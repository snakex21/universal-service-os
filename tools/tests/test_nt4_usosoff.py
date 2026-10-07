"""tools/nt4/usosoff: the NT 4.0 reboot/shutdown helper run at the end of an
unattended NT4 install. Checks the committed binary with plain struct: i386
console PE marked 4.00, and imports only NT 4.0 RTM kernel32/advapi32/user32
functions."""
from pathlib import Path
import struct
import unittest

ROOT = Path(__file__).resolve().parents[2]
EXE = ROOT / 'tools/nt4/usosoff/bin/i386/usosoff.exe'
SRC = ROOT / 'tools/nt4/usosoff/src/usosoff.c'

DLLS = {'kernel32.dll', 'advapi32.dll', 'user32.dll'}
ALLOWED = {
    'ExitWindowsEx', 'OpenProcessToken', 'LookupPrivilegeValueA',
    'AdjustTokenPrivileges', 'GetCurrentProcess', 'GetCommandLineA',
    'ExitProcess', 'GetStdHandle', 'WriteFile', 'GetModuleHandleA',
    'GetProcAddress', 'CloseHandle', 'GetLastError',
}


def parse(b: bytes):
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


class Usosoff(unittest.TestCase):
    def setUp(self):
        self.hdr, self.imports = parse(EXE.read_bytes())

    def test_i386_console_nt4_image(self):
        self.assertEqual(self.hdr['machine'], 0x14c)
        self.assertEqual(self.hdr['magic'], 0x10b)
        self.assertEqual(self.hdr['subsystem'], 3)
        self.assertEqual(self.hdr['os'][0], 4)
        self.assertEqual(self.hdr['subsys_ver'][0], 4)

    def test_imports_only_nt4_rtm_functions(self):
        self.assertTrue(self.imports)
        self.assertLessEqual(set(self.imports), DLLS)
        for dll, funcs in self.imports.items():
            for f in funcs:
                self.assertIn(f, ALLOWED, f'{dll}!{f}')
        self.assertIn('ExitWindowsEx', self.imports.get('user32.dll', []))

    def test_source_licence_header(self):
        text = SRC.read_text(encoding='utf-8')
        self.assertIn('GPL-3.0-or-later', text)
        self.assertIn('Copyright (C) 2026 Maksymilian and the USOS Authors', text)


if __name__ == '__main__':
    unittest.main()
