"""Host test: Program Manager icons for the staged DOS programs (Windows 3.x).

Copyright (C) 2026 Maksymilian and the USOS Authors
SPDX-License-Identifier: GPL-3.0-or-later

DATA Systems\\DOS\\MS-DOS\\Programs\\<FOLDER>\\USOSICON.TXT lines
"Name",C:\\PROGRAMS\\<FOLDER>\\FILE.EXE -> tools/dos_win3_menu.sh
dos_program_icons (called by dos_csmwrap_target.sh after the programs were
copied) -> the end of the Main group of WINSETUP\\SETUP.INF, which Windows
Setup turns into icons. The SETUP.INF excerpts below keep the layout of the
real files: Windows 3.0a EN ("Main,1" -> [Main], tab after the comma) and
Windows 3.1 PL / 3.11 EN / WfW 3.11 PL ("group3=<name>,1" -> [group3]).
"""
from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / 'tools/dos_win3_menu.sh'
SH = shutil.which('sh') or shutil.which('bash')

INF_30 = (
    '[progman.groups]\r\nMain,1\r\nAccessories\r\nGames\r\n\r\n'
    '[Main]\r\n"File Manager",\tWINFILE.EXE\r\n"Control Panel",\tCONTROL.EXE\r\n'
    '"DOS Prompt",\tCOMMAND.COM, PROGMAN.EXE, 1\r\n"Read Me",\t"NOTEPAD.EXE README.TXT"\r\n\r\n'
    '[Accessories]\r\n"Write",\t\tWRITE.EXE\r\n'
).encode('ascii')
INF_31PL = (
    '[progman.groups]\r\ngroup3=Grupa\u00a0g\u0088\u00a2wna,1\r\ngroup4=Akcesoria\r\ngroup5=Gry\r\ngroup1=Autostart\r\n\r\n'
    '; Progman DDE control section. This section controls the progman DDE and defines which\r\n'
    "; .exe's will be added to which groups.\r\n;\r\n"
    '[group3]\r\n"Mened\u00bfer plik\u00a2w",     WINFILE.EXE\r\n"Schowek", CLIPBRD.EXE\r\n\r\n'
    '[group4]\r\n"Write",  WRITE.EXE\r\n'
).encode('latin-1')  # CP852 bytes as in the Polish SETUP.INF
INF_311EN = (
    '[progman.groups]\r\ngroup3=Main,1\r\ngroup4=Accessories\r\ngroup5=Games\r\ngroup1=StartUp\r\n\r\n'
    '[group3]\r\n"File Manager",     WINFILE.EXE\r\n"Control Panel",    CONTROL.EXE\r\n'
).encode('ascii')  # Main is the last section: icons at the end of the file
INF_203 = b'[data]\r\nversion=2.03\r\n\r\n[display]\r\nvga\r\n'


def lf(data: bytes) -> bytes:
    return data.replace(b'\r\n', b'\n')


@unittest.skipIf(SH is None, 'no POSIX shell on this host')
class ProgramIcons(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-icons-'))
        self.u = self.tmp / 'USOSDOS'
        (self.u / 'WINSETUP').mkdir(parents=True)
        self.p = self.u / 'PROGRAMS'
        self.p.mkdir()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def program(self, folder: str, files: tuple[str, ...], icons: str | None, icon_name='USOSICON.TXT'):
        d = self.p / folder
        for f in files:
            (d / f).parent.mkdir(parents=True, exist_ok=True)
            (d / f).write_bytes(b'MZ')
        if icons is not None:
            (d / icon_name).write_bytes(icons.replace('\n', '\r\n').encode('latin-1'))

    def run_icons(self, inf: bytes | None) -> subprocess.CompletedProcess:
        if inf is not None:
            (self.u / 'WINSETUP/SETUP.INF').write_bytes(inf)
        script = f'. "{LIB.as_posix()}"; dos_program_icons "$1"'
        r = subprocess.run([SH, '-c', script, 'sh', self.u.as_posix()], capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        # no helper files left next to the start files
        self.assertEqual(sorted(p.name for p in self.u.iterdir()), ['PROGRAMS', 'WINSETUP'])
        return r

    def inf(self) -> bytes:
        return lf((self.u / 'WINSETUP/SETUP.INF').read_bytes())

    def test_main_group_detection(self):
        for inf, group in ((INF_30, 'Main'), (INF_31PL, 'group3'), (INF_311EN, 'group3'), (INF_203, '')):
            path = self.u / 'WINSETUP/SETUP.INF'
            path.write_bytes(inf)
            r = subprocess.run([SH, '-c', f'. "{LIB.as_posix()}"; dos_main_group "$1"', 'sh', path.as_posix()],
                               capture_output=True, text=True, timeout=30)
            self.assertEqual(r.stdout.strip(), group, inf[:40])

    def test_win30_main_group(self):
        self.program('NC', ('NC.EXE',), '; Norton Commander\n"Norton Commander",C:\\PROGRAMS\\NC\\NC.EXE\n')
        self.program('Games', ('PRINCE/PRINCE.EXE', 'DOOM.BAT'),
                     '"Prince of Persia", c:\\programs\\games\\prince\\prince.exe\n"Doom",C:\\PROGRAMS\\GAMES\\DOOM.BAT\n\n')
        r = self.run_icons(INF_30)
        self.assertIn('Program icons: 3 added to the Main group (Main) of SETUP.INF', r.stdout)
        main = self.inf().split(b'[Main]\n')[1].split(b'\n\n')[0].split(b'\n')
        self.assertEqual(main[:4], [b'"File Manager",\tWINFILE.EXE', b'"Control Panel",\tCONTROL.EXE',
                                    b'"DOS Prompt",\tCOMMAND.COM, PROGMAN.EXE, 1', b'"Read Me",\t"NOTEPAD.EXE README.TXT"'])
        self.assertEqual(sorted(main[4:]), [b'"Doom", C:\\PROGRAMS\\GAMES\\DOOM.BAT',
                                            b'"Norton Commander", C:\\PROGRAMS\\NC\\NC.EXE',
                                            b'"Prince of Persia", C:\\PROGRAMS\\GAMES\\PRINCE\\PRINCE.EXE'])
        # the blank line before [Accessories] and that section stay as they were
        self.assertIn(b'\n\n[Accessories]\n"Write",\t\tWRITE.EXE\n', self.inf())
        raw = (self.u / 'WINSETUP/SETUP.INF').read_bytes()
        self.assertIn(b'"Norton Commander", C:\\PROGRAMS\\NC\\NC.EXE\r\n', raw)

    def test_win31_polish_bytes_kept(self):
        self.program('NC', ('NC.EXE',), '"Norton Commander",C:\\PROGRAMS\\NC\\NC.EXE\n')
        r = self.run_icons(INF_31PL)
        self.assertIn('(group3)', r.stdout)
        out = self.inf()
        self.assertIn('group3=Grupa\u00a0g\u0088\u00a2wna,1\n'.encode('latin-1'), out)
        self.assertIn('[group3]\n"Mened\u00bfer plik\u00a2w",     WINFILE.EXE\n"Schowek", CLIPBRD.EXE\n'
                      '"Norton Commander", C:\\PROGRAMS\\NC\\NC.EXE\n\n[group4]\n'.encode('latin-1'), out)
        self.assertEqual(lf(INF_31PL).replace(b'"Norton Commander", C:\\PROGRAMS\\NC\\NC.EXE\n', b''),
                         out.replace(b'"Norton Commander", C:\\PROGRAMS\\NC\\NC.EXE\n', b''))

    def test_main_section_last_in_file(self):
        self.program('NC', ('NC.EXE',), '"NC",C:\\PROGRAMS\\NC\\NC.EXE')  # no final newline
        self.run_icons(INF_311EN)
        self.assertTrue(self.inf().endswith(b'"Control Panel",    CONTROL.EXE\n"NC", C:\\PROGRAMS\\NC\\NC.EXE\n'))

    def test_bad_lines_skipped(self):
        lines = [
            '"Good",C:\\PROGRAMS\\TOOLS\\GOOD.EXE',
            '"Other folder",C:\\PROGRAMS\\NC\\NC.EXE',
            '"Long name part",C:\\PROGRAMS\\TOOLS\\LONGNAME1.EXE',
            '"Long ext",C:\\PROGRAMS\\TOOLS\\GOOD.EXEC',
            '"Text file",C:\\PROGRAMS\\TOOLS\\README.TXT',
            '"Missing",C:\\PROGRAMS\\TOOLS\\MISSING.EXE',
            '"Bad (name)",C:\\PROGRAMS\\TOOLS\\GOOD.COM',
            'No quotes,C:\\PROGRAMS\\TOOLS\\GOOD.COM',
            '"Spaces",C:\\PROGRAMS\\TOOLS\\MY APP.EXE',
            '"Escape",C:\\PROGRAMS\\TOOLS\\..\\..\\COMMAND.COM',
            '"Twice",c:\\programs\\tools\\good.exe',
            '"Pol\u00f3wka",C:\\PROGRAMS\\TOOLS\\GOOD.COM',
            '"",C:\\PROGRAMS\\TOOLS\\GOOD.COM',
        ]
        self.program('TOOLS', ('GOOD.EXE', 'GOOD.COM', 'README.TXT', 'LONGNAME1.EXE'), '\n'.join(lines) + '\n')
        self.program('NC', ('NC.EXE',), None)
        r = self.run_icons(INF_30)
        self.assertIn('Program icons: "Good" -> C:\\PROGRAMS\\TOOLS\\GOOD.EXE', r.stdout)
        self.assertIn('Program icons: 1 added to the Main group (Main) of SETUP.INF', r.stdout)
        skipped = [l for l in r.stdout.splitlines() if ' skipped: ' in l]
        self.assertEqual([int(l.split(' line ')[1].split()[0]) for l in skipped], list(range(2, 14)), r.stdout)
        self.assertIn('line 6 skipped: C:\\PROGRAMS\\TOOLS\\MISSING.EXE was not staged', r.stdout)
        self.assertIn('line 11 skipped: C:\\PROGRAMS\\TOOLS\\GOOD.EXE listed twice', r.stdout)
        self.assertIn('line 12 skipped: not plain ASCII', r.stdout)
        self.assertEqual(self.inf().count(b'PROGRAMS'), 1)

    def test_already_listed_and_folder_names(self):
        inf = INF_30.replace(b'"File Manager"', b'"NC", C:\\PROGRAMS\\NC\\NC.EXE\r\n"File Manager"')
        self.program('NC', ('NC.EXE',), '"NC",C:\\PROGRAMS\\NC\\NC.EXE\n')
        self.program('Long Folder Name', ('X.EXE',), '"X",C:\\PROGRAMS\\LONG FOLDER NAME\\X.EXE\n')
        self.program('lower', ('x.exe',), '"Lower",C:\\PROGRAMS\\LOWER\\X.EXE\n', icon_name='usosicon.txt')
        r = self.run_icons(inf)
        self.assertIn('NC\\USOSICON.TXT line 1 skipped: C:\\PROGRAMS\\NC\\NC.EXE is in SETUP.INF already', r.stdout)
        self.assertIn('folder Long Folder Name is not an 8.3 name', r.stdout)
        self.assertIn('"Lower" -> C:\\PROGRAMS\\LOWER\\X.EXE', r.stdout)
        self.assertEqual(self.inf().count(b'C:\\PROGRAMS\\NC\\NC.EXE'), 1)

    def test_limit(self):
        files = tuple(f'P{i}.EXE' for i in range(35))
        self.program('MANY', files, ''.join(f'"P{i}",C:\\PROGRAMS\\MANY\\P{i}.EXE\n' for i in range(35)))
        r = self.run_icons(INF_30)
        self.assertIn('Program icons: 30 added', r.stdout)
        self.assertEqual(r.stdout.count('more than 30 icons'), 5)

    def test_no_main_group_or_nothing_to_do(self):
        self.program('NC', ('NC.EXE',), '"NC",C:\\PROGRAMS\\NC\\NC.EXE\n')
        r = self.run_icons(INF_203)
        self.assertIn('no Program Manager Main group in SETUP.INF (Windows 1.x/2.x), 1 icon(s) not added', r.stdout)
        self.assertEqual((self.u / 'WINSETUP/SETUP.INF').read_bytes(), INF_203)
        # programs without USOSICON.TXT: no output, SETUP.INF byte-identical
        shutil.rmtree(self.p / 'NC')
        self.program('NC', ('NC.EXE',), None)
        r = self.run_icons(INF_30)
        self.assertEqual(r.stdout, '')
        self.assertEqual((self.u / 'WINSETUP/SETUP.INF').read_bytes(), INF_30)

    def test_minimum_version(self):
        # optional third field: the oldest Windows the program runs on
        lines = ('"Netscape",C:\\PROGRAMS\\NETSCAPE\\NETSCAPE.EXE,3.1\n'
                 '"Opera", C:\\PROGRAMS\\NETSCAPE\\OPERA.EXE , 3.11\n'
                 '"Any",C:\\PROGRAMS\\NETSCAPE\\ANY.EXE,3.0\n'
                 '"Bad",C:\\PROGRAMS\\NETSCAPE\\ANY.EXE,95\n'
                 '"Plain",C:\\PROGRAMS\\NETSCAPE\\PLAIN.EXE\n')
        self.program('NETSCAPE', ('NETSCAPE.EXE', 'OPERA.EXE', 'ANY.EXE', 'PLAIN.EXE'), lines)
        for version, added in (('3.0', ('ANY', 'PLAIN')), ('3.1', ('NETSCAPE', 'ANY', 'PLAIN')),
                               ('3.11', ('NETSCAPE', 'OPERA', 'ANY', 'PLAIN')), ('', ('NETSCAPE', 'OPERA', 'ANY', 'PLAIN'))):
            (self.u / 'WINSETUP/SETUP.INF').write_bytes(INF_30)
            script = f'. "{LIB.as_posix()}"; dos_program_icons "$1" "$2"'
            r = subprocess.run([SH, '-c', script, 'sh', self.u.as_posix(), version], capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stderr)
            out = self.inf()
            for exe in ('NETSCAPE', 'OPERA', 'ANY', 'PLAIN'):
                entry = ('C:\\PROGRAMS\\NETSCAPE\\%s.EXE\n' % exe).encode()
                self.assertEqual(entry in out, exe in added, (version, exe))
            self.assertIn('line 4 skipped: minimum Windows version must be 3.0, 3.1 or 3.11', r.stdout)
            self.assertNotIn(b',3.1', out)  # the field never reaches SETUP.INF
            if version == '3.0':
                self.assertIn('line 1 skipped: needs Windows 3.1, this is Windows 3.0', r.stdout)
        target = (ROOT / 'tools/dos_csmwrap_target.sh').read_text(encoding='ascii')
        self.assertIn('windows-3-0:*) icons_ver=3.0 ;;', target)
        self.assertIn('dos_program_icons "$U" "$icons_ver"', target)

    def test_target_wiring(self):
        target = (ROOT / 'tools/dos_csmwrap_target.sh').read_text(encoding='ascii')
        call = target.index('dos_program_icons "$U"')
        self.assertLess(target.index('cp -r "$PROGRAMS_DIR" "$U/PROGRAMS"'), call)
        self.assertLess(target.index("log 'Windows 3.x Setup files copied'"), call)
        self.assertLess(call, target.index('umount "$work/c" || fail'))
        self.assertIn('if [ -n "$WIN3_ISO" ]; then\n        dos_program_icons', target)


if __name__ == '__main__':
    unittest.main()
