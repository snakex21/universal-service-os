"""tools/win3x_vga_patch.py: NE parsing, the code walk, site selection and
the segment rewrite on a synthetic NE driver, and Unicorn emulation with the
planar VGA model of test_usosvgar.py: original and patched code give the
same registers, flags, RAM and VGA planes on a faithful VGA; on the X470
fault model (latches of a locked read come from byte offset|3) the original
breaks and the patched code still gives the faithful result.

The per-site emulation over a real Windows 3.x display driver runs when
USOS_WIN3X_DRV names one or more driver files (os.pathsep separated, e.g.
the user's own VGA.DRV 3.1); those files are never part of the repository.
"""
from pathlib import Path
import os
import random
import struct
import sys
import unittest

from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_CODE, UC_HOOK_INSN
from unicorn.x86_const import *

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import win3x_vga_patch as vp           # noqa: E402
from test_usosvgar import Vga, rmw_sites  # noqa: E402

CS, SS, RAMSEG = 0x1000, 0x3000, 0x5000


class Cpu:
    """16-bit CPU with code at CS:0, stack at SS, RAM at RAMSEG and the
    VGA model at A000 (MMIO); locked/RMW instruction kinds are tracked with
    code hooks so the fault model sees them."""

    def __init__(self, code, vga, seed):
        self.vga, self.kind = vga, None
        u = self.u = Uc(UC_ARCH_X86, UC_MODE_16)
        u.mem_map(0, 0xa0000)
        u.mmio_map(0xa0000, 0x10000, self._mr, None, self._mw, None)
        u.mem_map(0xb0000, 0x50000)
        u.mem_write(CS * 16, bytes(code))
        rnd = random.Random(seed)
        u.mem_write(RAMSEG * 16, bytes(rnd.getrandbits(8) for _ in range(0x10000)))
        u.mem_write(SS * 16, bytes(rnd.getrandbits(8) for _ in range(0x10000)))
        for a, k in rmw_sites(bytes(code), CS * 16).items():
            u.hook_add(UC_HOOK_CODE, self._kind, k, a, a)
        u.hook_add(UC_HOOK_INSN, self._in, None, 1, 0, UC_X86_INS_IN)
        u.hook_add(UC_HOOK_INSN, self._out, None, 1, 0, UC_X86_INS_OUT)

    def _kind(self, uc, addr, size, kind):
        self.kind = kind

    def _mr(self, uc, off, size, data):
        v = 0
        for i in range(size):
            v |= self.vga.read(off + i, self.kind) << (8 * i)
        return v

    def _mw(self, uc, off, size, value, data):
        for i in range(size):
            self.vga.write(off + i, (value >> (8 * i)) & 0xff)

    def _in(self, uc, port, size, data):
        return self.vga.inp(port)

    def _out(self, uc, port, size, value, data):
        self.vga.out(port, value & 0xff)
        if size == 2:
            self.vga.out(port + 1, (value >> 8) & 0xff)

    REGS = (UC_X86_REG_AX, UC_X86_REG_BX, UC_X86_REG_CX, UC_X86_REG_DX, UC_X86_REG_SI,
            UC_X86_REG_DI, UC_X86_REG_BP, UC_X86_REG_SP)

    def run(self, start, until, regs, ds):
        u = self.u
        for r, v in zip(self.REGS, regs):
            u.reg_write(r, v)
        for r, v in ((UC_X86_REG_CS, CS), (UC_X86_REG_SS, SS), (UC_X86_REG_DS, ds),
                     (UC_X86_REG_ES, 0xa000), (UC_X86_REG_IP, start)):
            u.reg_write(r, v)
        u.reg_write(UC_X86_REG_EFLAGS, 0x0002 | (regs[0] & 0x8d5))
        u.emu_start(CS * 16 + start, CS * 16 + until, count=200000)
        self.assert_ip = u.reg_read(UC_X86_REG_IP)
        return self.state()

    def state(self):
        """Registers, arithmetic flags, RAM, the stack segment except the
        16 bytes below SP (free stack: the CALL return address and the
        stub's PUSH land there), VGA planes, latches and registers."""
        u = self.u
        sp = u.reg_read(UC_X86_REG_SP)
        stack = bytearray(u.mem_read(SS * 16, 0x10000))
        stack[max(sp - 16, 0):sp] = bytes(sp - max(sp - 16, 0))
        return (tuple(u.reg_read(r) for r in self.REGS),
                u.reg_read(UC_X86_REG_EFLAGS) & 0x8d5,
                bytes(u.mem_read(RAMSEG * 16, 0x10000)),
                bytes(stack),
                tuple(bytes(p) for p in self.vga.planes),
                tuple(self.vga.latch),
                tuple(self.vga.gc), tuple(self.vga.seq))


def make_vga(seed, mode, fault):
    v = Vga(locked3=fault)
    rnd = random.Random(seed)
    for p in v.planes:
        p[:] = bytes(rnd.getrandbits(8) for _ in range(0x10000))
    v.gc[5], v.gc[8], v.gc[3] = mode
    v.latch = [rnd.getrandbits(8) for _ in range(4)]
    return v


# write mode, bit mask, function/rotate: all of them combine with the latches
MODES = ((0, 0x3c, 0x00), (2, 0x5a, 0x00), (0, 0xff, 0x18), (3, 0x0f, 0x00))


# --- synthetic NE driver -------------------------------------------------------
def asm_seg1():
    """Code segment 1: entry 0 calls r1 and r2 and a far routine in segment
    2 (relocated); r1 = lodsb / xchg es:[di],al / inc di loop, r2 =
    DS=ES=A000 xchg [di],ah / add di,50h loop (2-byte site, window with the
    next instruction), a DS variable xchg [40h],cl (busy flag: never
    patched) and xchg es:[di+1],ah (4 bytes: call + NOP). After r2 an
    unreached 26 86 05 C3 block (template-like)."""
    c = bytearray()
    c += b'\xe8\0\0'                      # 0000 call r1
    c += b'\xe8\0\0'                      # 0003 call r2
    c += b'\x9a\xff\xff\0\0'              # 0006 call far seg2:0 (fixup at 0007)
    c += b'\xcb'                          # 000B retf
    c += b'\x90' * (0x10 - len(c))
    r1 = len(c)
    c += b'\xb9\x10\x00'                  # mov cx,16
    c += b'\xac'                          # lodsb
    c += b'\x26\x86\x05'                  # xchg es:[di],al
    c += b'\x47'                          # inc di
    c += b'\xe2\xf9'                      # loop lodsb
    c += b'\xc3'
    r2 = len(c)
    c += b'\x1e\x06\x1f'                  # push ds / push es / pop ds
    c += b'\xb9\x08\x00'                  # mov cx,8
    c += b'\x86\x25'                      # L: xchg [di],ah
    c += b'\x81\xc7\x50\x00'              # add di,50h
    c += b'\xe2\xf8'                      # loop L
    c += b'\x1f'                          # pop ds
    c += b'\x86\x0e\x40\x00'              # xchg [0040h],cl
    c += b'\x26\x86\x65\x01'              # xchg es:[di+1],ah
    c += b'\xc3'
    tmpl = len(c)
    c += b'\x26\x86\x05\xc3'              # unreached template
    struct.pack_into('<H', c, 1, r1 - 3)
    struct.pack_into('<H', c, 4, r2 - 6)
    return bytes(c), r1, r2, tmpl


def build_ne():
    seg1, r1, r2, tmpl = asm_seg1()
    seg2 = b'\xcb'
    shift = 4
    ne_off = 0x40
    segtab = ne_off + 0x40
    entry = ne_off + 0x60
    ent = bytes([1, 1, 0x01]) + struct.pack('<H', 0) + b'\0'   # 1 fixed entry seg1:0
    body = bytearray(0x200)
    body[0:2] = b'MZ'
    struct.pack_into('<I', body, 0x3c, ne_off)
    body[ne_off:ne_off + 2] = b'NE'
    struct.pack_into('<H', body, ne_off + 0x04, entry - ne_off)
    struct.pack_into('<H', body, ne_off + 0x06, len(ent))
    struct.pack_into('<H', body, ne_off + 0x1c, 2)
    struct.pack_into('<H', body, ne_off + 0x22, segtab - ne_off)
    struct.pack_into('<H', body, ne_off + 0x32, shift)
    body[entry:entry + len(ent)] = ent
    out = bytearray(body)
    s1 = len(out)
    rel1 = struct.pack('<H', 1) + struct.pack('<BBHHH', 3, 0, 0x0007, 2, 0)
    out += seg1 + rel1
    out += b'\0' * (-len(out) % 16)
    s2 = len(out)
    out += seg2
    out += b'\0' * (-len(out) % 16)
    out += b'TRAILER-RESOURCES'
    struct.pack_into('<HHHH', out, segtab, s1 >> 4, len(seg1), 0x0150, len(seg1))
    struct.pack_into('<HHHH', out, segtab + 8, s2 >> 4, len(seg2), 0x0050, len(seg2))
    return bytes(out), r1, r2, tmpl


class SyntheticTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw, cls.r1, cls.r2, cls.tmpl = build_ne()
        cls.out, cls.sites, cls.reach = vp.patch(cls.raw)

    def test_sites(self):
        got = {(s.seg, s.off): s.action for s in self.sites}
        r2 = self.r2
        self.assertEqual(got[(1, self.r1 + 4)], 'patched')
        self.assertEqual(got[(1, r2 + 6)], 'patched')                 # xchg [di],ah
        self.assertIn('ds-abs', got[(1, r2 + 15)])                     # busy flag
        self.assertEqual(got[(1, r2 + 19)], 'patched')                # es:[di+1]
        self.assertIn('not reached', got[(1, self.tmpl)])
        w = {(s.seg, s.off): s.window for s in self.sites}
        self.assertEqual(w[(1, r2 + 6)], (r2 + 6, r2 + 12))           # + add di,50h
        self.assertEqual(len(vp.replaced(self.sites)), 3)

    def test_file_layout(self):
        old, new = vp.parse_ne(self.raw), vp.parse_ne(self.out)
        self.assertEqual(self.out[:len(self.raw)][:0x80], self.raw[:0x80])
        self.assertTrue(self.out[:len(self.raw)].endswith(b'TRAILER-RESOURCES'))
        s_old, s_new = old.segments[0], new.segments[0]
        self.assertGreater(s_new.file_off, len(self.raw) - 1)
        self.assertEqual(s_new.minalloc, s_new.length)
        self.assertEqual(s_new.relocs, s_old.relocs)
        self.assertEqual(s_new.flags, s_old.flags)
        self.assertEqual(s_new.data[0x06:0x0b], b'\x9a\xff\xff\0\0')  # fixup untouched
        self.assertEqual(new.segments[1].data, old.segments[1].data)
        # only the site windows changed; template block untouched
        diff = [i for i in range(s_old.length) if s_old.data[i] != s_new.data[i]]
        r1, r2 = self.r1, self.r2
        allowed = set(range(r1 + 4, r1 + 7)) | set(range(r2 + 6, r2 + 12)) | \
            set(range(r2 + 19, r2 + 23))
        self.assertTrue(set(diff) <= allowed, diff)
        self.assertEqual(s_new.data[r2 + 22], 0x90)
        self.assertEqual(s_new.data[self.tmpl:self.tmpl + 4], b'\x26\x86\x05\xc3')
        self.assertEqual(self.out[0x40 + 0x37] & 8, 0)                 # no fast-load area
        self.assertEqual(self.out[0x40 + 0x38:0x40 + 0x3c], b'\0' * 4)

    def run_routines(self, code, fault, seed, mode):
        vga = make_vga(seed, mode, fault)
        cpu = Cpu(code, vga, seed)
        res = []
        for start, ds in ((self.r1, RAMSEG), (self.r2, RAMSEG)):
            sp = 0xff00
            cpu.u.mem_write(SS * 16 + sp, struct.pack('<H', 0x000b))
            regs = (0x1234, 0x0000, 0x5555, 0x3ce, 0x0100, 0x1230 + seed, 0x0400, sp)
            res.append(cpu.run(start, 0x000b, regs, ds))
        return res

    def test_emulated_routines(self):
        orig = vp.parse_ne(self.raw).segments[0].data
        new = vp.parse_ne(self.out).segments[0].data
        for seed, mode in enumerate(MODES):
            good = self.run_routines(orig, False, seed, mode)
            self.assertEqual(self.run_routines(new, False, seed, mode), good)
            self.assertNotEqual(self.run_routines(orig, True, seed, mode), good)
            self.assertEqual(self.run_routines(new, True, seed, mode), good)

    def test_unlocked_rmw_option(self):
        raw = bytearray(self.raw)
        # put "or es:[di],al" at the r1 site instead of the XCHG
        s1 = vp.parse_ne(self.raw).segments[0].file_off
        raw[s1 + self.r1 + 4:s1 + self.r1 + 7] = b'\x26\x08\x05'
        out, sites, _ = vp.patch(bytes(raw))
        self.assertNotIn((1, self.r1 + 4), {(s.seg, s.off) for s in vp.replaced(sites)})
        out, sites, _ = vp.patch(bytes(raw), unlocked_rmw=True)
        self.assertIn((1, self.r1 + 4), {(s.seg, s.off) for s in vp.replaced(sites)})
        orig = vp.parse_ne(bytes(raw)).segments[0].data
        new = vp.parse_ne(out).segments[0].data
        for seed, mode in enumerate(MODES):
            good = self.run_routines(orig, False, seed, mode)
            self.assertEqual(self.run_routines(new, False, seed, mode), good)

    def test_stub_sequences(self):
        self.assertEqual(vp.xchg_seq(b'\x26\x86\x05'),
                         b'\x51\x26\x8a\x0d\x26\x88\x05\x8a\xc1\x59')   # T = CX
        self.assertEqual(vp.xchg_seq(b'\x26\x86\x25'),
                         b'\x51\x26\x8a\x0d\x26\x88\x25\x8a\xe1\x59')   # AH: T not AX (POP AX)
        # [bx+di] with BL: T must avoid BX
        seq = vp.xchg_seq(b'\x26\x86\x19')
        self.assertEqual(seq[0], 0x50)
        with self.assertRaises(vp.PatchError):
            vp.xchg_seq(b'\x66\x26\x87\x05')


@unittest.skipUnless(os.environ.get('USOS_WIN3X_DRV'), 'USOS_WIN3X_DRV not set')
class RealDriverTest(unittest.TestCase):
    """Every replaced window of the given driver(s), executed alone with
    random registers, VGA planes and modes: patched == original on a
    faithful VGA, and patched on the fault model == original on a faithful
    VGA."""

    def test_windows(self):
        for name in os.environ['USOS_WIN3X_DRV'].split(os.pathsep):
            raw = Path(name).read_bytes()
            out, sites, reach = vp.patch(raw)
            old, new = vp.parse_ne(raw), vp.parse_ne(out)
            done, broken = 0, 0
            for s in vp.replaced(sites):
                if s.action != 'patched':
                    continue
                lo, hi = s.window
                ocode = old.segments[s.seg - 1].data
                ncode = new.segments[s.seg - 1].data
                ins = reach[s.seg][0][s.off]
                ds = 0xa000 if vp._seg_of(ins) == 'ds-reg' else RAMSEG
                for k, mode in enumerate(MODES):
                    seed = s.off * 7 + k
                    rnd = random.Random(seed)
                    regs = tuple(rnd.getrandbits(16) for _ in range(7)) + (0xf000,)
                    regs = regs[:6] + (0x8000 | rnd.getrandbits(14),) + regs[7:]
                    good = Cpu(ocode, make_vga(seed, mode, False), seed).run(lo, hi, regs, ds)
                    with self.subTest(driver=name, site=f'{s.seg}:{s.off:04X}', mode=mode):
                        self.assertEqual(
                            Cpu(ncode, make_vga(seed, mode, False), seed).run(lo, hi, regs, ds),
                            good)
                        self.assertEqual(
                            Cpu(ncode, make_vga(seed, mode, True), seed).run(lo, hi, regs, ds),
                            good)
                    bad = Cpu(ocode, make_vga(seed, mode, True), seed).run(lo, hi, regs, ds)
                    broken += bad != good
                done += 1
            print(f'{Path(name).name}: {done} windows emulated x {len(MODES)} modes, '
                  f'original wrong on the fault model in {broken} runs')
            self.assertGreater(done, 0)
            self.assertGreater(broken, 0)


if __name__ == '__main__':
    unittest.main()
