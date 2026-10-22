"""tools/nt4/usosvbe NT 3.x build (build-nt3.cmd, -DUSOSVBE_NT3) and its
NT 3.5/3.51 wiring (docs/nt3-vesa-2026-10-14.md). Host-only, no Microsoft
files: the committed miniport is a PE 3.10 image whose imports resolve on the
NT 3.1, 3.5 and 3.51 kernels and video port drivers (export-name fixtures in
tools/tests/data); the display driver stays the CD's own framebuf.dll, staged
by nt4_csmwrap_target.sh and registered by usosnt3.exe.
"""
from __future__ import annotations
from pathlib import Path
import re
import struct
import sys
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
from check_nt4_driver_imports import parse  # noqa: E402
from check_nt52_driver_imports import pe  # noqa: E402

SYS = ROOT / 'tools/nt4/usosvbe/bin/nt3/i386/usosvbe.sys'
SRC = ROOT / 'tools/nt4/usosvbe/src/mini/usosvbe.c'
BUILD_NT3 = ROOT / 'tools/nt4/usosvbe/build-nt3.cmd'
USOSNT3 = ROOT / 'tools/nt3/usosnt3/src/usosnt3.c'
USOSNT3_EXE = ROOT / 'tools/nt3/usosnt3/bin/i386/usosnt3.exe'
TARGET = ROOT / 'tools/nt4_csmwrap_target.sh'
BUILD = ROOT / 'tools/build_micro_linux.py'
FIXTURES = {'3.1': HERE / 'data/nt31_exports.txt', '3.5': HERE / 'data/nt35_exports.txt',
            '3.51': HERE / 'data/nt351_exports.txt'}


class Binary(unittest.TestCase):
    def test_imports_resolve_on_nt31_nt35_nt351(self):
        _, imports = pe(SYS)
        self.assertEqual(sorted({m.lower() for m, _ in imports}), ['ntoskrnl.exe', 'videoprt.sys'])
        for ver, path in FIXTURES.items():
            tables = parse(path.read_text(encoding='utf-8'))
            self.assertIn('videoprt.sys', tables, ver)
            for kernel in ('ntoskrnl.exe', 'ntkrnlmp.exe'):
                view = {'ntoskrnl.exe': tables[kernel], 'videoprt.sys': tables['videoprt.sys']}
                missing = [f'{m}!{n}' for m, n in imports if n not in view[m.lower()]]
                self.assertEqual(missing, [], f'NT {ver} {kernel}')

    def test_pe_version_310(self):
        b = SYS.read_bytes()
        opt = struct.unpack_from('<I', b, 60)[0] + 24
        self.assertEqual(struct.unpack_from('<HH', b, opt + 40), (3, 10))
        self.assertEqual(struct.unpack_from('<HH', b, opt + 48), (3, 10))

    def test_no_c_runtime_no_nt4_only_import(self):
        data = SYS.read_bytes()
        for name in (b'memset', b'memcpy', b'__security_check_cookie', b'PsGetCurrentProcessId'):
            self.assertNotIn(name, data)
        self.assertIn('usosvbe 1.1-nt3'.encode('utf-16-le'), data)


class Source(unittest.TestCase):
    def test_nt3_sizes_and_checks(self):
        src = SRC.read_text(encoding='utf-8')
        for want in ('#define NT3_HW_INIT_DATA_SIZE 0x20', '#define NT3_CONFIG_INFO_SIZE 0x38',
                     'd.HwInitDataSize = NT3_HW_INIT_DATA_SIZE;',
                     'if (ci->Length < NT3_CONFIG_INFO_SIZE) return ERROR_INVALID_PARAMETER;',
                     'ci->VdmPhysicalVideoMemoryAddress.QuadPart = 0xA0000;',
                     'if (x->Int10Ok && (!valid(0xC0000) || !valid(0xC0FFF))) {', 'if (depth == 15) return;',
                     'if (basevideo()) return 0xC000000EUL;', 't[0].Name = L"SystemStartOptions";'):
            self.assertIn(want, src)
        # The NT 4.0 build keeps its own values.
        self.assertIn('d.HwInitDataSize = SIZE_OF_NT4_VIDEO_HW_INITIALIZATION_DATA;', src)
        cmd = BUILD_NT3.read_text(encoding='utf-8')
        self.assertIn('set "C_DEFINES=-DUSOSVBE_NT3"', cmd)
        self.assertIn('pe_nt4_version.py" --version 3.10', cmd)


def function_body(text: str, name: str) -> str:
    # post() returns int since the NT 3.5x network / client policy gate.
    start = next(i for i in (text.find(f'static void {name}(void)\n{{'),
                             text.find(f'static int {name}(void)\n{{')) if i >= 0)
    return text[start:text.index('\n}\n', start)]


class Flow(unittest.TestCase):
    def test_target_stages_miniport_and_cd_framebuf(self):
        text = TARGET.read_text(encoding='utf-8')
        nt3 = text[text.index('elif [ -n "$nt3" ]; then\nusos="$work/c/USOS/NT3"'):]
        nt3 = nt3[:nt3.index('> "$usos/SOURCE.TXT"')]
        self.assertIn('cp "$drv/USOSVBE.SYS" "$usos/USOSVBE.SYS"', nt3)
        self.assertIn('cp "$framebuf" "$usos/FRAMEBUF.DL_"', nt3)
        self.assertIn('for name in FRAMEBUF.DL_ framebuf.dl_; do [ -f "$i386/$name" ]', nt3)
        self.assertIn("log 'display: VGA (640x480x16; no USOSVBE.SYS in this build)'", nt3)
        build = BUILD.read_text(encoding='utf-8')
        self.assertIn('("tools/nt4/usosvbe/bin/nt3/i386/usosvbe.sys", "usr/lib/usos/nt3/USOSVBE.SYS")', build)
        # Nothing Microsoft in the repo.
        self.assertEqual([p for p in (ROOT / 'tools').rglob('framebuf.d*')], [])

    def test_usosnt3_registers_usosvbe(self):
        src = USOSNT3.read_text(encoding='utf-8')
        post = function_body(src, 'post')
        # vesa() and the display profile run after DRIVERS.TXT and the
        # network / client policy steps, right before a successful return.
        self.assertTrue(post.rstrip().endswith('vesa();\n    display_profile();\n    return 1;'))
        self.assertLess(post.index('write_file("DRIVERS.TXT", g_text);'), post.index('vesa();'))
        body = function_body(src, 'vesa')
        self.assertLess(src.index('static void vesa(void)\n{'), src.index('static void WINAPI handler(DWORD control)'))
        for want in ('static const WCHAR drivers[] = L"framebuf\\0";',
                     'RegSetValueExW(h, L"InstalledDisplayDrivers", 0, REG_MULTI_SZ',
                     'set_dword("usosvbe", NULL, "Type", 1);', 'set_dword("usosvbe", NULL, "Start", 1);',
                     'set_sz("usosvbe", "Group", REG_SZ, "Video");',
                     '"\\\\expand.exe " DIR "FRAMEBUF.DL_ "', 'say("vesa on\\r\\n");',
                     'say("vesa off: no framebuf.dll, VGA stays\\r\\n");'):
            self.assertIn(want, body)
        names = re.findall(r'"DefaultSettings\.(\w+)"', body)
        self.assertEqual(names, ['BitsPerPel', 'XResolution', 'YResolution', 'VRefresh', 'Interlaced', 'Flags'])
        self.assertIn('{ 16, 1024, 768, 60, 0, 0, 0 }', body)
        # VgaStart (NT 3.51/3.5, Group "Video Init") off when present; VgaSave stays on.
        self.assertIn('set_dword("VgaStart", NULL, "Start", 4);', body)
        self.assertIn('SVC_KEY "VgaStart"', body)
        self.assertNotIn('"VgaSave"', body)
        _, imports = pe(USOSNT3_EXE)
        self.assertIn(('advapi32.dll', 'RegSetValueExW'), imports)
        self.assertIn(('kernel32.dll', 'CreateProcessA'), imports)


if __name__ == '__main__':
    unittest.main()
