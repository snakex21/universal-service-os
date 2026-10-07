"""tools/nt4/usosvbe: the NT 4.0 VESA miniport + frame buffer display driver
(own GPL code). Host-only, no Microsoft files: both committed binaries are
PE 4.00 images whose imports resolve on NT 4.0 RTM and SP6a (export-name
fixtures in tools/tests/data, videoprt.sys and win32k.sys included), the
display driver keeps to the routines NT 4.0's own framebuf.dll uses. Not
wired into the NT4 flow yet (README: logon hang under QEMU OVMF + CSMWrap).
"""
from __future__ import annotations
from pathlib import Path
import struct, sys, unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import check_nt4_driver_imports as nt4  # noqa: E402

DRV = ROOT / 'tools/nt4/usosvbe'
SYS = DRV / 'bin/i386/usosvbe.sys'
DLL = DRV / 'bin/i386/usosvbe.dll'
FIXTURES = [HERE / 'data/nt4rtm_exports.txt', HERE / 'data/nt4sp6a_exports.txt']
# The routines NT 4.0 RTM's framebuf.dll imports from win32k.sys.
FRAMEBUF_SET = {'EngAllocMem', 'EngAssociateSurface', 'EngCreateBitmap', 'EngCreatePalette',
                'EngDeletePalette', 'EngDeleteSurface', 'EngDeviceIoControl', 'EngFreeMem'}


class Binary(unittest.TestCase):
    def test_imports_resolve_on_rtm_and_sp6a(self):
        for f in FIXTURES:
            tables = nt4.parse(f.read_text())
            self.assertIn('videoprt.sys', tables, f.name)
            self.assertIn('win32k.sys', tables, f.name)
            r = nt4.check(tables, [SYS, DLL])
            self.assertEqual(r['usosvbe.sys']['missing'], [], f.name)
            self.assertEqual(r['usosvbe.dll']['missing'], [], f.name)
            self.assertEqual(r['usosvbe.sys']['subsystem'], '4.00')
            self.assertEqual(r['usosvbe.dll']['subsystem'], '4.00')
            self.assertEqual(r['usosvbe.sys']['modules'], ['ntoskrnl.exe', 'videoprt.sys'])
            self.assertEqual(r['usosvbe.dll']['modules'], ['win32k.sys'])

    def test_display_driver_uses_framebuf_routines_only(self):
        _, imports = nt4.pe(DLL)
        self.assertLessEqual({fn for _, fn in imports}, FRAMEBUF_SET)

    def test_display_driver_entry_is_native(self):
        # win32k calls the image entry point (DrvEnableDriver); no exports,
        # native subsystem, like NT 4.0's own display drivers.
        b = DLL.read_bytes()
        opt = struct.unpack_from('<I', b, 60)[0] + 24
        self.assertNotEqual(struct.unpack_from('<I', b, opt + 16)[0], 0)
        self.assertEqual(struct.unpack_from('<H', b, opt + 68)[0], 1)

    def test_no_c_runtime(self):
        for f in (SYS, DLL):
            data = f.read_bytes()
            for name in (b'memset', b'memcpy', b'__security_check_cookie', b'msvcrt'):
                self.assertNotIn(name, data, f.name)

    def test_dll_is_i386_dll(self):
        b = DLL.read_bytes()
        p = struct.unpack_from('<I', b, 60)[0]
        self.assertEqual(b[p:p + 4], b'PE\0\0')
        self.assertTrue(struct.unpack_from('<H', b, p + 22)[0] & 0x2000)   # IMAGE_FILE_DLL


if __name__ == '__main__':
    unittest.main()
