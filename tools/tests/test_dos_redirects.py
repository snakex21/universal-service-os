"""Host test: no "File creation error" from a redirection in the DOS batch files.

Copyright (C) 2026 Maksymilian and the USOS Authors
SPDX-License-Identifier: GPL-3.0-or-later

MS-DOS COMMAND.COM prints "File creation error" when it cannot open the
target of `>` / `>>` (a missing directory, an invalid path). It opens the
target before it runs the command, also on an `IF` line whose condition is
false (install.cmd l.221). The Windows 3.0a install on the X470 showed the
message (2026-10-24, docs: scratch micron-w31-netscape.md), so every batch
file of the MS-DOS / Windows 1.x-3.x install and start path is checked
statically:
  1. no `IF ... >file` / `IF ... >>file` (NUL is fine): use IF ... GOTO;
  2. every redirection target is in the root of a drive, in a directory
     made earlier in the same file (`md DIR` or `if not exist DIR\\NUL md
     DIR`), or in a directory that exists by construction (ALLOW, with the
     reason).
The lines tools/dos_win3_menu.sh adds to WINMENU.BAT (Winsock profile) are
checked the same way.
"""
from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MSDOS = ROOT / 'src/platform/bios/msdos'
LIB = ROOT / 'tools/dos_win3_menu.sh'
SH = shutil.which('sh') or shutil.which('bash')

DEVICES = {'nul', 'con', 'prn', 'aux', 'lpt1', 'lpt2', 'lpt3', 'com1', 'com2', 'com3', 'com4'}
# Directories that exist whenever the file runs, per source file.
ALLOW = {
    # PREPDOS.BAT (prepare_files.cmd) makes C:\DOS; INSTALL.BAT stops unless
    # its READY.TAG is there (install.cmd l.19).
    'install.cmd': {'c:\\dos'},
    # Runs as C:\NET\NETSTART.BAT (INSTALL.BAT copies it there).
    'network_start.cmd': {'c:\\net'},
    'network_start_queue.cmd': {'c:\\net'},
    # %2 = the target directory, made by PREPDOS.BAT (prepare_files.cmd l.2)
    # before it calls COPYDOS.BAT / UNPACK.BAT.
    'copy_group.cmd': {'%2'},
    'unpack_file.cmd': {'%2'},
    # Runs as C:\USOSW3\WINMENU.BAT.
    'windows_menu.cmd': {'c:\\usosw3'},
}
REDIRECT = re.compile(r'(>>?)\s*([^\s<>|]+)')
MD = re.compile(r'^(?:if not exist (\S+)\\nul )?md (\S+)$', re.I)


def problems(name: str, text: str) -> list[str]:
    made: set[str] = set(ALLOW.get(name, ()))
    out = []
    for no, raw in enumerate(text.replace('\r\n', '\n').split('\n'), 1):
        line = raw.strip().lstrip('@')
        low = line.lower()
        if not line or low.startswith(('rem ', 'rem\t', ':')) or low == 'rem':
            continue
        m = MD.match(line)
        if m:
            made.add(m.group(2).lower().rstrip('\\'))
            continue
        for op, target in REDIRECT.findall(line):
            t = target.lower()
            if t in DEVICES or t.rstrip(':') in DEVICES:
                continue
            where = f'{name}:{no}: {line}'
            if low.startswith('if '):
                out.append(where + ' -> IF with a redirection into a file (use IF ... GOTO)')
            d = t.rsplit('\\', 1)[0] if '\\' in t else ''
            if d in ('', 'c:', 'a:', 'd:') or re.fullmatch(r'[a-z]:', d):
                continue
            if d not in made:
                out.append(where + f' -> directory {d} not made before this line')
    return out


class Redirects(unittest.TestCase):
    def test_batch_sources(self):
        files = sorted(MSDOS.glob('*.cmd'))
        self.assertGreater(len(files), 10)
        found = []
        for path in files:
            found += problems(path.name, path.read_text(encoding='ascii'))
        self.assertEqual(found, [])

    def test_checker_catches_both_patterns(self):
        bad = 'if exist C:\\X echo a>>C:\\NET\\WIN16\\STAGE.LOG\r\necho b>C:\\USOSW3\\WINRUN.ON\r\n'
        self.assertEqual(len(problems('x.cmd', bad)), 3)
        good = ('if not exist C:\\USOSW3\\NUL md C:\\USOSW3\r\necho b>C:\\USOSW3\\WINRUN.ON\r\n'
                'if exist C:\\X goto skip\r\necho a>>C:\\AUTOEXEC.BAT\r\n:skip\r\nver >nul\r\n')
        self.assertEqual(problems('x.cmd', good), [])

    @unittest.skipIf(SH is None, 'no POSIX shell on this host')
    def test_winsock_winmenu_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            u, c, src = t / 'c/USOSDOS', t / 'c', t / 'winsock16'
            (u / 'WINSETUP').mkdir(parents=True)
            src.mkdir()
            for name, source in (('WINMENU.BAT', 'windows_menu.cmd'), ('W3AUTO.BAT', 'windows_auto.cmd')):
                (u / name).write_bytes((MSDOS / source).read_bytes())
            (u / 'WINSETUP/SETUP.INF').write_bytes(b'[setup]\r\n')
            for name in ('WINSOCK.DLL', 'GETHTTP.EXE', 'TESTLOAD.EXE', 'USOSPKTQ.COM', 'NETSTART.BAT', 'WINSOCK.TXT'):
                (src / name).write_bytes(b'x')
            (t / 'DOS.INI').write_bytes(b'[dos]\r\nwinsock=yes\r\n')
            r = subprocess.run([SH, '-c', '. "$1"; dos_winsock_apply "$2" "$3" "$4" "$5"', 'sh', LIB.as_posix(),
                                u.as_posix(), (t / 'DOS.INI').as_posix(), src.as_posix(), c.as_posix()],
                               capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stderr)
            menu = (u / 'WINMENU.BAT').read_bytes().decode('ascii')
            self.assertIn('STAGE.LOG', menu)
            self.assertEqual(problems('windows_menu.cmd', menu), [])


if __name__ == '__main__':
    unittest.main()
