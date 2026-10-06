"""USB mouse for Windows 9x under CSMWrap: the INT 15h C207h callback of the
real USOSKEY.COM (shared block version 4) in Unicorn, the USOSMOUS.DRV NE
exports, and its wiring into the 98 SE / 98 install (INSTALL.BAT, payload)."""
from pathlib import Path
import struct
import sys
import unittest
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INTR
from unicorn.x86_const import *

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
from build_win3_usb_keyboard import build_tsr, build_mouse_driver, elf_symbols, write_tsr_header

SEG = 0x2000
# Shared block offsets (usoskey.S, version 4).
MHEAD, MTAIL, MALIVE, MCB, MDROPPED, MIGNORED, MPACKETS, MLAST, MRING = 396, 397, 398, 400, 402, 404, 408, 412, 420


class UsosMouse(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        work = ROOT / 'zig-out/win3-usb-mouse-test'
        work.mkdir(parents=True, exist_ok=True)
        com = build_tsr(work, work)
        cls.code = com.read_bytes()
        cls.sym = elf_symbols(work / 'usoskey.elf')
        write_tsr_header(com, work / 'usoskey.elf', work)
        cls.drv = build_mouse_driver(work, work).read_bytes()

    def machine(self):
        u = Uc(UC_ARCH_X86, UC_MODE_16)
        u.mem_map(0, 0x100000)
        u.mem_write(SEG * 16 + 0x100, self.code)
        for reg in (UC_X86_REG_CS, UC_X86_REG_DS, UC_X86_REG_ES):
            u.reg_write(reg, SEG)
        u.reg_write(UC_X86_REG_SS, 0x3000)
        u.hook_add(UC_HOOK_INTR, lambda uc, n, d: self.fail(f'unexpected INT {n:02x}'))
        return u

    def shared(self, u, off, size=1):
        return bytes(u.mem_read(SEG * 16 + self.sym['shared'] + off, size))

    def set_shared(self, u, off, data):
        u.mem_write(SEG * 16 + self.sym['shared'] + off, data)

    def callback(self, u, status, x, y):
        """Far call as SeaBIOS's invoke_mouse_handler: push status, X, Y, Z
        (words), lcall, the caller pops 8 bytes."""
        sp = 0xff00
        frame = struct.pack('<HHHHHH', 0x7000, 0x0000, 0, y, x, status)  # ret IP, ret CS, Z, Y, X, status
        u.mem_write(0x30000 + sp, frame)
        u.reg_write(UC_X86_REG_SP, sp)
        u.reg_write(UC_X86_REG_BP, 0x1234)
        u.reg_write(UC_X86_REG_AX, 0xaaaa)
        u.reg_write(UC_X86_REG_BX, 0xbbbb)
        u.reg_write(UC_X86_REG_SI, 0x5151)
        u.reg_write(UC_X86_REG_CS, SEG)
        mcb = struct.unpack('<H', self.shared(u, MCB, 2))[0]
        self.assertEqual(mcb, self.sym['mcb'])
        u.emu_start(SEG * 16 + mcb, 0x7000, count=200)
        self.assertEqual((u.reg_read(UC_X86_REG_CS), u.reg_read(UC_X86_REG_IP)), (0, 0x7000))
        self.assertEqual(u.reg_read(UC_X86_REG_SP), sp + 4)        # retf only: the BIOS pops its 4 words
        self.assertEqual([u.reg_read(r) for r in (UC_X86_REG_BP, UC_X86_REG_AX, UC_X86_REG_BX, UC_X86_REG_SI)],
                         [0x1234, 0xaaaa, 0xbbbb, 0x5151])

    def test_block_version_and_layout(self):
        u = self.machine()
        self.assertEqual(self.shared(u, 0, 6), b'USKY\x04\x00')
        self.assertEqual(self.sym['mring'] - self.sym['shared'], MRING)
        self.assertEqual(self.sym['in9'] - self.sym['shared'], MRING + 128)
        self.assertLess(self.sym['mcb'], self.sym['resident_end'])

    def test_packets_go_to_the_ring_only_while_the_driver_polls(self):
        u = self.machine()
        self.callback(u, 0x09, 0x05, 0xfe)          # no consumer: counted, not stored
        self.assertEqual(self.shared(u, MHEAD, 2), b'\x00\x00')
        self.assertEqual(struct.unpack('<H', self.shared(u, MIGNORED, 2))[0], 1)
        self.set_shared(u, MALIVE, b'\x12')
        self.callback(u, 0x19, 0xfb, 0x03)          # left button, X -5, Y +3
        self.assertEqual(self.shared(u, MHEAD, 2), b'\x01\x00')
        self.assertEqual(self.shared(u, MRING, 3), b'\x19\xfb\x03')
        self.assertEqual(self.shared(u, MLAST, 3), b'\x19\xfb\x03')
        self.assertEqual(struct.unpack('<I', self.shared(u, MPACKETS, 4))[0], 2)

    def test_full_ring_drops(self):
        u = self.machine()
        self.set_shared(u, MALIVE, b'\x12')
        for i in range(31):
            self.callback(u, 0x08, i, 0)
        self.assertEqual(self.shared(u, MHEAD, 1), bytes([31]))
        self.callback(u, 0x08, 0x40, 0)             # 32 slots, one stays free
        self.assertEqual(self.shared(u, MHEAD, 1), bytes([31]))
        self.assertEqual(struct.unpack('<H', self.shared(u, MDROPPED, 2))[0], 1)
        self.set_shared(u, MTAIL, bytes([5]))       # the driver took 5
        self.callback(u, 0x0a, 0x41, 0x42)
        self.assertEqual(self.shared(u, MHEAD, 1), b'\x00')
        self.assertEqual(self.shared(u, MRING + 31 * 4, 3), b'\x0a\x41\x42')

    def test_mouse_driver_exports(self):
        d = self.drv
        ne = struct.unpack_from('<H', d, 0x3c)[0]
        self.assertEqual(d[ne:ne + 2], b'NE')
        names, i = {}, ne + struct.unpack_from('<H', d, ne + 0x26)[0]
        while d[i]:
            n = d[i]
            names[d[i + 1:i + 1 + n].decode()] = struct.unpack_from('<H', d, i + 1 + n)[0]
            i += n + 3
        # Module name MOUSE (USER imports the mouse driver by it), DDK ordinals.
        self.assertEqual(names, {'MOUSE': 0, 'INQUIRE': 1, 'ENABLE': 2, 'DISABLE': 3, 'MOUSEGETINTVECT': 4, 'WEP': 5})

    def test_install_wiring(self):
        install = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='latin-1')
        auto = [l for l in install.splitlines() if 'AUTOEXEC.BAT' in l and l.startswith('ECHO @')]
        copy_line = next(i for i, l in enumerate(auto) if 'USOSMOUS.DRV COPY' in l or 'USOSMOUS.DRV IF EXIST' in l)
        fix_line = next(i for i, l in enumerate(auto) if 'U9FIX.COM /CSM' in l)
        self.assertLess(copy_line, fix_line, 'the driver must be in SYSTEM before U9FIX names it')
        self.assertIn('IF "%U9SYS%"=="98SE" GOTO MOUSEOK', install)
        # 98 (first edition) and 95 get the mouse driver too; Me drops it.
        self.assertIn('IF "%U9SYS%"=="98" GOTO MOUSEOK', install)
        self.assertIn('IF "%U9SYS%"=="95" GOTO MOUSEOK', install)
        self.assertNotIn('IF "%U9SYS%"=="ME" GOTO MOUSEOK', install)
        sys.path.insert(0, str(ROOT / 'tools'))
        import build_win9x_support
        self.assertIn('USOSMOUS.DRV', build_win9x_support.FILES)
        self.assertIn('"USOSMOUS.DRV"', (ROOT / 'src/platform/bios/dos_native_iso.zig').read_text())
        self.assertIn('win9x/USOSMOUS.DRV', (ROOT / 'installer/cmd/usos-payload-pack/main.go').read_text())


if __name__ == '__main__':
    unittest.main()
