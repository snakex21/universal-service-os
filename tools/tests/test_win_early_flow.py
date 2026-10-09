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


def run_early_auto(config):
    r"""Walk W1AUTO.BAT for one CONFIG value (files in C:\DOS present, Windows
    2.x installed): the commands that run, in order, without the comments."""
    lines = [l.strip() for l in (MSDOS / 'windows_early_auto.cmd').read_text(encoding='ascii').splitlines()]
    env = {'CONFIG': config}
    exists = {r'C:\DOS\VBMOUSE.EXE', r'C:\DOS\USOSKBC.COM', r'C:\DOS\USOSWHER.COM', r'C:\WINDOWS\WIN.COM'}
    labels = {l[1:].lower()[:8]: i for i, l in reversed(list(enumerate(lines))) if l.startswith(':')}
    ran, i = [], 0
    expand = lambda s: re.sub(r'%(\w+)%', lambda m: env.get(m.group(1), ''), s)
    while i < len(lines):
        line = lines[i]
        i += 1
        if not line or line.lower().startswith(('rem', '@echo', ':')):
            continue
        cond = re.match(r'if (not )?(?:"([^"]*)"=="([^"]*)"|exist (\S+)) (.*)$', line, re.I)
        if cond:
            if cond.group(4):
                value = cond.group(4) in exists or cond.group(4).upper().endswith(r'\NUL')
            else:
                value = expand('"%s"' % cond.group(2)) == '"%s"' % cond.group(3)
            if bool(cond.group(1)) == value:
                continue
            line = cond.group(5)
        jump = re.match(r'goto (\S+)$', line, re.I)
        if jump:
            i = labels[jump.group(1).lower()[:8]] + 1
            continue
        setting = re.match(r'set (\w+)=(.*)$', line, re.I)
        if setting:
            env[setting.group(1)] = expand(setting.group(2))
            continue
        ran.append(expand(line))
    return ran


class DiagnosticMenu(unittest.TestCase):
    """W1CONFIG.SYS submenu DIAG + W1AUTO.BAT (Windows 2.03 logo hang, X470)."""

    def setUp(self):
        self.config = (MSDOS / 'windows_early_config.sys').read_text(encoding='ascii')
        self.blocks = {}
        name = None
        for line in self.config.splitlines():
            m = re.match(r'\[(\w+)\]$', line.strip())
            if m:
                name = m.group(1)
                self.blocks[name] = []
            elif name and line.strip() and not line.startswith(';'):
                self.blocks[name].append(line.strip())

    def test_menu(self):
        self.assertIn('submenu=DIAG,', '\n'.join(self.blocks['menu']))
        items = [l.split('=', 1)[1].split(',')[0] for l in self.blocks['DIAG'] if l.startswith('menuitem=')]
        self.assertEqual(items, ['D1WHERE', 'D2NOKBC', 'D4CLEAN', 'D5MIN', 'DOSONLY'])
        self.assertLessEqual(len(items), 9)
        for item in items:
            self.assertIn(item, self.blocks)

    def test_himem_per_item(self):
        himem = r'DEVICE=C:\DOS\HIMEM.SYS /TESTMEM:OFF'
        for name in ('WINSTD', 'WINREAL', 'DOSONLY', 'D1WHERE', 'D2NOKBC'):
            self.assertIn(himem, self.blocks[name])
        for name in ('D4CLEAN', 'D5MIN'):
            self.assertEqual(self.blocks[name], [])
        self.assertNotIn(himem, self.blocks['common'])
        self.assertIn(r'DEVICE=C:\DOS\SETVER.EXE', self.blocks['common'])
        # HIMEM before SETVER (file order): the item blocks precede [common].
        self.assertLess(self.config.index('[WINSTD]'), self.config.index('[common]'))

    def loaded(self, config):
        ran = run_early_auto(config)
        names = [r.split()[0].split('\\')[-1] for r in ran]
        return ran, [n for n in names if n in ('VBMOUSE.EXE', 'USOSKBC.COM', 'USOSWHER.COM', 'WIN.COM')]

    def test_variants(self):
        expected = {
            'WINSTD': ['VBMOUSE.EXE', 'USOSKBC.COM', 'WIN.COM'],
            'D1WHERE': ['VBMOUSE.EXE', 'USOSKBC.COM', 'USOSWHER.COM', 'WIN.COM'],
            'D2NOKBC': ['VBMOUSE.EXE', 'WIN.COM'],
            'D4CLEAN': ['USOSKBC.COM', 'WIN.COM'],
            'D5MIN': ['USOSWHER.COM', 'WIN.COM'],
            'DOSONLY': ['VBMOUSE.EXE', 'USOSKBC.COM'],
        }
        for config, programs in expected.items():
            ran, names = self.loaded(config)
            self.assertEqual(names, programs, config)
            if 'USOSKBC.COM' in programs:
                self.assertIn(r'C:\DOS\USOSKBC.COM /R', ran)
            if 'USOSWHER.COM' in programs:
                self.assertIn(r'C:\DOS\USOSWHER.COM /G', ran)

    def test_diag_log(self):
        for config, tag in (('D1WHERE', 'D1'), ('D2NOKBC', 'D2'), ('D4CLEAN', 'D4'), ('D5MIN', 'D5')):
            ran = run_early_auto(config)
            log = r'>>C:\USOS\DIAG\%s.TXT' % tag
            writes = [r for r in ran if r.endswith(log)]
            self.assertTrue(any(r.startswith(r'C:\DOS\MEM.EXE /D') for r in writes), config)
            win = ran.index('WIN.COM')
            self.assertTrue(all(ran.index(w) < win for w in writes if 'returned' not in w))
            self.assertIn('echo ==== WIN returned' + log, ran)
            self.assertLess(win, ran.index('echo ==== WIN returned' + log))
        self.assertFalse(any('DIAG' in r for r in run_early_auto('WINSTD')))

    def test_no_redirection_inside_if(self):
        # COMMAND.COM opens a redirection target even when the IF is false.
        for line in (MSDOS / 'windows_early_auto.cmd').read_text(encoding='ascii').splitlines():
            if line.strip().lower().startswith('if '):
                self.assertNotIn('>', line.split('==', 1)[-1], line)

    def test_staged(self):
        build = (ROOT / 'tools/build_dos_native_support.py').read_text(encoding='utf-8')
        self.assertIn("dos_out / 'USOSWHER.COM'", build)
        self.assertIn(r'copy %USRC%\USOSWHER.COM C:\DOS /y >nul', batch_lines(MSDOS / 'install.cmd'))
        self.assertIn('USOSWHER.COM', (ROOT / 'installer/cmd/usos-payload-pack/main.go').read_text(encoding='utf-8'))
        where = (ROOT / 'src/platform/bios/win9x/usoswhere.S').read_text(encoding='ascii')
        self.assertIn('mov ax, 0x1130', where)
        self.assertIn('gfxout:', where)
        # 1.1: planar graphics detected from the VGA GC too, INT 10h mode-set AX, font fallback
        self.assertIn('gport:', where)
        self.assertIn('0xfa6e', where)
        self.assertIn('mov word ptr cs:[ax10], ax', where)


if __name__ == '__main__':
    unittest.main()
