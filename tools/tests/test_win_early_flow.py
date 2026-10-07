"""Host test: early-Windows fixes from the X470 run of 2026-10-08.

* install.cmd adds WIN100.BIN to the SETVER table (MS-DOS 6.22 lists only
  WIN200.BIN; the Windows 1.0x kernel otherwise prints "Incorrect DOS
  version" plus memory garbage at every start), on the CSMWrap and the
  plain path, and only for the early systems.
* Key scripts: Windows 3.0 leaves Setup with "Return to DOS" (no extra
  restart), Windows 2.03 installs without a mouse driver.
* micro_linux_ui.sh takes the progress-page heading from usos.heading=
  instead of the old "Windows 9x" default.
"""
from pathlib import Path
import re, unittest

ROOT = Path(__file__).resolve().parents[2]
MSDOS = ROOT / 'src/platform/bios/msdos'


def batch_lines(path):
    return [l.strip() for l in path.read_text(encoding='ascii').splitlines()]


class SetverWin100(unittest.TestCase):
    def setUp(self):
        self.lines = batch_lines(MSDOS / 'install.cmd')

    def test_entry_in_early_branch(self):
        start = self.lines.index(r'if not exist %USRC%\EARLY.TAG goto early_done')
        setver = self.lines.index(':early_setver')
        done = self.lines.index(':early_done')
        self.assertLess(start, setver)
        self.assertLess(setver, done)
        body = [l for l in self.lines[setver:done] if not l.lower().startswith('rem')]
        self.assertIn(r'if exist C:\DOS\SETVER.EXE C:\DOS\SETVER.EXE C:\DOS WIN100.BIN 3.40 >nul', body)

    def test_plain_path_reaches_setver(self):
        # Without CSMWRAP.TAG the branch must still add the entry.
        self.assertIn(r'if not exist %USRC%\CSMWRAP.TAG goto early_setver', self.lines)
        early = self.lines[self.lines.index(r'if not exist %USRC%\EARLY.TAG goto early_done'):self.lines.index(':early_setver')]
        self.assertNotIn('goto early_done', ' '.join(early[1:]))

    def test_start_menu_loads_setver(self):
        for name in ('windows_early_config.sys',):
            text = (MSDOS / name).read_text(encoding='ascii')
            self.assertIn(r'DEVICE=C:\DOS\SETVER.EXE', text)


class KeyScripts(unittest.TestCase):
    def ops(self, name):
        return [l.strip() for l in (MSDOS / 'keys' / name).read_text(encoding='ascii').splitlines()
                if l.strip() and not l.lstrip().startswith('#')]

    def test_w30_returns_to_dos(self):
        self.assertEqual(self.ops('W30.txt')[-1], 'key alt+d')

    def test_w203_no_mouse(self):
        ops = self.ops('W203.txt')
        i = ops.index('wait "select your pointing device"')
        # The list starts with the Microsoft Mouse; "No mouse" is second.
        self.assertEqual(ops[i + 1], 'key down enter')


class Heading(unittest.TestCase):
    def test_ui_reads_cmdline_heading(self):
        text = (ROOT / 'tools/micro_linux_ui.sh').read_text(encoding='utf-8')
        self.assertIn('usos.heading=?*)', text)
        self.assertNotIn("USOS_UI_HEADING='Windows 9x'", text)

    def test_uefi_passes_heading(self):
        text = (ROOT / 'src/platform/uefi/manual_summary.zig').read_text(encoding='utf-8')
        self.assertRegex(text, r'startWin9x\(root, vista_csmwrap_heading\)')
        prep = (ROOT / 'src/platform/uefi/vista_preparation.zig').read_text(encoding='utf-8')
        self.assertIn('" usos.heading="', prep)


if __name__ == '__main__':
    unittest.main()
