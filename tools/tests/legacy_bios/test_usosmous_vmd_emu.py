"""USOSMOUS.DRV in VMOUSE mode (USOSVMD.VXD v2), run in Unicorn on the
harness of test_usosmous_wheel_emu.py: C:\\USOS9X\\USOSVMD.ON present or
not, INT 2Fh AX=1684h answering for VMOUSE (BX=000Ch) and USOSVMD (BX=0,
ES:DI -> "USOSVMD "), the two PM APIs as stubs, DPMI 0200h / 0302h for the
direct INT 15h path. Checks:

  * VMOUSE mode only with the flag, both APIs and the VxD in "minidriver"
    mode; the shared block is handed to the VxD (function 1);
  * the BIOS registration goes through the real-mode INT 15h vector (0302h,
    so a V86 INT 15h hook cannot swallow it) and C207h names the VxD's V86
    callback, never the bridge's mcb (the Me callback hazard);
  * USER's event procedure goes to VMOUSE (VMDAPI 3); the timer sends only
    the wheel (AX=0800h), never motion or buttons (VMOUSE does those);
  * USOSVMDMODE answers 1 (USOSKEY.DRV leaves its DOS-box guard off),
    USOSPAUSE does nothing, Disable takes the callback back and switches
    the BIOS mouse off through the same path;
  * observer mode, no VxD or no flag: the plain path, unchanged.
"""
from pathlib import Path
import struct
import sys
import unittest
from unicorn.x86_const import *

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_usosmous_wheel_emu as W  # noqa: E402

VXD_CB = (0xF123, 0x0456)            # the VxD's V86 callback (seg, off)
INT15 = (0xF000, 0xF859)             # the system VM's real-mode INT 15h vector
VMD_SEG_OFF = 0x0200                 # stub offsets in STUB_SEG
VXD_SEG_OFF = 0x0210


class VmdEmu(W.Emu):
    def __init__(self, drv, dos_version, bios_id, flag=True, vmouse=True, vxd=True, vxd_mode=1):
        super().__init__(drv, dos_version, bios_id)
        self.flag, self.vmouse, self.vxd, self.vxd_mode = flag, vmouse, vxd, vxd_mode
        self.stubs['VmdApi'] = VMD_SEG_OFF
        self.stubs['VxdApi'] = VXD_SEG_OFF
        for off in (VMD_SEG_OFF, VXD_SEG_OFF):
            self.u.mem_write(W.STUB_SEG * 16 + off, b'\xcb')          # retf
        self.lookups, self.vmd_calls, self.vxd_calls, self.c15 = [], [], [], []

    def on_stub(self, u, address, size, _):
        name = next(k for k, v in self.stubs.items() if W.STUB_SEG * 16 + v == address)
        if name == 'OpenFile':
            off, seg = self.arg(3), self.arg(4)
            raw = bytes(u.mem_read(seg * 16 + off, 64)).split(b'\0')[0].decode()
            u.reg_write(UC_X86_REG_AX, 1 if (self.flag and raw.upper().endswith('USOSVMD.ON')) else 0xFFFF)
            return
        cf = 0
        if name == 'VmdApi':
            ax = u.reg_read(UC_X86_REG_AX)
            self.vmd_calls.append((ax, u.reg_read(UC_X86_REG_CX), u.reg_read(UC_X86_REG_DX)))
        elif name == 'VxdApi':
            ax = u.reg_read(UC_X86_REG_AX)
            self.vxd_calls.append((ax, u.reg_read(UC_X86_REG_BX), u.reg_read(UC_X86_REG_CX)))
            if ax == 1:
                ok = (u.reg_read(UC_X86_REG_BX), u.reg_read(UC_X86_REG_CX)) == (W.SHARED_SEG, W.SHARED_OFF)
                u.reg_write(UC_X86_REG_AX, 0x5655 if ok else 0)
                u.reg_write(UC_X86_REG_BX, VXD_CB[0])
                u.reg_write(UC_X86_REG_CX, VXD_CB[1])
                u.reg_write(UC_X86_REG_DX, self.vxd_mode)
                cf = 0 if ok else 1
            elif ax == 2:
                dst = u.reg_read(UC_X86_REG_ES) * 16 + u.reg_read(UC_X86_REG_DI)
                u.mem_write(dst, b'UV\x02' + bytes([self.vxd_mode]) + bytes(60))
                u.reg_write(UC_X86_REG_CX, 64)
        else:
            return super().on_stub(u, address, size, _)
        fl = u.reg_read(UC_X86_REG_EFLAGS)
        u.reg_write(UC_X86_REG_EFLAGS, (fl | 1) if cf else (fl & ~1))

    def on_int(self, u, intno, _):
        ax = u.reg_read(UC_X86_REG_AX)
        if intno == 0x2F and ax == 0x1684:
            bx = u.reg_read(UC_X86_REG_BX)
            es, di = u.reg_read(UC_X86_REG_ES), u.reg_read(UC_X86_REG_DI)
            name = bytes(u.mem_read(es * 16 + di, 8)) if bx == 0 else None
            self.lookups.append((bx, name))
            if bx == 0x000C and self.vmouse:
                u.reg_write(UC_X86_REG_ES, W.STUB_SEG)
                u.reg_write(UC_X86_REG_DI, VMD_SEG_OFF)
            elif bx == 0 and name == b'USOSVMD ' and self.vxd:
                u.reg_write(UC_X86_REG_ES, W.STUB_SEG)
                u.reg_write(UC_X86_REG_DI, VXD_SEG_OFF)
            return                                  # not found: ES:DI unchanged
        if intno == 0x31 and ax == 0x0200:
            assert u.reg_read(UC_X86_REG_BX) & 0xFF == 0x15
            u.reg_write(UC_X86_REG_CX, INT15[0])
            u.reg_write(UC_X86_REG_DX, INT15[1])
            u.reg_write(UC_X86_REG_EFLAGS, u.reg_read(UC_X86_REG_EFLAGS) & ~1)
            return
        if intno == 0x31 and ax in (0x0300, 0x0302):
            rm = u.reg_read(UC_X86_REG_ES) * 16 + u.reg_read(UC_X86_REG_DI)
            regs = bytearray(u.mem_read(rm, 0x32))
            eax, = struct.unpack_from('<I', regs, 0x1C)
            ebx, = struct.unpack_from('<I', regs, 0x10)
            es = struct.unpack_from('<H', regs, 0x22)[0]
            ip, cs = struct.unpack_from('<HH', regs, 0x2A)
            self.c15.append(('direct' if ax == 0x0302 else 'int', eax & 0xFFFF, ebx & 0xFFFF, es,
                             (cs, ip) if ax == 0x0302 else None))
            if ax == 0x0302:
                assert u.reg_read(UC_X86_REG_BX) == 0 and u.reg_read(UC_X86_REG_CX) == 0
                u.reg_write(UC_X86_REG_AX, 0x0300)
                u.reg_write(UC_X86_REG_BX, 0x0015)
        return super().on_int(u, intno, _)


class VmdMode(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        work = W.ROOT / 'zig-out/win3-usb-mouse-vmd-test'
        work.mkdir(parents=True, exist_ok=True)
        cls.drv = W.build_mouse_driver(work, work).read_bytes()

    def start(self, **kw):
        e = VmdEmu(self.drv, kw.pop('dos', 0x070A), 0, **kw)
        e.export('INQUIRE', (0, W.MOUSEINFO_SEG))
        e.export('ENABLE', (e.stubs['EventProc'], W.STUB_SEG))
        return e

    def test_vmouse_mode_registers_the_vxd_callback_directly(self):
        e = self.start()
        self.assertIn((0x000C, None), e.lookups)
        self.assertIn((0, b'USOSVMD '), e.lookups)
        self.assertIn((1, W.SHARED_SEG, W.SHARED_OFF), e.vxd_calls)        # attach the shared block
        c207 = [c for c in e.c15 if c[1] == 0xC207]
        self.assertEqual(c207[-1], ('direct', 0xC207, VXD_CB[1], VXD_CB[0], INT15))
        self.assertNotIn(0x0400, [c[2] for c in c207])                     # never the bridge's mcb
        # every BIOS call after the decision went the direct way
        first = next(i for i, c in enumerate(e.c15) if c[0] == 'direct')
        self.assertTrue(all(c[0] == 'direct' for c in e.c15[first:]))
        self.assertEqual(e.c15[-1][1:3], (0xC200, 0x0100))
        self.assertEqual(e.vmd_calls[-1], (3, W.STUB_SEG, e.stubs['EventProc']))   # USER's proc to VMOUSE
        self.assertIsNotNone(e.timer_proc)
        self.assertEqual(e.shared(W.MSTATE)[0], 1)

    def test_timer_sends_only_the_wheel(self):
        e = self.start()
        e.push_packets([(0x09, 8, 0, 0), (0x08, 0, 3, 0xFF), (0x08, 0, 0, 0xFF)])
        e.poll()
        self.assertEqual(e.events, [(0x0800, 0, 0, 240)])                  # two notches up, no motion/buttons
        e.events.clear()
        e.push_packets([(0x0A, 5, 5, 0)])
        e.poll()
        self.assertEqual(e.events, [])
        self.assertEqual(e.shared(W.MTAIL), e.shared(W.MHEAD))             # ring drained

    def test_mode_export_pause_and_disable(self):
        e = self.start(dos=0x0800)
        self.assertEqual(e.export('USOSVMDMODE'), 1)
        n = len(e.c15)
        e.export('USOSPAUSE', (1,))
        self.assertEqual(len(e.c15), n)                                    # no pause in VMOUSE mode
        self.assertEqual(e.shared(W.MSTATE)[0], 1)
        e.export('DISABLE')
        self.assertEqual(e.vmd_calls[-1], (3, 0, 0))                       # callback taken back
        self.assertEqual([c[:4] for c in e.c15[n:]], [('direct', 0xC200, 0, 0), ('direct', 0xC207, 0, 0)])

    def test_vmd_info(self):
        e = self.start()
        e.export('USOSVMDINFO')
        seg, off = e.u.reg_read(UC_X86_REG_DX), e.u.reg_read(UC_X86_REG_AX)
        raw = bytes(e.u.mem_read(seg * 16 + off, 82))
        ver, checked, flag, vapi, xapi, mode, active, cbok = raw[:8]
        cb, derr, nstat = struct.unpack_from('<IHH', raw, 8)
        self.assertEqual((ver, checked, flag, vapi, xapi, mode, active, cbok), (1, 1, 1, 1, 1, 1, 1, 1))
        self.assertEqual(cb, (VXD_CB[0] << 16) | VXD_CB[1])
        self.assertEqual((derr, nstat), (0, 64))
        self.assertEqual(raw[18:22], b'UV\x02\x01')                        # the VxD's block copied

    def plain(self, e):
        c207 = [c for c in e.c15 if c[1] == 0xC207]
        self.assertEqual(c207[-1][:4], ('int', 0xC207, 0x0400, W.SHARED_SEG))   # bridge mcb, INT path
        self.assertFalse(any(c[0] == 'direct' for c in e.c15))
        self.assertEqual([c for c in e.vmd_calls if c[0] == 3], [])
        e.push_packets([(0x08, 8, 0, 0)])
        e.poll()
        self.assertEqual(e.events, [(0x0001, 4, 0, 3)])                    # motion from this driver
        self.assertEqual(e.export('USOSVMDMODE'), 0)

    def test_observer_keeps_the_plain_path(self):
        self.plain(self.start(vxd_mode=2))

    def test_no_vxd_keeps_the_plain_path(self):
        e = self.start(vxd=False)
        self.plain(e)
        self.assertEqual(e.vxd_calls, [])

    def test_no_flag_asks_nothing(self):
        e = self.start(flag=False)
        self.plain(e)
        self.assertEqual(e.lookups, [])


if __name__ == '__main__':
    unittest.main()
