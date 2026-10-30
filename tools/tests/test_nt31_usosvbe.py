"""usosvbe NT 3.1 build (build-nt31.cmd, -DUSOSVBE_NT3 -DUSOSVBE_NT31) and its
native NT 3.1 wiring (docs/nt-native-plan.md section 8.7). Host-only, no
Microsoft files: the committed miniport is a PE 3.10 image whose imports
resolve on the NT 3.1 kernel and video port (export-name fixture); the
display driver is the CD's own framebuf.dll, expanded by
nt4_csmwrap_target.sh and registered by usosnt3.exe /vesa31.
"""
from __future__ import annotations
from pathlib import Path
import struct
import sys
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
from check_nt4_driver_imports import parse  # noqa: E402
from check_nt52_driver_imports import pe  # noqa: E402

SYS31 = ROOT / 'tools/nt4/usosvbe/bin/nt31/i386/usosvbe.sys'
SYS3 = ROOT / 'tools/nt4/usosvbe/bin/nt3/i386/usosvbe.sys'
SRC = ROOT / 'tools/nt4/usosvbe/src/mini/usosvbe.c'
BUILD31 = ROOT / 'tools/nt4/usosvbe/build-nt31.cmd'
USOSNT3 = ROOT / 'tools/nt3/usosnt3/src/usosnt3.c'
USOSNT3_EXE = ROOT / 'tools/nt3/usosnt3/bin/i386/usosnt3.exe'
TARGET = ROOT / 'tools/nt4_csmwrap_target.sh'
BUILD = ROOT / 'tools/build_micro_linux.py'
NT31 = HERE / 'data/nt31_exports.txt'


def body(text: str, start: str) -> str:
    at = text.index(start)
    return text[at:text.index('\n}\n', at)]


class Binary(unittest.TestCase):
    def test_imports_resolve_on_nt31(self):
        _, imports = pe(SYS31)
        tables = parse(NT31.read_text(encoding='utf-8'))
        self.assertEqual(sorted({m.lower() for m, _ in imports}), ['ntoskrnl.exe', 'videoprt.sys'])
        for kernel in ('ntoskrnl.exe', 'ntkrnlmp.exe'):
            view = {'ntoskrnl.exe': tables[kernel], 'videoprt.sys': tables['videoprt.sys']}
            self.assertEqual([f'{m}!{n}' for m, n in imports if n not in view[m.lower()]], [], kernel)

    def test_pe_310_version_string_no_crt(self):
        b = SYS31.read_bytes()
        opt = struct.unpack_from('<I', b, 60)[0] + 24
        self.assertEqual(struct.unpack_from('<HH', b, opt + 40), (3, 10))
        self.assertEqual(struct.unpack_from('<HH', b, opt + 48), (3, 10))
        self.assertIn('usosvbe 1.2-nt31'.encode('utf-16-le'), b)
        self.assertIn(' first='.encode('utf-16-le'), b)
        for word in ('UsosVbeEntry', ' entry', ' isa=', ' eisa=', ' mca=', ' pci='):
            self.assertIn(word.encode('utf-16-le'), b)
        for name in (b'memset', b'memcpy', b'__security_check_cookie', b'PsGetCurrentProcessId'):
            self.assertNotIn(name, b)

    def test_nt31_driver_entry_trace_and_buses(self):
        src = SRC.read_text(encoding='utf-8')
        fn = body(src, 'ULONG __stdcall DriverEntry(PVOID ctx1, PVOID ctx2)')
        self.assertIn('static const INTERFACE_TYPE buses[] = { Isa, Eisa, MicroChannel, PCIBus };', fn)
        self.assertIn('for (i = 0; i < 4 && st != NO_ERROR; i++) {', fn)
        self.assertLess(fn.index('entry_cat(USOSVBE_VERSION L" entry", 0, FALSE);'), fn.index('basevideo()'))
        _, imports = pe(SYS31)
        self.assertIn(('ntoskrnl.exe', 'RtlWriteRegistryValue'), [(m.lower(), n) for m, n in imports])

    def test_nt35x_binary_untouched(self):
        # The NT 3.5 / 3.51 build (X470 PASS) is a separate file.
        self.assertNotIn('1.2-nt31'.encode('utf-16-le'), SYS3.read_bytes())


class Source(unittest.TestCase):
    def test_start_mode_preference(self):
        src = SRC.read_text(encoding='utf-8')
        fn = body(src, 'static void prefer_first(PDEVEXT x)')
        self.assertLess(fn.index('{ 1920, 1080, 16 }'), fn.index('{ 1024, 768, 16 }'))
        self.assertLess(fn.index('{ 1024, 768, 16 }'), fn.index('{ 800, 600, 16 }'))
        self.assertIn('x->Modes[0] = t;', fn)
        q = body(src, 'static void query(PDEVEXT x)')
        # after the sort, before the list is published / cached
        self.assertLess(q.index('mode_less(&t, &x->Modes[j - 1])'), q.index('if (x->QueryOk) prefer_first(x);'))
        self.assertLess(q.index('if (x->QueryOk) prefer_first(x);'), q.index('UsosVbeModes'))
        cmd = BUILD31.read_text(encoding='utf-8')
        self.assertIn('set "C_DEFINES=-DUSOSVBE_NT3 -DUSOSVBE_NT31"', cmd)
        self.assertIn('bin\\nt31\\i386\\usosvbe.sys', cmd)


class Flow(unittest.TestCase):
    def test_usosnt3_vesa31(self):
        src = USOSNT3.read_text(encoding='utf-8')
        fn = body(src, 'static void vesa31(void)\n{')
        for want in ('set_dword("usosvbe", NULL, "Start", 0);', 'set_dword("usosvbe", NULL, "Tag", 2);',
                     'set_sz("usosvbe", "Group", REG_SZ, "Video");',
                     'RegSetValueExW(h, L"InstalledDisplayDrivers", 0, REG_MULTI_SZ',
                     'set_dword("usosvbe", "Device0", "VgaCompatible", 0);',
                     'CopyFileA(DIR "FRAMEBUF.DLL", dst, FALSE)', 'say("vesa off: no framebuf.dll, VGA stays\\r\\n");'):
            self.assertIn(want, fn)
        # all-zero DEVMODE -> framebuf takes the miniport's first mode; vga stays.
        self.assertNotIn('DefaultSettings', fn)
        self.assertNotIn('"vga"', fn)
        self.assertIn('if (lstrcmpA(opt, "vesa31") == 0) {', src)
        self.assertIn('vesa31'.encode(), USOSNT3_EXE.read_bytes())

    def test_target_native31_stages_and_post_cmd(self):
        text = TARGET.read_text(encoding='utf-8')
        fn = body(text, 'nt31_native() {')
        self.assertIn('[ -r "$LIB/nt3/USOSVBE31.SYS" ]', fn)
        self.assertIn('--szdd-get "$fb31" "$usos/FRAMEBUF.DLL"', fn)
        self.assertIn('cp "$LIB/nt3/USOSVBE31.SYS" "$usos/USOSVBE.SYS"', fn)
        self.assertIn("vesa31='C:\\USOS\\NT3\\USOSNT3.EXE /vesa31'", fn)
        self.assertIn('ENVIRON["VESA31"]', fn)
        build = BUILD.read_text(encoding='utf-8')
        self.assertIn('("tools/nt4/usosvbe/bin/nt31/i386/usosvbe.sys", "usr/lib/usos/nt3/USOSVBE31.SYS")', build)
        self.assertEqual([p for p in (ROOT / 'tools').rglob('framebuf.d*')], [])

    def test_post_cmd_order(self):
        # The awk of nt31_native on a POST.CMD tail: /vesa31 then /finish31
        # right before DONE.TXT (run with a POSIX awk when one is present).
        import shutil
        import subprocess
        awk = shutil.which('awk')
        if not awk:
            self.skipTest('no awk')
        text = TARGET.read_text(encoding='utf-8')
        line = next(ln for ln in text.splitlines() if 'ENVIRON["VESA31"]' in ln)
        prog = line[line.index("'") + 1:line.rindex("'")]
        env = {'VESA31': 'C:\\USOS\\NT3\\USOSNT3.EXE /vesa31'}
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / 'post.awk'
            script.write_text(prog, encoding='utf-8')
            out = subprocess.run([awk, '-v', 'BINMODE=3', '-f', str(script)], input=b'@echo off\r\necho done > C:\\USOS\\NT3\\DONE.TXT\r\n',
                                 capture_output=True, env=env, check=True).stdout
        self.assertEqual(out.split(b'\r\n')[:4], [b'@echo off', b'C:\\USOS\\NT3\\USOSNT3.EXE /vesa31',
                                                  b'C:\\USOS\\NT3\\USOSNT3.EXE /finish31',
                                                  b'echo done > C:\\USOS\\NT3\\DONE.TXT'])


if __name__ == '__main__':
    unittest.main()
