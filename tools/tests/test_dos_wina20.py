"""Host test: MS-DOS install puts WINA20.386 into C:\\ (X470 2026-10-23).

Windows 3.0 in 386 enhanced mode (plain WIN) on MS-DOS 5.0/6.x stops with
"You must have the file WINA20.386 in the root of your boot drive" unless
the file is there; MS-DOS Setup copies it there (DOSSETUP.INI [dif-path]).
USOS expands it with the rest of the media into C:\\DOS (PREPDOS: *.??_ ->
EXPAND, *.38_ -> *.386) and install.cmd copies it to C:\\ for every MS-DOS
install, idempotent, logged to C:\\DOS\\USOSDOS.LOG, skipped when missing.
The file itself comes from the user's MS-DOS media, never from the repo.
"""
from pathlib import Path
import os, shutil, subprocess, unittest

ROOT = Path(__file__).resolve().parents[2]
MSDOS = ROOT / 'src/platform/bios/msdos'
ISO = Path(os.environ.get('USOS_DOS622_ISO', r'C:\Users\ASRock\Desktop\Universal_Service_OS\OS\DOS\MS-DOS\MS-DOS 6.22 EN.iso'))


def lines(name):
    return [l.strip() for l in (MSDOS / name).read_text(encoding='ascii').splitlines()]


class Wina20Install(unittest.TestCase):
    def setUp(self):
        self.lines = lines('install.cmd')
        self.code = [l for l in self.lines if l and not l.lower().startswith('rem')]

    def block(self):
        start = self.code.index(r'if exist C:\WINA20.386 goto wina20_have')
        end = self.code.index(':wina20_done')
        return start, self.code[start:end + 1]

    def test_after_prepdos_before_windows_branch(self):
        start, _ = self.block()
        self.assertLess(self.code.index(r'if not exist C:\DOS\READY.TAG goto failed'), start)
        # every install: before the DOS-only / Windows Setup split
        self.assertLess(start, self.code.index(r'if not exist %USRC%\WINSETUP\SETUP.EXE goto dos_done'))
        self.assertLess(start, self.code.index(r'if not exist %USRC%\EARLY.TAG goto early_done'))

    def test_copy_from_expanded_media_plain_attributes(self):
        _, block = self.block()
        self.assertIn(r'if not exist C:\DOS\WINA20.386 goto wina20_none', block)
        self.assertIn(r'copy C:\DOS\WINA20.386 C:\ /y >nul', block)
        self.assertFalse([l for l in block if 'ATTRIB' in l.upper()])

    def test_missing_file_does_not_fail_install(self):
        _, block = self.block()
        self.assertFalse([l for l in block if 'goto failed' in l])
        for tag in ('wina20_have', 'wina20_none'):
            self.assertIn(':' + tag, block)
        logs = [l for l in block if l.startswith('echo WINA20.386:')]
        self.assertEqual(3, len(logs))
        for l in logs:
            self.assertTrue(l.endswith(r'>>C:\DOS\USOSDOS.LOG'), l)
            self.assertLessEqual(len(l), 127)

    def test_prepdos_expands_386(self):
        prep = lines('prepare_files.cmd')
        self.assertIn(r'for %%f in (%1\*.??_) do call %3\UNPACK.BAT %%f %2 %1\EXPAND.EXE', prep)
        self.assertIn(r'if exist %2\*.38_ ren %2\*.38_ *.386', prep)

    def test_not_in_repo(self):
        hits = [p for p in ROOT.rglob('WINA20.*') if '.git' not in p.parts]
        self.assertEqual([], hits)


SEVEN = shutil.which('7z') or r'C:\Program Files\7-Zip\7z.exe'


@unittest.skipUnless(ISO.is_file() and Path(SEVEN).is_file(), 'local MS-DOS 6.22 ISO or 7-Zip not available')
class Wina20Media(unittest.TestCase):
    def test_media_has_wina20_compressed(self):
        out = subprocess.run([SEVEN,'l', str(ISO)], capture_output=True, text=True).stdout
        names = {l.split()[-1].upper() for l in out.splitlines() if l[:4].isdigit()}
        self.assertIn('WINA20.38_', names)
        self.assertNotIn('WINA20.386', names)


if __name__ == '__main__':
    unittest.main()
