"""usos-reg.exe (tools/windows_usos_reg.c, built by tools/build_windows_usos_reg.py):
compiles it, checks the image (i386, console, PE OS/subsystem 4.00, imports
only kernel32/advapi32 functions present in Windows NT 4.0) and runs
--dry-run on sample set files on the host. Nothing touches the host registry
(no --dry-run-less runs).

    python tools/tests/test_usos_reg.py

Needs the zig toolchain: tools/zig/zig.exe or USOS_ZIG.
"""
from pathlib import Path
import os
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from build_windows_usos_reg import build, zig_path  # noqa: E402

OUT = ROOT / 'zig-out/windows-usos-reg'
SRC = ROOT / 'tools/windows_usos_reg.c'

# Every function here is exported by NT 4.0 RTM kernel32.dll / advapi32.dll.
NT4_ALLOWED = {
    'kernel32.dll': {
        'CloseHandle', 'CreateFileW', 'ExitProcess', 'ExpandEnvironmentStringsW',
        'FlushFileBuffers', 'GetCommandLineW', 'GetCurrentProcess', 'GetCurrentProcessId',
        'GetFileAttributesW', 'GetFileSize', 'GetLastError', 'GetModuleHandleW',
        'GetProcAddress', 'GetStdHandle', 'MultiByteToWideChar', 'ReadFile',
        'SetFilePointer', 'Sleep', 'WideCharToMultiByte', 'WriteFile',
    },
    'advapi32.dll': {
        'AdjustTokenPrivileges', 'GetTokenInformation', 'LookupPrivilegeValueW',
        'OpenProcessToken', 'RegCloseKey', 'RegCreateKeyExW', 'RegDeleteValueW',
        'RegFlushKey', 'RegLoadKeyW', 'RegOpenKeyExW', 'RegQueryValueExW',
        'RegSetValueExW', 'RegUnLoadKeyW',
    },
}
# Newer than NT 4.0: must never be a static import.
FORBIDDEN = {'IsWow64Process', 'GetFileSizeEx', 'RegDeleteKeyExW', 'RegSetKeyValueW',
             'RegGetValueW', 'GetSystemWindowsDirectoryW', 'SetFilePointerEx'}


def parse_pe(b: bytes):
    p = struct.unpack_from('<I', b, 60)[0]
    assert b[p:p + 4] == b'PE\0\0'
    machine, nsec = struct.unpack_from('<HH', b, p + 4)
    optsize = struct.unpack_from('<H', b, p + 20)[0]
    opt = p + 24
    hdr = {
        'machine': machine,
        'magic': struct.unpack_from('<H', b, opt)[0],
        'os': struct.unpack_from('<HH', b, opt + 40),
        'subsys_ver': struct.unpack_from('<HH', b, opt + 48),
        'subsystem': struct.unpack_from('<H', b, opt + 68)[0],
        'checksum': struct.unpack_from('<I', b, opt + 64)[0],
    }
    imp_rva = struct.unpack_from('<I', b, opt + 96 + 8)[0]
    secs = []
    for i in range(nsec):
        s = opt + optsize + 40 * i
        vsize, va, rsize, raw = struct.unpack_from('<IIII', b, s + 8)
        secs.append((va, max(vsize, rsize), raw))

    def off(rva):
        for va, size, raw in secs:
            if va <= rva < va + size:
                return rva - va + raw
        raise ValueError(hex(rva))

    def cstr(rva):
        o = off(rva)
        return b[o:b.index(b'\0', o)].decode('ascii')

    imports = {}
    d = off(imp_rva)
    while True:
        ilt, _, _, name, iat = struct.unpack_from('<IIIII', b, d)
        if not (ilt or name or iat):
            break
        funcs = []
        t = off(ilt or iat)
        while True:
            e = struct.unpack_from('<I', b, t)[0]
            if not e:
                break
            funcs.append(f'#{e & 0xffff}' if e & 0x80000000 else cstr(e + 2))
            t += 4
        imports[cstr(name).lower()] = funcs
        d += 20
    return hdr, imports


SAMPLE = (
    '\ufeff; USOS sample set file\r\n'
    '# comment with a | bar\r\n'
    '\r\n'
    '   \r\n'
    'HKLM\\SOFTWARE\\USOS\\Test|Dec|dword|42\r\n'
    'HKLM\\SOFTWARE\\USOS\\Test|Hex|dword|0xFFFFFFFF\r\n'
    'USER\\Control Panel\\Desktop|Wallpaper|sz|C:\\Windows\\usos.bmp\r\n'
    'USER\\Control Panel\\Desktop||sz|default value\r\n'
    'DEFAULT\\Control Panel\\Keyboard|InitialKeyboardIndicators|sz|2\r\n'
    'HKLM\\SOFTWARE\\USOS\\Test|Path|expand_sz|%SystemRoot%\\system32\r\n'
    'HKLM\\SOFTWARE\\USOS\\Test|Blob|binary|ff,00,1,a0\r\n'
    'HKLM\\SOFTWARE\\USOS\\Test|Empty|binary|\r\n'
    'HKLM\\SOFTWARE\\USOS\\Test|Gone|del|\r\n'
    'hklm\\SOFTWARE\\USOS\\Zaż\u00f3łć|Name|sz|' + 'x' * 65 + '\r\n'
    'USER\\Software\\USOS|Empty|sz|\n'  # LF-only last line
)


class UsosReg(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not zig_path(ROOT).is_file():
            raise unittest.SkipTest('zig toolchain missing (tools/zig/zig.exe or USOS_ZIG)')
        cls.exe = build(ROOT, OUT)
        cls.hdr, cls.imports = parse_pe(cls.exe.read_bytes())
        cls.tmp = tempfile.TemporaryDirectory()

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_set(self, content: bytes, *extra, name='set.reg'):
        path = Path(self.tmp.name) / name
        path.write_bytes(content)
        r = subprocess.run([str(self.exe), *extra, str(path)], capture_output=True, timeout=30)
        return r.returncode, r.stdout.decode('utf-8', 'replace')

    def test_i386_console_nt4_image(self):
        self.assertEqual(self.hdr['machine'], 0x14c)
        self.assertEqual(self.hdr['magic'], 0x10b)
        self.assertEqual(self.hdr['subsystem'], 3)
        self.assertEqual(self.hdr['os'], (4, 0))
        self.assertEqual(self.hdr['subsys_ver'], (4, 0))
        self.assertNotEqual(self.hdr['checksum'], 0)

    def test_no_sse_instructions(self):
        # NT 4.0 never enables SSE: a movaps (0f 28 / 0f 29) faulted with
        # c000001d in QEMU (2026-10-12); the build targets i586.
        data = self.exe.read_bytes()
        self.assertNotIn(b'\x0f\x28', data)
        self.assertNotIn(b'\x0f\x29', data)

    def test_imports_only_nt4_functions(self):
        self.assertEqual(set(self.imports), set(NT4_ALLOWED))
        for dll, funcs in self.imports.items():
            for f in funcs:
                self.assertIn(f, NT4_ALLOWED[dll], f'{dll}!{f} is not on the NT 4.0 allow-list')
                self.assertNotIn(f, FORBIDDEN)
        self.assertIn('RegLoadKeyW', self.imports['advapi32.dll'])
        self.assertIn('GetProcAddress', self.imports['kernel32.dll'])
        self.assertIn(b'IsWow64Process', self.exe.read_bytes())

    def test_dry_run_sample(self):
        code, out = self.run_set(SAMPLE.encode('utf-8'), '--dry-run')
        self.assertEqual(code, 0, out)
        dry = [line for line in out.splitlines() if line.startswith('[usos-reg] DRY ')]
        self.assertEqual(len(dry), 11, out)
        self.assertIn('DRY line 5 HKLM\\SOFTWARE\\USOS\\Test|Dec dword 0x0000002a (42)', out)
        self.assertIn('|Hex dword 0xffffffff (4294967295)', out)
        self.assertIn('DRY line 7 USER\\Control Panel\\Desktop|Wallpaper sz "C:\\Windows\\usos.bmp"', out)
        self.assertIn('DRY line 8 USER\\Control Panel\\Desktop| sz "default value"', out)
        self.assertIn('DEFAULT\\Control Panel\\Keyboard|InitialKeyboardIndicators sz "2"', out)
        self.assertIn('|Path expand_sz "%SystemRoot%\\system32"', out)
        self.assertIn('|Blob binary (4 bytes)', out)
        self.assertIn('|Empty binary (0 bytes)', out)
        self.assertIn('|Gone del', out)
        self.assertIn('HKLM\\SOFTWARE\\USOS\\Zaż\u00f3łć|Name sz (65 chars)', out)
        self.assertNotIn('x' * 65, out)
        self.assertIn('DRY line 15 USER\\Software\\USOS|Empty sz ""', out)
        self.assertIn('11 entries parsed, nothing written', out)

    def test_dry_run_hive_override_and_log(self):
        log = Path(self.tmp.name) / 'sub-log.txt'
        log.write_bytes(b'previous\r\n')
        code, out = self.run_set(b'USER\\Software\\USOS|A|dword|1\n', '--log', str(log), '--dry-run',
                                 '--hive', r'C:\offline\NTUSER.DAT')
        self.assertEqual(code, 0)
        self.assertEqual(out, '')
        text = log.read_bytes().decode('utf-8')
        self.assertTrue(text.startswith('previous\r\n'), text)
        self.assertIn(r'default user hive C:\offline\NTUSER.DAT', text)
        self.assertNotIn('HKEY_CURRENT_USER', text)  # --hive: offline, no HKCU
        self.assertIn('1 entries parsed', text)
        if os.environ.get('PROCESSOR_ARCHITEW6432') or os.environ.get('PROCESSOR_ARCHITECTURE') == 'AMD64':
            self.assertIn('WOW64: using the 64-bit registry view', text)

    def test_dry_run_default_hive_resolution(self):
        code, out = self.run_set(b'USER\\Software\\USOS|A|dword|1\n', '--dry-run')
        self.assertEqual(code, 0, out)
        self.assertRegex(out, r'default user hive [A-Za-z]:\\.*\\NTUSER\.DAT')
        self.assertNotIn('%', out.split('default user hive')[1].splitlines()[0])

    def test_malformed_sets(self):
        cases = {
            b'HKLM\\A|B|dword|4294967296\n': 'line 1: dword: larger than',
            b'; ok\nHKLM\\A|B|dword|0x123456789\n': 'line 2: dword: more than 8 hex digits',
            b'HKLM\\A|B|dword|12a\n': 'line 1: dword: not a decimal',
            b'HKLM\\A|B|dword|\n': 'line 1: dword: empty number',
            b'HKCU\\A|B|sz|x\n': 'line 1: root must be HKLM, USER or DEFAULT',
            b'HKLM|B|sz|x\n': 'line 1: first field must be ROOT\\Key\\Path',
            b'HKLM\\|B|sz|x\n': 'line 1: empty key path',
            b'HKLM\\A\\\\B|B|sz|x\n': 'line 1: empty key path component',
            b'HKLM\\A\\|B|sz|x\n': 'line 1: empty key path component',
            b'HKLM\\A|B|sz\n': "line 1: expected 4 fields",
            b'HKLM\\A|B|sz|x|y\n': 'line 1: more than 4 fields',
            b'HKLM\\A|B|qword|1\n': 'line 1: type must be',
            b'HKLM\\A|B|SZ|1\n': 'line 1: type must be',
            b'HKLM\\A|B|del|x\n': 'line 1: del takes no data',
            b'HKLM\\A|B|binary|fff\n': 'line 1: binary:',
            b'HKLM\\A|B|binary|ff,\n': 'line 1: binary:',
            b'HKLM\\A|B|binary|zz\n': 'line 1: binary:',
            b'\r\n\r\nHKLM\\A|B|sz|ok\r\n\r\nnonsense\r\n': 'line 5: expected 4 fields',
            'HKLM\\A|B|sz|x\n'.encode('utf-16-le'): 'NUL byte',
        }
        for content, expect in cases.items():
            with self.subTest(content=content):
                code, out = self.run_set(content, '--dry-run')
                self.assertEqual(code, 1, out)
                self.assertIn(expect, out)
                if b'\0' not in content:
                    self.assertIn('set file rejected, nothing written', out)
                self.assertNotIn('DRY', out)

    def test_all_errors_reported(self):
        code, out = self.run_set(b'HKX\\A|B|sz|x\nHKLM\\A|B|sz|ok\nHKLM\\A|B|dword|x\n', '--dry-run')
        self.assertEqual(code, 1)
        self.assertIn('line 1:', out)
        self.assertIn('line 3:', out)
        self.assertNotIn('line 2:', out)

    def test_bad_arguments(self):
        for args in ([], ['--bogus', 'x'], ['a', 'b'], ['--log']):
            with self.subTest(args=args):
                r = subprocess.run([str(self.exe), *args], capture_output=True, timeout=30)
                self.assertEqual(r.returncode, 1)
                self.assertIn(b'usage: usos-reg.exe', r.stdout)
                self.assertIn(b'GPL-3.0-or-later', r.stdout)
        r = subprocess.run([str(self.exe), '--dry-run', str(Path(self.tmp.name) / 'missing.reg')],
                           capture_output=True, timeout=30)
        self.assertEqual(r.returncode, 1)
        self.assertIn(b'cannot open the set file', r.stdout)

    def test_source_licence_header(self):
        text = SRC.read_text(encoding='utf-8')
        self.assertIn('GPL-3.0-or-later', text)
        self.assertIn('Copyright (C) 2026 Maksymilian and the USOS Authors', text)

    def test_micro_linux_stages_it(self):
        text = (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8')
        self.assertIn('"usr/lib/usos/usos-reg.exe"', text)


if __name__ == '__main__':
    unittest.main()
