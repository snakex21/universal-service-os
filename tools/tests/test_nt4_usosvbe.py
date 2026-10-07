"""tools/nt4/usosvbe: the NT 4.0 VESA miniport + frame buffer display driver
(own GPL code). Host-only, no Microsoft files: both committed binaries are
PE 4.00 images whose imports resolve on NT 4.0 RTM and SP6a (export-name
fixtures in tools/tests/data, videoprt.sys and win32k.sys included), the
display driver keeps to the routines NT 4.0's own framebuf.dll uses.
The flow ships only the miniport; the display DLL is NT 4.0's own
framebuf.dll from the user's CD (usosvbe.dll stays WIP: logon hang under
QEMU OVMF + CSMWrap, README).
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


TARGET = ROOT / 'tools/nt4_csmwrap_target.sh'
BUILD = ROOT / 'tools/build_micro_linux.py'


def heredoc(text, name):
    start = text.index(f'"$usos/{name}" <<\'EOF\'\n')
    start = text.index('\n', start) + 1
    return text[start:text.index('\nEOF\n', start)]


class Flow(unittest.TestCase):
    def setUp(self):
        self.text = TARGET.read_text(encoding='utf-8')

    def test_only_the_miniport_is_shipped(self):
        self.assertIn('"$LIB/nt4/USOSVBE.SYS"', self.text)
        self.assertNotIn('USOSVBE.DLL', self.text)
        build = BUILD.read_text(encoding='utf-8')
        self.assertIn('("tools/nt4/usosvbe/bin/i386/usosvbe.sys", "usr/lib/usos/nt4/USOSVBE.SYS")', build)
        self.assertNotIn('usosvbe.dll', build)
        # Nothing Microsoft in the repo: framebuf.dll only comes from the user's CD.
        self.assertEqual([p for p in (ROOT / 'tools').rglob('framebuf.d*')], [])

    def test_framebuf_comes_from_the_cd(self):
        self.assertIn('for name in FRAMEBUF.DL_ framebuf.dl_; do [ -f "$i386/$name" ]', self.text)
        self.assertIn('cp "$framebuf" "$usos/FRAMEBUF.DL_"', self.text)

    def test_vesa_registry(self):
        reg = heredoc(self.text, 'VESA.REG')
        self.assertTrue(reg.startswith('REGEDIT4\n'))
        line = next(l for l in reg.splitlines() if l.startswith('"InstalledDisplayDrivers"=hex(7):'))
        raw = bytes(int(x, 16) for x in line.split(':', 1)[1].split(','))
        self.assertEqual(raw, b'framebuf\0\0')     # NT 4.0 regedit widens each byte
        self.assertIn('"Group"="Video"', reg)
        for k, v in (('BitsPerPel', 16), ('XResolution', 1024), ('YResolution', 768)):
            self.assertIn(f'"DefaultSettings.{k}"=dword:{v:08x}', reg)
        self.assertIn('"Start"=dword:00000004', reg[reg.index(r'Services\VgaStart]'):])
        self.assertNotIn('VgaSave', reg)           # kept: full-screen consoles + /basevideo
        self.assertNotIn('usosvbe', heredoc(self.text, 'DRIVERS.REG'))

    def test_post_cmd_falls_back_to_vga(self):
        lines = heredoc(self.text, 'POST.CMD').splitlines()
        i = lines.index(r'if exist %SystemRoot%\system32\framebuf.dll goto vesa')
        self.assertEqual(lines[i + 1], r'if not exist C:\USOS\NT4\FRAMEBUF.DL_ goto novesa')
        self.assertTrue(lines[i + 2].startswith(r'%SystemRoot%\system32\expand.exe C:\USOS\NT4\FRAMEBUF.DL_ '))
        self.assertEqual(lines[i + 3], r'if not exist %SystemRoot%\system32\framebuf.dll goto novesa')
        self.assertEqual(lines[i + 4], ':vesa')
        vesa = lines.index(r'%SystemRoot%\regedit.exe /s C:\USOS\NT4\VESA.REG')
        self.assertIn(r'if not exist %SystemRoot%\system32\drivers\usosvbe.sys goto novesa', lines[i:vesa])
        self.assertLess(lines.index(r'%SystemRoot%\regedit.exe /s C:\USOS\NT4\DRIVERS.REG'), i)
        self.assertLess(vesa, lines.index(':novesa'))
        self.assertLess(lines.index(':novesa'), lines.index(':vesadone'))
        self.assertLess(lines.index(':vesadone'), lines.index(':nosp'))


if __name__ == '__main__':
    unittest.main()
