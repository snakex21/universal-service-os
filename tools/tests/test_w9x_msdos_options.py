"""C:\MSDOS.SYS [Options] written by INSTALL.BAT (src/platform/bios/dos_startup.cmd)
for Windows 95/98/98 SE: text boot, no forced startup menu, Normal as the menu
default. Windows keeps showing the menu by itself after an unclean shutdown."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
INSTALL = ROOT / 'src/platform/bios/dos_startup.cmd'


class MsdosOptions(unittest.TestCase):
    def lines(self):
        return [l for l in INSTALL.read_text(encoding='latin-1').splitlines() if 'C:\MSDOS.SYS' in l and l.startswith('ECHO ')]

    def test_options_block(self):
        written = [l.split('>>')[0][5:] for l in self.lines()]
        self.assertEqual(written, ['[Options]', 'Logo=0', 'BootMenu=0', 'BootMenuDefault=1'])

    def test_no_forced_boot_menu_anywhere(self):
        pattern = re.compile(r'BootMenu\s*=\s*1|BootKeys\s*=\s*1|BootMenuDelay', re.I)
        for path in [INSTALL, *sorted((ROOT / 'tools').glob('w9x_*.sh')), *sorted((ROOT / 'tools').glob('dos_*.sh'))]:
            self.assertIsNone(pattern.search(path.read_text(encoding='latin-1')), path.name)


if __name__ == '__main__':
    unittest.main()
