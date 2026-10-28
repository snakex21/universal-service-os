"""USOSVGAR.COM (VGA register readback / MTRR / bulk latch probe) in Unicorn
against a planar VGA model: a faithful VGA gives RESULT OK, a card whose
graphics controller or sequencer data reads do not return the written value
gives RESULT READBACK-BAD, broken off-screen latch storage gives
RESULT MEMORY-OR-LATCH-BAD, a write mode 1 path that stores a stale latch or
an ignored rotate gives RESULT BULK-BAD; the previous text mode is set again.
Version 3 RMW tests: latches of locked reads taken from byte offset|3 (the
X470 fault; reproduces the X470 USOSVGAR 2 bulk lines) give RMW RESULT
LOCKED-ONLY, the same for every RMW gives UNLOCKED-BAD-TOO.
CPUID and RDMSR/WRMSR are emulated by the test so the MTRR decode and the
temporary 259h=UC experiment (always restored) can be checked."""
from pathlib import Path
import os
import struct
import sys
import tempfile
import unittest
import capstone
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INTR, UC_HOOK_INSN, UC_HOOK_CODE
from unicorn.x86_const import *

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
import build_win9x_support
if os.environ.get('USOS_TOOLS_ROOT'):
    # Worktrees without tools/zig: take the toolchain from another checkout.
    build_win9x_support.ROOT = Path(os.environ['USOS_TOOLS_ROOT'])

PSP = 0x1000


def ror8(v, n):
    n &= 7
    return ((v >> n) | (v << (8 - n))) & 0xff


class Vga:
    """Planar VGA: SEQ 2 map mask, GC 0-8, write modes 0-3 (rotate, ALU,
    set/reset, bit mask), read modes 0/1, latches. Fault switches:
    bad_gc / bad_seq: data reads return a wrong value; bad_offscreen: no
    memory above BF00; lag: write mode 1 stores the latch of the read
    BEFORE the last one; no_rotate: GC3 rotate ignored; locked3: a locked
    read (XCHG with memory, LOCK prefix) loads the latches from byte
    offset|3 (the X470/RX 560 fault seen with USOSVGAR 2; the CPU still
    gets the addressed byte); rmw3: the same for every read-modify-write
    instruction."""

    def __init__(self, bad_gc=None, bad_seq=False, bad_offscreen=False,
                 lag=False, no_rotate=False, locked3=False, rmw3=False):
        self.planes = [bytearray(0x10000) for _ in range(4)]
        self.latch = [0, 0, 0, 0]
        self.prev = [0, 0, 0, 0]
        self.seq = [3, 1, 0x0f, 0, 6]
        self.gc = [0, 0, 0, 0, 0, 0, 5, 0x0f, 0xff]
        self.si = self.gi = 0
        self.bad_gc, self.bad_seq, self.bad_off = bad_gc, bad_seq, bad_offscreen
        self.lag, self.no_rotate = lag, no_rotate
        self.locked3, self.rmw3 = locked3, rmw3

    def out(self, port, v):
        if port == 0x3c4:
            self.si = v & 7
        elif port == 0x3c5 and self.si < 5:
            self.seq[self.si] = v
        elif port == 0x3ce:
            self.gi = v & 15
        elif port == 0x3cf and self.gi < 9:
            self.gc[self.gi] = v

    def inp(self, port):
        if port == 0x3c4:
            return self.si
        if port == 0x3ce:
            return self.gi
        if port == 0x3c5:
            v = self.seq[self.si] if self.si < 5 else 0xff
            return (v ^ 0x05) if self.bad_seq and self.si == 2 else v
        if port == 0x3cf:
            v = self.gc[self.gi] if self.gi < 9 else 0xff
            return 0xff if self.bad_gc is not None and self.gi == self.bad_gc else v
        return 0xff

    def read(self, off, kind=None):
        """kind: None plain read, 'rmw' read of an RMW instruction,
        'locked' read of a locked one."""
        if self.bad_off and off >= 0xbf00:
            self.latch = [0x00] * 4
            return 0
        self.prev = self.latch
        src = off
        if (kind == 'locked' and self.locked3) or (kind and self.rmw3):
            src = off | 3
        self.latch = [p[src] for p in self.planes]
        cpu = [p[off] for p in self.planes]
        if self.gc[5] & 8:
            r = 0xff
            for i in range(4):
                if self.gc[7] >> i & 1:
                    r &= ~(cpu[i] ^ (0xff if self.gc[2] >> i & 1 else 0))
            return r & 0xff
        return cpu[self.gc[4] & 3]

    def write(self, off, v):
        if self.bad_off and off >= 0xbf00:
            return
        gc = self.gc
        mode, fn, bm = gc[5] & 3, (gc[3] >> 3) & 3, gc[8]
        rot = 0 if self.no_rotate else gc[3] & 7
        for i in range(4):
            if not self.seq[2] & (1 << i):
                continue
            lat = self.latch[i]
            if mode == 1:
                self.planes[i][off] = (self.prev if self.lag else self.latch)[i]
                continue
            sr = 0xff if gc[0] >> i & 1 else 0
            if mode == 2:
                d, m = (0xff if v >> i & 1 else 0), bm
            elif mode == 3:
                d, m = sr, ror8(v, rot) & bm
            else:
                d, m = (sr if gc[1] >> i & 1 else ror8(v, rot)), bm
            d = (d, d & lat, d | lat, d ^ lat)[fn]
            self.planes[i][off] = (d & m) | (lat & ~m & 0xff)


RMW_MNEMONICS = {'add', 'or', 'adc', 'sbb', 'and', 'sub', 'xor', 'not', 'neg',
                 'inc', 'dec', 'shl', 'shr', 'sal', 'sar', 'rol', 'ror', 'rcl', 'rcr'}


def rmw_sites(code, base):
    """{address: kind} for every byte position of a 16-bit image that
    decodes as a locked ('locked': XCHG with memory or LOCK prefix) or other
    read-modify-write ('rmw') instruction with a memory destination, plus
    {address after it: None}. Positions inside data or other instructions
    are harmless: hooks only fire at executed instruction starts."""
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_16)
    md.detail = True
    sites = {}
    for i in range(len(code)):
        insn = next(md.disasm(code[i:i + 15], base + i, 1), None)
        if insn is None or not insn.operands:
            continue
        mem0 = insn.operands[0].type == capstone.x86.X86_OP_MEM
        memany = any(o.type == capstone.x86.X86_OP_MEM for o in insn.operands)
        if (capstone.x86.X86_PREFIX_LOCK in insn.prefix and memany) or                 (insn.mnemonic == 'xchg' and memany):
            kind = 'locked'
        elif mem0 and insn.mnemonic in RMW_MNEMONICS:
            kind = 'rmw'
        else:
            continue
        sites[base + i] = kind
        sites.setdefault(base + i + insn.size, None)
    return sites


class Machine:
    def __init__(self, com, vga, cpu=None):
        """cpu: None = CPUID without the MSR bit; otherwise a dict of MSRs
        (CPUID reports AuthenticAMD with MSR + MTRR)."""
        self.vga, self.mode, self.out, self.modes = vga, 3, b'', []
        self.msrs = cpu
        self.msr_writes = []
        self.int_flag_at_wrmsr = []
        self.on_wrmsr = None
        u = self.u = Uc(UC_ARCH_X86, UC_MODE_16)
        u.mem_map(0, 0xa0000)
        u.mmio_map(0xa0000, 0x10000, self._mr, None, self._mw, None)
        u.mem_map(0xb0000, 0x50000)
        u.mem_write(PSP * 16 + 0x100, com)
        u.mem_write(0xf0000, b'\xcf')
        for n in range(256):
            u.mem_write(n * 4, struct.pack('<HH', 0, 0xf000))
        for r, v in ((UC_X86_REG_CS, PSP), (UC_X86_REG_DS, PSP), (UC_X86_REG_ES, PSP),
                     (UC_X86_REG_SS, PSP), (UC_X86_REG_SP, 0xfffe), (UC_X86_REG_IP, 0x100)):
            u.reg_write(r, v)
        u.hook_add(UC_HOOK_INTR, self._int)
        u.hook_add(UC_HOOK_INSN, self._in, None, 1, 0, UC_X86_INS_IN)
        u.hook_add(UC_HOOK_INSN, self._outh, None, 1, 0, UC_X86_INS_OUT)
        u.hook_add(UC_HOOK_INSN, self._cpuid, None, 1, 0, UC_X86_INS_CPUID)
        # The Python binding has no RDMSR/WRMSR hook: hook every 0F 30 /
        # 0F 32 position of the image (data matches are never executed).
        base = PSP * 16 + 0x100
        for i in range(len(com) - 1):
            if com[i] == 0x0f and com[i + 1] in (0x30, 0x32):
                u.hook_add(UC_HOOK_CODE, self._msr, None, base + i, base + i)
        # MMIO callbacks do not see the current IP: mark the instruction
        # kind (locked / rmw) with code hooks at those instructions and
        # clear it at the next one.
        self.kind = None
        if vga.locked3 or vga.rmw3:
            for a, k in rmw_sites(com, base).items():
                u.hook_add(UC_HOOK_CODE, self._kind, k, a, a)
        self.done = False

    def _kind(self, uc, addr, size, kind):
        self.kind = kind

    def _cpuid(self, uc, data):
        leaf = uc.reg_read(UC_X86_REG_EAX)
        if leaf == 0:
            vals = (1, 0x68747541, 0x444d4163, 0x69746e65)    # AuthenticAMD
        elif leaf == 1:
            edx = 0x1031 if self.msrs is not None else 0x0001  # FPU (+MSR, MTRR)
            vals = (0xa20f10, 0, 0, edx)
        else:
            vals = (0, 0, 0, 0)
        for r, v in zip((UC_X86_REG_EAX, UC_X86_REG_EBX, UC_X86_REG_ECX, UC_X86_REG_EDX), vals):
            uc.reg_write(r, v)
        return 1

    def _msr(self, uc, addr, size, data):
        op = bytes(uc.mem_read(addr, 2))
        ecx = uc.reg_read(UC_X86_REG_ECX)
        if op == b'\x0f\x32':
            v = self.msrs.get(ecx, 0)
            uc.reg_write(UC_X86_REG_EAX, v & 0xffffffff)
            uc.reg_write(UC_X86_REG_EDX, v >> 32)
        else:
            v = uc.reg_read(UC_X86_REG_EAX) | (uc.reg_read(UC_X86_REG_EDX) << 32)
            self.msrs[ecx] = v
            self.msr_writes.append((ecx, v))
            self.int_flag_at_wrmsr.append(bool(uc.reg_read(UC_X86_REG_EFLAGS) & 0x200))
            if self.on_wrmsr:
                self.on_wrmsr(self)
        uc.reg_write(UC_X86_REG_IP, uc.reg_read(UC_X86_REG_IP) + 2)

    def _mr(self, uc, off, size, data):
        kind = self.kind
        v = 0
        for i in range(size):
            v |= self.vga.read(off + i, kind) << (8 * i)
        return v

    def _mw(self, uc, off, size, value, data):
        for i in range(size):
            self.vga.write(off + i, (value >> (8 * i)) & 0xff)

    def _in(self, uc, port, size, data):
        return self.vga.inp(port)

    def _outh(self, uc, port, size, value, data):
        self.vga.out(port, value & 0xff)

    def _int(self, uc, n, data):
        ax = uc.reg_read(UC_X86_REG_AX)
        if n == 0x10:
            ah = ax >> 8
            if ah == 0x0f:
                uc.reg_write(UC_X86_REG_AX, (ax & 0xff00) | self.mode)
            elif ah == 0:
                self.mode = ax & 0x7f
                self.modes.append(self.mode)
        elif n == 0x21:
            ah = ax >> 8
            if ah == 0x40:
                ds = uc.reg_read(UC_X86_REG_DS)
                dx, cx = uc.reg_read(UC_X86_REG_DX), uc.reg_read(UC_X86_REG_CX)
                self.out += bytes(uc.mem_read(ds * 16 + dx, cx))
                uc.reg_write(UC_X86_REG_AX, cx)
            elif ah == 0x4c:
                self.done = True
                uc.emu_stop()

    def run(self):
        self.u.emu_start(PSP * 16 + 0x100, 0)
        return self.out.decode('ascii')


# MSRs of a machine whose A0000-BFFFF fixed range is write-combining
AMD_WC = {0xfe: 0x508, 0x2ff: 0xc06, 0x259: 0x0101010101010101,
          0x200: 0x6, 0x201: 0xffff80000800, 0xc0010010: 0x1c0000}
# fixed MTRRs on, 259h all UC (the expected firmware setting)
AMD_UC = {**AMD_WC, 0x259: 0}
# MTRRs disabled entirely
AMD_OFF = {**AMD_WC, 0x2ff: 0x006}
# fixed MTRRs off, variable MTRR 0 (WB, 0-2 GiB) covers A0000
AMD_FEOFF = {**AMD_WC, 0x2ff: 0x806}


class UsosVgarTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        out = Path(cls.tmp.name)
        cls.com = build_win9x_support.build_usosvgar(out, out).read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_with(self, vga, cpu=None, on_wrmsr=None):
        m = Machine(self.com, vga, cpu)
        m.on_wrmsr = on_wrmsr
        text = m.run()
        self.assertTrue(m.done, text)
        self.assertEqual(m.modes, [0x12, 3], text)
        self.machine = m
        return text

    def test_faithful_vga_ok(self):
        text = self.run_with(Vga())
        self.assertIn('readback tests 0075 mismatches 0000', text)
        self.assertIn('RESULT OK', text)
        self.assertIn('implicit index (SEQ2 via 3C5, GC8 via 3CF): 05 0F 3C FF', text)
        self.assertIn('no MSR support, MSR part skipped', text)
        self.assertIn('bulk total mismatches 0000', text)
        self.assertIn('WM1 back rep movsb overlap 0000->0050 len 4000 mismatches 0000', text)
        self.assertIn('RM1 compare 0A dont-care 07 mismatches 0000', text)
        self.assertIn('UC experiment: skipped (no MTRR access)', text)
        # readback, plane memory, latch; 1 fill + 10 copies + 10 ops + 2 RM1; total
        self.assertEqual(text.count(' mismatches 0000\r\n'), 3 + 23 + 1, text)
        # v3: 10 byte RMW forms x (WM1 + WM0/3C) + RMW RESULT + RESULT; 4 word forms INFO
        self.assertEqual(text.count(' OK\r\n'), 22, text)
        self.assertEqual(text.count(' INFO\r\n'), 4, text)
        self.assertIn('RMW xchg es:[di],al     WM1 a0 =:01FF a1 =:01FF a2 =:01FF a3 =:01FF '
                      'stray 0000 OK', text)
        self.assertIn('RMW summary: locked bad 0000 of 0004, unlocked bad 0000 of 0010', text)
        self.assertIn('RMW RESULT OK', text)

    def test_bad_gc8_readback(self):
        text = self.run_with(Vga(bad_gc=8))
        self.assertIn('RESULT READBACK-BAD', text)
        self.assertIn('bad 03CE:08 wrote 00 read FF', text)

    def test_bad_seq_readback(self):
        text = self.run_with(Vga(bad_seq=True))
        self.assertIn('RESULT READBACK-BAD', text)
        self.assertIn('bad 03C4:02', text)

    def test_bad_offscreen_latches(self):
        text = self.run_with(Vga(bad_offscreen=True))
        self.assertIn('RESULT MEMORY-OR-LATCH-BAD', text)

    def test_stale_latch_copy_is_bulk_bad(self):
        text = self.run_with(Vga(lag=True))
        self.assertIn('RESULT MEMORY-OR-LATCH-BAD', text)
        self.assertNotIn('WM1 fwd  rep movsb 0000->8000 len 6000 mismatches 0000', text)
        self.assertRegex(text, r'WM1 fwd  rep movsb 0000->8000 len 6000 mismatches [0-9A-F]{4} @8000 p0')
        self.assertIn('WM0 XOR mismatches 0000', text)

    def test_ignored_rotate_is_bulk_bad(self):
        text = self.run_with(Vga(no_rotate=True))
        self.assertIn('RESULT BULK-BAD', text)
        self.assertIn('WM0 AND mismatches 0000', text)
        self.assertNotIn('WM0 rot 3 mismatches 0000', text)
        self.assertIn('WM1 fwd  byte loop 0000->8000 len 6000 mismatches 0000', text)

    def test_locked_addr3_latch_reproduces_x470(self):
        # USOSVGAR 2 on the X470 (Micron, Windows 3.1 install): this fault
        # model gives the same 24 bulk lines byte for byte; v3 then narrows
        # it to locked RMW.
        text = self.run_with(Vga(locked3=True))
        self.assertIn('WM2 bit mask 3C mismatches 1800 @9200 p0 exp FE got 3D @9201 p0 '
                      'exp C3 got 01 @9202 p0 exp 3C got 3D @9204 p0 exp 3E got 3D', text)
        self.assertIn('WM0 AND mismatches 12B8 @9200 p0 exp A4 got 01', text)
        self.assertIn('WM1 fwd  rep movsb 0000->8000 len 6000 mismatches 0000', text)
        self.assertIn('bulk total mismatches A468', text)
        self.assertIn('RMW xchg es:[di],al     WM1 a0 3:01FF a1 3:01FF a2 3:01FF a3 =:01FF '
                      'stray 0000 ADDR3', text)
        self.assertIn('RMW xchg es:[di],al     WM0/3C =:01FF 3:05FD R:0000 ?:0000 stray 0000 '
                      'cpu 0000 ADDR3', text)
        self.assertIn('RMW lock or es:[di],al  WM1 a0 3:01FF', text)
        self.assertIn('RMW or es:[di],al       WM1 a0 =:01FF a1 =:01FF a2 =:01FF a3 =:01FF '
                      'stray 0000 OK', text)
        self.assertIn('RMW summary: locked bad 0004 of 0004, unlocked bad 0000 of 0010', text)
        self.assertIn('RMW RESULT LOCKED-ONLY', text)
        self.assertIn('RESULT BULK-BAD', text)

    def test_all_rmw_addr3_latch(self):
        text = self.run_with(Vga(rmw3=True))
        self.assertIn('RMW or es:[di],al       WM1 a0 3:01FF', text)
        self.assertIn('RMW mov ah,[di]/[di],al WM1 a0 =:01FF a1 =:01FF a2 =:01FF a3 =:01FF '
                      'stray 0000 OK', text)
        self.assertIn('RMW test es:[di],al+mov WM0/3C =:07FC', text)
        self.assertIn('RMW summary: locked bad 0004 of 0004, unlocked bad 000C of 0010', text)
        self.assertIn('RMW RESULT UNLOCKED-BAD-TOO', text)

    def test_restores_registers(self):
        vga = Vga()
        self.run_with(vga)
        self.assertEqual(vga.gc[5] & 3, 0)
        self.assertEqual(vga.gc[3], 0)
        self.assertEqual(vga.gc[1], 0)
        self.assertEqual(vga.gc[8], 0xff)
        self.assertEqual(vga.seq[2], 0x0f)

    def test_msr_decode_uc(self):
        text = self.run_with(Vga(), dict(AMD_UC))
        self.assertIn('AuthenticAMD CPUID1.EDX 00001031', text)
        self.assertIn('  MSR 00000259 00000000:00000000', text)
        self.assertIn('  AMD SYSCFG MtrrFixDramEn/ModEn/VarDramEn 111', text)
        self.assertIn('A0000-BFFFF memory type: fixed MTRR 259h UC\r\n', text)
        self.assertIn('UC experiment: not needed (A0000-BFFFF already UC)', text)
        self.assertEqual(self.machine.msr_writes, [])
        self.assertIn('RESULT OK', text)

    def test_msr_mtrrs_disabled(self):
        text = self.run_with(Vga(), dict(AMD_OFF))
        self.assertIn('A0000-BFFFF memory type: UC (MTRRs disabled, 2FFh.E=0)', text)
        self.assertIn('UC experiment: not needed', text)
        self.assertEqual(self.machine.msr_writes, [])

    def test_msr_fixed_off_variable_wb(self):
        text = self.run_with(Vga(), dict(AMD_FEOFF))
        self.assertIn('  var MTRR 00 00000006 0000FFFF:80000800 covers A0000', text)
        self.assertIn('A0000-BFFFF memory type: variable MTRR type 06', text)
        self.assertIn('UC experiment: skipped (fixed MTRRs disabled', text)
        self.assertEqual(self.machine.msr_writes, [])

    def test_uc_experiment_restores_and_reports_fix(self):
        # The model "caches" A0000 while 259h is not UC: write mode 1 then
        # stores a stale latch. Setting 259h=0 removes the fault.
        vga = Vga(lag=True)

        def follow(m):
            m.vga.lag = m.msrs.get(0x259, 0) != 0
        text = self.run_with(vga, dict(AMD_WC), follow)
        self.assertIn('A0000-BFFFF memory type: fixed MTRR 259h NOT-UC', text)
        self.assertIn('UC experiment: 259h set to 0, readback\r\n  MSR 00000259 00000000:00000000', text)
        self.assertIn('UC WM1 fwd  rep movsb 0000->8000 len 6000 mismatches 0000', text)
        self.assertIn('UC experiment: restore OK', text)
        self.assertRegex(text, r'bulk mismatches normal [0-9A-F]{4} with 259h=UC 0000 UC-FIXES-BULK')
        self.assertIn('UC experiment: running', text)
        m = self.machine
        self.assertEqual(m.msrs[0x259], AMD_WC[0x259])
        self.assertEqual(m.msrs[0x2ff], AMD_WC[0x2ff])
        # MTRRs off, 259h, MTRRs on - twice (set, restore); never with IF=1
        self.assertEqual([w[0] for w in m.msr_writes], [0x2ff, 0x259, 0x2ff] * 2)
        self.assertEqual(m.msr_writes[0][1], 0x406)
        self.assertEqual(m.msr_writes[1][1], 0)
        self.assertEqual(m.msr_writes[4][1], AMD_WC[0x259])
        self.assertFalse(any(m.int_flag_at_wrmsr))
        cr0 = m.u.reg_read(UC_X86_REG_CR0)
        self.assertEqual(cr0 & 0x60000000, 0)

    def test_uc_experiment_no_fix(self):
        text = self.run_with(Vga(no_rotate=True), dict(AMD_WC))
        self.assertIn('UC-NO-FIX', text)
        self.assertIn('UC experiment: restore OK', text)


if __name__ == '__main__':
    unittest.main()
