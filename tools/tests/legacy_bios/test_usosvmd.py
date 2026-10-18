"""USOSVMD.VXD - the Windows 9x VMOUSE mouse minidriver that gives MS-DOS
boxes an Int 33h mouse by draining USOSKEY.COM's USB mouse ring at ring 0
and posting to VMOUSE (docs/dos-mouse-2026-10-18.md). Checks:

  * the shared-block offsets the VxD hard-codes match usoskey.S (version 4);
  * the built file is a valid LE VxD with the USOSVMD DDB (SDK 4.0) and makes
    exactly the documented VMM / VMOUSE service calls;
  * emulated at ring 0 (Unicorn, 32-bit), the `drain` routine finds the block
    through the system VM's CB_High_Linear, decodes PS/2 packets from the
    ring, maps the buttons to the VMOUSE AL format (b1=0x20, b2=0x08,
    b3=0x10), posts delta X as read and delta Y negated (PS/2 up-positive ->
    down-positive), skips overflow packets, advances the tail and tops up
    malive;
  * USOSMOUS.DRV gained the flag-gated VMOUSE mode and still imports KERNEL
    only; USOSKEY.DRV leaves the Me DOS-box pause off when the VxD is on.
"""
from pathlib import Path
import re
import struct
import sys
import unittest

from unicorn import Uc, UC_ARCH_X86, UC_MODE_32, UC_HOOK_INTR
from unicorn.x86_const import (UC_X86_REG_EIP, UC_X86_REG_ESP, UC_X86_REG_EAX,
                               UC_X86_REG_EBX, UC_X86_REG_ESI, UC_X86_REG_EDI,
                               UC_X86_REG_EDX)

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
from build_win3_usb_keyboard import build_vxd, ne_imported_modules, build_mouse_driver, build_tsr, write_tsr_header

# Shared-block mouse-field offsets as the VxD hard-codes them (usoskey.S v4).
OFF = dict(MHEAD=396, MTAIL=397, MALIVE=398, MCBOFS=400, MRING=420)
BASE = 0x10000                      # LE object load base


def le_image(path: Path):
    """Return (flat bytes of object 1 with internal fixups applied, symbol
    map). Enough of the LE format for a single-object preload VxD."""
    d = path.read_bytes()
    le = struct.unpack_from('<I', d, 0x3c)[0]
    assert d[le:le + 2] == b'LE'
    g = lambda o: struct.unpack_from('<I', d, le + o)[0]
    pagesz, npages = g(0x28), g(0x14)
    objtab, pmap = g(0x40), g(0x48)
    fpt, frt, datapg = le + g(0x68), le + g(0x6c), g(0x80)
    vs, base, fl, pidx, pcnt, _ = struct.unpack_from('<IIIIII', d, le + objtab)
    buf = bytearray(vs + pagesz)
    for p in range(pcnt):
        pg = pidx + p
        off = datapg + (pg - 1) * pagesz
        sz = g(0x2c) if pg == npages else pagesz
        buf[p * pagesz:p * pagesz + sz] = d[off:off + sz]
    # internal fixups
    for p in range(pcnt):
        a, b = struct.unpack_from('<II', d, fpt + 4 * (pidx + p - 1))
        r, end = frt + a, frt + b
        while r < end:
            src, flags = d[r], d[r + 1]; r += 2
            so = struct.unpack_from('<h', d, r)[0]; r += 2
            tobj = d[r]; r += 1
            st = src & 0xf
            if st == 7:
                toff = struct.unpack_from('<H', d, r)[0]; r += 2
                struct.pack_into('<I', buf, p * pagesz + so, BASE + toff)
            else:
                raise AssertionError('unexpected fixup type %d' % st)
    return bytes(buf[:vs])


def vxd_calls(code: bytes):
    out = []
    i = 0
    while i < len(code) - 5:
        if code[i] == 0xcd and code[i + 1] == 0x20:
            v = struct.unpack_from('<I', code, i + 2)[0]
            out.append((v >> 16, v & 0x7fff))
            i += 6
        else:
            i += 1
    return out


def sym_map(work: Path):
    m = {}
    for line in (work / 'usosvmd.map').read_text(errors='replace').splitlines():
        g = re.match(r'\s*0001:([0-9a-fA-F]{8})\*?\s+(\w+)', line)
        if g:
            m[g.group(2)] = BASE + int(g.group(1), 16)
    return m


class UsosVmd(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        work = ROOT / 'zig-out/win3-usb-mouse-test'
        work.mkdir(parents=True, exist_ok=True)
        cls.work = work
        cls.vxd = build_vxd(work, work)
        cls.img = le_image(cls.vxd)
        cls.sym = sym_map(work)

    # --- offsets match the TSR ---------------------------------------------
    def test_shared_offsets_match_usoskey_S(self):
        s = (ROOT / 'src/platform/bios/msdos/usoskey.S').read_text()
        sizes = {'.byte': 1, '.word': 2, '.long': 4}

        def dir_size(d, arg):
            if d == '.space':
                return int(arg.split(',')[0], 0)
            if d in ('.ascii', '.asciz', '.string'):
                lit = re.search(r'"((?:[^"\\]|\\.)*)"', arg).group(1)
                n = len(re.sub(r'\\.', 'x', lit))
                return n + (1 if d != '.ascii' else 0)
            return sizes[d]

        # Walk from the `shared:` label, summing every data directive (an
        # optional label may share the line) and recording each label's byte
        # offset from `shared`.
        off, cur, seen = {}, 0, False
        datare = re.compile(r'(\.byte|\.word|\.long|\.space|\.ascii|\.asciz|\.string)\s+(.*)')
        for line in s.splitlines():
            line = line.split('/*')[0].strip()
            if line.startswith('shared:'):
                seen = True
            if not seen:
                continue
            lab = re.match(r'(\w+):', line)
            if lab:
                off[lab.group(1)] = cur
                line = line[lab.end():].strip()
            m = datare.match(line)
            if m:
                cur += dir_size(m.group(1), m.group(2))
            if 'mring' in off and cur > off['mring'] + 128:
                break
        got = {k: off[name] for k, name in
               (('MHEAD', 'mhead'), ('MTAIL', 'mtail'), ('MALIVE', 'malive'),
    ('MCBOFS', 'mcbofs'), ('MRING', 'mring'))}
        self.assertEqual(got, OFF)
        # and the .asm actually uses them
        asm = (ROOT / 'src/platform/win9x/usosvmd.asm').read_text()
        for name, val in OFF.items():
            self.assertRegex(asm, r'OFF_%s\s+equ\s+%d\b' % (name, val))

    # --- LE / DDB / service set --------------------------------------------
    def test_valid_le_vxd_and_ddb(self):
        d = self.vxd.read_bytes()
        le = struct.unpack_from('<I', d, 0x3c)[0]
        self.assertEqual(d[le:le + 2], b'LE')
        b = self.img
        i = b.find(b'USOSVMD ')
        self.assertGreaterEqual(i, 0)
        ddb = i - 12
        self.assertEqual(struct.unpack_from('<H', b, ddb + 4)[0], 0x400)   # SDK 4.0
        self.assertEqual(struct.unpack_from('<I', b, ddb + 20)[0], 0x80000000)  # init order undefined

    def test_service_calls(self):
        calls = set(vxd_calls(self.img))
        self.assertIn((0x0001, 0x03), calls)    # VMM Get_Sys_VM_Handle
        self.assertIn((0x0001, 0x3c), calls)    # VMM Set_Global_Time_Out
        self.assertIn((0x000c, 0x00), calls)    # VMD_Get_Version
        self.assertIn((0x000c, 0x06), calls)    # VMD_Set_Mouse_Data
        self.assertIn((0x000c, 0x03), calls)    # VMD_Post_Pointer_Message

    # --- emulate the drain path --------------------------------------------
    def run_drain(self, mhead, mtail, packets):
        """Lay out the block at 0x20000, run `drain`, return the list of
        (al, dx, dy, edx) posted to VMOUSE and the resulting tail / malive."""
        SYSCB = 0x50000             # fake system-VM control block
        BLK = 0x1000                # the "USKY" block (within 0x600..0x9fc00,
                                    # near the scan start so emulation is short)
        u = Uc(UC_ARCH_X86, UC_MODE_32)
        u.mem_map(0, 0x200000)
        u.mem_write(BASE, self.img)
        # system VM control block: CB_High_Linear (+4) = 0 (identity map)
        u.mem_write(SYSCB + 4, struct.pack('<I', 0))
        # the block
        u.mem_write(BLK, b'USKY' + struct.pack('<H', 4))
        u.mem_write(BLK + OFF['MCBOFS'], struct.pack('<H', 0x1234))
        u.mem_write(BLK + OFF['MHEAD'], bytes([mhead]))
        u.mem_write(BLK + OFF['MTAIL'], bytes([mtail]))
        for idx, pkt in packets.items():
            u.mem_write(BLK + OFF['MRING'] + idx * 4, bytes(pkt))
        posts = []

        def on_intr(uc, n, data):
            eip = uc.reg_read(UC_X86_REG_EIP)
            v = struct.unpack_from('<I', bytes(uc.mem_read(eip, 4)), 0)[0]
            dev, svc = v >> 16, v & 0x7fff
            if (dev, svc) == (1, 3):            # Get_Sys_VM_Handle
                uc.reg_write(UC_X86_REG_EBX, SYSCB)
            elif (dev, svc) == (0xc, 3):        # VMD_Post_Pointer_Message
                posts.append((uc.reg_read(UC_X86_REG_EAX) & 0xff,
                              uc.reg_read(UC_X86_REG_ESI) | 0,
                              uc.reg_read(UC_X86_REG_EDI) | 0,
                              uc.reg_read(UC_X86_REG_EDX)))
            # all VxDcalls are 2-byte INT 20h + 4-byte service dword
            uc.reg_write(UC_X86_REG_EIP, eip + 4)

        u.hook_add(UC_HOOK_INTR, on_intr)
        RET = 0x1f0000                                        # inside the 0..0x200000 map
        u.reg_write(UC_X86_REG_ESP, 0x180000)
        u.mem_write(0x180000, struct.pack('<I', RET))         # return address
        u.mem_write(RET, b'\xf4')                             # HLT (never executed; stop is here)
        u.emu_start(self.sym['drain'], RET, count=200000)
        tail = u.mem_read(BLK + OFF['MTAIL'], 1)[0]
        malive = u.mem_read(BLK + OFF['MALIVE'], 1)[0]
        return posts, tail, malive

    @staticmethod
    def s8(v):
        return v - 0x100000000 if v >= 0x80000000 else v

    def test_drain_moves_and_buttons(self):
        # one packet: left button down, dx=+5, dy=+3 (PS/2 up-positive)
        posts, tail, malive = self.run_drain(1, 0, {0: [0x01, 5, 3, 0]})
        self.assertEqual(len(posts), 1)
        al, esi, edi, edx = posts[0]
        self.assertEqual(al, 0x20)                   # b1 (left)
        self.assertEqual(self.s8(esi), 5)            # dx as read
        self.assertEqual(self.s8(edi), -3)           # dy negated
        self.assertEqual(tail, 1)                    # tail advanced
        self.assertEqual(malive, 18)                 # topped up

    def test_drain_sign_and_button_map(self):
        # dx negative (status bit4), dy negative (bit5), right+middle down
        posts, _, _ = self.run_drain(1, 0, {0: [0x06 | 0x10 | 0x20, 0xFE, 0xFD, 0]})
        al, esi, edi, _ = posts[0]
        self.assertEqual(al, 0x08 | 0x10)            # b2 (right) | b3 (middle)
        self.assertEqual(self.s8(esi), -2)           # 0xFE sign-extended
        self.assertEqual(self.s8(edi), 3)            # dy=0xFD(-3) negated -> +3

    def test_drain_skips_overflow(self):
        posts, tail, _ = self.run_drain(2, 0, {0: [0x40, 9, 9, 0],   # overflow bit
                                               1: [0x00, 1, 0, 0]})
        self.assertEqual(len(posts), 1)              # overflow packet dropped
        self.assertEqual(self.s8(posts[0][1]), 1)
        self.assertEqual(tail, 2)

    def test_drain_empty_ring_posts_nothing(self):
        posts, tail, malive = self.run_drain(0, 0, {})
        self.assertEqual(posts, [])
        self.assertEqual(tail, 0)
        self.assertEqual(malive, 18)                 # still topped up when block found

    # --- the companion driver changes --------------------------------------
    def test_usosmous_vmouse_mode_and_imports(self):
        work = self.work
        com = build_tsr(work, work)
        write_tsr_header(com, work / 'usoskey.elf', work)
        drv = build_mouse_driver(work, work).read_bytes()
        self.assertEqual(ne_imported_modules(drv), ['KERNEL'])
        c = (ROOT / 'src/platform/win3/usosmous.c').read_text()
        self.assertIn('USOSVMD.ON', c)
        self.assertIn('VMDAPI_SET_MOUSE_EVENT_CB', c)
        self.assertRegex(c, r'VMD_DEVICE_ID\s+0x000C')
        self.assertIn('vmd_set_callback', c)

    def test_usoskey_guard_off_when_vxd_present(self):
        k = (ROOT / 'src/platform/win3/usoskey.c').read_text()
        self.assertIn('USOSVMD.ON', k)
        self.assertRegex(k, r'mouse_guard\s*=\s*!usosvmd_on\(\)')


if __name__ == '__main__':
    unittest.main()
