"""Host test: early-Windows fixes from the X470 run of 2026-10-08.

* install.cmd adds WIN100.BIN to the SETVER table (MS-DOS 6.22 lists only
  WIN200.BIN; the Windows 1.0x kernel otherwise prints "Incorrect DOS
  version" plus memory garbage at every start), on the CSMWrap and the
  plain path, and only for the early systems.
* Key scripts: Windows 3.0 leaves Setup with "Return to DOS" (no extra
  restart), Windows 2.03 installs MOUSE.DRV (USB mouse via USOSKBC /M).
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


class Win1Mouse(unittest.TestCase):
    """USOSMS1.DRV (Windows 1.0x USB mouse through the BIOS) replaces
    MOUSE.DRV in C:\\WINSETUP before Setup binds it into WIN100.BIN, only in
    the CSMWrap branch and only for 1.01/1.04."""
    def test_install_copies_over_mouse_drv(self):
        lines = batch_lines(MSDOS / 'install.cmd')
        csm = lines.index(r'if not exist %USRC%\CSMWRAP.TAG goto early_setver')
        copy = lines.index(r'copy %USRC%\USOSMS1.DRV C:\WINSETUP\MOUSE.DRV /y >nul')
        self.assertLess(csm, copy)
        self.assertLess(copy, lines.index(':early_setver'))
        self.assertEqual(lines[copy + 1], 'if errorlevel 1 goto failed')

    def test_staged_only_for_1x(self):
        text = (ROOT / 'tools/dos_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertIn('windows-1-01|windows-1-04) ;;', text)
        self.assertEqual(text.count('rm -f "$U/USOSMS1.DRV"'), 2)
        self.assertIn('USOSMS1.DRV', (ROOT / 'installer/cmd/usos-payload-pack/main.go').read_text(encoding='utf-8'))
        self.assertIn('build_win1_mouse(out, work)', (ROOT / 'tools/build_win3_usb_keyboard.py').read_text(encoding='utf-8'))

    def test_key_scripts_pick_microsoft_mouse(self):
        for name in ('W101.txt', 'W104.txt'):
            lines = [l.strip() for l in (MSDOS / 'keys' / name).read_text(encoding='ascii').splitlines()]
            i = lines.index('wait "Type the number for your pointing device"')
            self.assertEqual(lines[i + 1], 'key 2 enter')   # 2 = MOUSE.DRV


class KeyScripts(unittest.TestCase):
    def ops(self, name):
        return [l.strip() for l in (MSDOS / 'keys' / name).read_text(encoding='ascii').splitlines()
                if l.strip() and not l.lstrip().startswith('#')]

    def test_w30_returns_to_dos(self):
        self.assertEqual(self.ops('W30.txt')[-1], 'key alt+d')

    def test_w203_microsoft_mouse(self):
        ops = self.ops('W203.txt')
        i = ops.index('wait "select your pointing device"')
        # The list starts with "Microsoft Mouse (Bus or Serial)" = MOUSE.DRV
        # (its PS/2 path through the BIOS; USOSKBC /M wakes it under CSMWrap).
        self.assertEqual(ops[i + 1], 'key enter')

    def test_setup_and_start_load_mouse_kick(self):
        setup = batch_lines(MSDOS / 'windows_early_setup.cmd')
        self.assertIn(r'if exist C:\DOS\USOSKBC.COM C:\DOS\USOSKBC.COM /R /M C:\USOSW3\SETUP.KEY', setup)
        auto = batch_lines(MSDOS / 'windows_early_auto.cmd')
        self.assertIn(r'if exist C:\DOS\USOSKBC.COM C:\DOS\USOSKBC.COM /R /M', auto)
        kbc = (MSDOS / 'usoskbc.S').read_text(encoding='ascii')
        # unit run of /M: tools/tests/legacy_bios/test_usoskbc_mouse.py
        for needle in ('cmp ax, 0xc207', 'mtramp:', 'int74:', 'int 0x74', 'mov ax, 0x2574', "cmp al, 'm'"):
            self.assertIn(needle, kbc)


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


def quiet(ran):
    r"""The commands without the silent log / flag lines (C:\USOSW3\WINRUN.LOG,
    WINRUN.ON) and the WIN.COM -> WIN30.COM shadow steps."""
    return [r for r in ran if 'WINRUN.LOG' not in r and 'WINRUN.ON' not in r]


WIN30_FILES = (r'C:\WINDOWS\SYSTEM\DOSX.EXE', r'C:\USOSW3\WINRUN.BAT', r'C:\DOS\DOSKEY.COM')


def run_early_auto(config, extra=(), name='windows_early_auto.cmd', args=(), env=None, absent=()):
    r"""Walk W1AUTO.BAT for one CONFIG value (files in C:\DOS present, Windows
    2.x installed; extra=WIN30_FILES: Windows 3.0): the commands that run, in
    order, without the comments. Every program exits with errorlevel 0."""
    lines = [l.strip() for l in (MSDOS / name).read_text(encoding='ascii').splitlines()]
    env = dict(env or {}, CONFIG=config)
    for n, a in enumerate(args, 1):
        env[str(n)] = a
    exists = {r'C:\DOS\VBMOUSE.EXE', r'C:\DOS\USOSKBC.COM', r'C:\DOS\USOSWHER.COM', r'C:\DOS\USOSV10.COM',
              r'C:\WINDOWS\WIN.COM', *extra}
    exists -= set(absent)
    labels = {l[1:].lower()[:8]: i for i, l in reversed(list(enumerate(lines))) if l.startswith(':')}
    ran, i = [], 0
    expand = lambda s: re.sub(r'%(\d)', lambda m: env.get(m.group(1), ''),
                              re.sub(r'%(\w+)%', lambda m: env.get(m.group(1), ''), s))
    while i < len(lines):
        line = lines[i]
        i += 1
        if not line or line.lower().startswith(('rem', '@echo', ':')):
            continue
        cond = re.match(r'if (not )?(?:"([^"]*)"=="([^"]*)"|exist (\S+)|errorlevel (\d+)) (.*)$', line, re.I)
        if cond:
            if cond.group(5):
                value = int(cond.group(5)) <= 0
            elif cond.group(4):
                value = cond.group(4) in exists or cond.group(4).upper().endswith(r'\NUL')
            else:
                value = expand('"%s"' % cond.group(2)) == '"%s"' % cond.group(3)
            if bool(cond.group(1)) == value:
                continue
            line = cond.group(6)
        jump = re.match(r'goto (\S+)$', line, re.I)
        if jump:
            i = labels[jump.group(1).lower()[:8]] + 1
            continue
        setting = re.match(r'set (\w+)=(.*)$', line, re.I)
        if setting:
            env[setting.group(1)] = expand(setting.group(2))
            continue
        line = expand(line)
        ran.append(line)
        # files the batch itself creates, deletes or renames
        made = re.match(r'echo [^>]*[^>]>(\S+)$', line, re.I)
        if made:
            exists.add(made.group(1))
        gone = re.match(r'del (\S+)$', line, re.I)
        if gone:
            exists.discard(gone.group(1))
        moved = re.match(r'ren (\S+) (\S+)$', line, re.I)
        if moved and moved.group(1) in exists:
            exists.discard(moved.group(1))
            exists.add(moved.group(1).rsplit('\\', 1)[0] + '\\' + moved.group(2))
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
        # WINREAL (Windows 3.0 WIN /S) resets the X470: only here, not in [menu].
        self.assertEqual(items, ['D1WHERE', 'D2NOKBC', 'D4CLEAN', 'D5MIN', 'D6V10', 'WINREAL', 'DOSONLY'])
        self.assertNotIn('WINREAL', '\n'.join(self.blocks['menu']))
        self.assertLessEqual(len(items), 9)
        for item in items:
            self.assertIn(item, self.blocks)

    def test_himem_per_item(self):
        himem = r'DEVICE=C:\DOS\HIMEM.SYS /TESTMEM:OFF'
        for name in ('WINSTD', 'WINREAL', 'DOSONLY', 'D1WHERE', 'D2NOKBC'):
            self.assertIn(himem, self.blocks[name])
        for name in ('D4CLEAN', 'D5MIN', 'D6V10'):
            self.assertEqual(self.blocks[name], [])
        self.assertNotIn(himem, self.blocks['common'])
        self.assertIn(r'DEVICE=C:\DOS\SETVER.EXE', self.blocks['common'])
        # HIMEM before SETVER (file order): the item blocks precede [common].
        self.assertLess(self.config.index('[WINSTD]'), self.config.index('[common]'))

    def loaded(self, config):
        ran = run_early_auto(config)
        names = [r.split()[0].split('\\')[-1] for r in ran]
        return ran, [n for n in names if n in ('USOSV10.COM', 'VBMOUSE.EXE', 'USOSKBC.COM', 'USOSWHER.COM', 'WIN.COM')]

    def test_variants(self):
        expected = {
            # USOSV10 (INT 10h on its own stack) first everywhere but in D5,
            # the control item for the 2.03 logo hang
            'WINSTD': ['USOSV10.COM', 'VBMOUSE.EXE', 'USOSKBC.COM', 'WIN.COM'],
            'WINREAL': ['USOSV10.COM', 'VBMOUSE.EXE', 'USOSKBC.COM', 'WIN.COM'],
            'D1WHERE': ['USOSV10.COM', 'VBMOUSE.EXE', 'USOSKBC.COM', 'USOSWHER.COM', 'WIN.COM'],
            'D2NOKBC': ['USOSV10.COM', 'VBMOUSE.EXE', 'WIN.COM'],
            'D4CLEAN': ['USOSV10.COM', 'USOSKBC.COM', 'WIN.COM'],
            'D5MIN': ['USOSWHER.COM', 'WIN.COM'],
            'D6V10': ['USOSV10.COM', 'USOSWHER.COM', 'WIN.COM'],
            'DOSONLY': ['USOSV10.COM', 'VBMOUSE.EXE', 'USOSKBC.COM'],
        }
        for config, programs in expected.items():
            ran, names = self.loaded(config)
            self.assertEqual(names, programs, config)
            if 'USOSKBC.COM' in programs:
                self.assertIn(r'C:\DOS\USOSKBC.COM /R /M', ran)
            if 'USOSWHER.COM' in programs:
                self.assertIn(r'C:\DOS\USOSWHER.COM /G', ran)

    def test_win30_vbmouse_after_windows(self):
        # Windows 3.0 (X470 2026-10-24): real-mode WINOLDAP resets INT 33h and
        # VBMOUSE took the C207h callback from MOUSE.DRV (dead mouse after the
        # DOS prompt). No VBMOUSE before WIN; loaded after DOSKEY (last hook,
        # so WINRUN.BAT can unload it), also for the DOS item.
        for config in ('WINSTD', 'WINREAL', 'D1WHERE', 'D2NOKBC', 'DOSONLY'):
            ran = run_early_auto(config, WIN30_FILES)
            names = [r.split()[0].split('\\')[-1] for r in ran]
            self.assertEqual(names.count('VBMOUSE.EXE'), 1, config)
            vbm = names.index('VBMOUSE.EXE')
            if 'WIN.COM' in names:
                self.assertLess(names.index('WIN.COM'), vbm, config)
            self.assertLess(names.index('DOSKEY.COM'), vbm, config)
            self.assertEqual(ran[vbm - 1:vbm + 2], ['ctty nul', r'C:\DOS\VBMOUSE.EXE', 'ctty con'], config)
        for config in ('D4CLEAN', 'D5MIN', 'D6V10'):
            self.assertNotIn(r'C:\DOS\VBMOUSE.EXE', run_early_auto(config, WIN30_FILES), config)
        # Windows 1.0x/2.x (and Windows/386): before WIN as before, quiet.
        ran = run_early_auto('WINSTD')
        self.assertEqual(ran[ran.index(r'C:\DOS\VBMOUSE.EXE') - 1:ran.index(r'C:\DOS\VBMOUSE.EXE') + 2],
                         ['ctty nul', r'C:\DOS\VBMOUSE.EXE', 'ctty con'])
        self.assertLess(ran.index(r'C:\DOS\VBMOUSE.EXE'), ran.index('WIN.COM'))
        # Every ctty nul is undone right after one program.
        for name in ('windows_early_auto.cmd', 'windows_run.cmd'):
            lines = batch_lines(MSDOS / name)
            for n, line in enumerate(lines):
                if line.lower() == 'ctty nul':
                    self.assertEqual(lines[n + 2].lower(), 'ctty con', name)
                    self.assertIn('VBMOUSE.EXE', lines[n + 1], name)

    def test_winrun_win30(self):
        early = (r'C:\USOSW3\EARLY.TAG', r'C:\DOS\VBMOUSE.EXE')
        for wincom in ('WIN.COM', 'WIN30.COM'):
            files = early + ((r'C:\WINDOWS\WIN30.COM',) if wincom == 'WIN30.COM' else ())
            for args, win in (((), r'C:\WINDOWS\%s /R' % wincom), (('/3',), r'C:\WINDOWS\%s /3' % wincom)):
                full = run_early_auto('', files, 'windows_run.cmd', args)
                ran = quiet(full)
                self.assertEqual(ran[:3], ['ctty nul', r'C:\DOS\VBMOUSE.EXE uninstall', 'ctty con'], args)
                self.assertEqual(ran[3].rstrip(), win, args)
                self.assertEqual(ran[4:7], ['ctty nul', r'C:\DOS\VBMOUSE.EXE', 'ctty con'], args)
                # WINRUN.ON exists exactly while Windows 3.0 runs
                on, off = full.index(r'echo USOS>C:\USOSW3\WINRUN.ON'), full.index(r'del C:\USOSW3\WINRUN.ON')
                self.assertLess(on, full.index(ran[3]))
                self.assertLess(full.index(ran[3]), off)
                self.assertTrue(full[0].startswith('echo WINRUN [') and full[0].endswith(r'>>C:\USOSW3\WINRUN.LOG'))
        # Windows 3.1 / 3.11 (no EARLY.TAG): VBMOUSE stays (VBMOUSE.DRV uses it).
        ran = run_early_auto('', (r'C:\DOS\VBMOUSE.EXE',), 'windows_run.cmd')
        self.assertFalse(any('VBMOUSE' in r for r in ran))
        self.assertIn(r'C:\WINDOWS\WIN.COM /S /B', ran)
        self.assertFalse(any('WINRUN.ON' in r for r in ran))

    def test_win30_win_bat_shadow(self):
        # WIN typed in the DOS window of a Windows 3.0 started from the menu
        # (no DOSKEY macro yet, C:\WINDOWS current) must reach WINRUN.BAT:
        # WIN.COM -> WIN30.COM, C:\USOSW3\WIN.BAT -> C:\WINDOWS\WIN.BAT.
        files = WIN30_FILES + (r'C:\USOSW3\WIN.BAT',)
        ran = run_early_auto('WINSTD', files)
        ren = ran.index(r'ren C:\WINDOWS\WIN.COM WIN30.COM')
        self.assertLess(ren, ran.index(r'copy C:\USOSW3\WIN.BAT C:\WINDOWS\WIN.BAT /y >nul'))
        # a WINRUN.ON left by a reset is removed before anything else
        stale = run_early_auto('WINSTD', files + (r'C:\USOSW3\WINRUN.ON',))
        self.assertLess(stale.index(r'del C:\USOSW3\WINRUN.ON'), stale.index(r'ren C:\WINDOWS\WIN.COM WIN30.COM'))
        # already renamed (WIN30.COM there, no WIN.COM): only the batch is refreshed
        ran = run_early_auto('WINSTD', files + (r'C:\WINDOWS\WIN30.COM',), absent=(r'C:\WINDOWS\WIN.COM',))
        self.assertFalse(any(r.startswith('ren ') for r in ran))
        self.assertIn(r'copy C:\USOSW3\WIN.BAT C:\WINDOWS\WIN.BAT /y >nul', ran)
        win = ran.index('WIN30.COM /R')
        self.assertLess(ran.index(r'echo USOS>C:\USOSW3\WINRUN.ON'), win)
        self.assertLess(win, ran.index(r'del C:\USOSW3\WINRUN.ON', win))
        # Windows 1.x/2.x: untouched
        self.assertFalse(any('WIN30' in r or 'WIN.BAT' in r for r in run_early_auto('WINSTD', (r'C:\USOSW3\WIN.BAT',))))
        # staged: helper W30WIN.BAT -> C:\USOSW3\WIN.BAT, payload, WINMENU/W3START accept WIN30.COM
        self.assertIn(r'copy %USRC%\W30WIN.BAT C:\USOSW3\WIN.BAT /y >nul', batch_lines(MSDOS / 'install.cmd'))
        self.assertIn("('windows_win30.cmd', 'W30WIN.BAT')", (ROOT / 'tools/build_dos_native_support.py').read_text())
        self.assertIn('EFI/USOS/dos-native/msdos/W30WIN.BAT', (ROOT / 'installer/cmd/usos-payload-pack/main.go').read_text())
        self.assertIn(r'C:\USOSW3\WINRUN.BAT %1 %2 %3 %4 %5 %6 %7 %8 %9', batch_lines(MSDOS / 'windows_win30.cmd'))
        for name, label in (('windows_menu.cmd', 'have_win'), ('windows_start.cmd', 'installed')):
            self.assertIn(r'if exist C:\WINDOWS\WIN30.COM goto ' + label, batch_lines(MSDOS / name))

    def test_usoswin_guard(self):
        # WIN typed in a DOS window of the running Windows: one hint, no WIN.COM.
        # Windows 3.0: the WINRUN.ON file (X470 2026-10-24: the environment
        # flag alone did not stop a second Windows); USOSWIN=1 as well.
        hint = ['echo Windows is already running - type EXIT to return.']
        for extra in ((), (r'C:\USOSW3\EARLY.TAG', r'C:\DOS\VBMOUSE.EXE')):
            ran = run_early_auto('', extra, 'windows_run.cmd', env={'USOSWIN': '1'})
            self.assertEqual(quiet(ran), hint, extra)
            self.assertIn('USOSWIN=1', ran[1])
            ran = run_early_auto('', extra + (r'C:\USOSW3\WINRUN.ON',), 'windows_run.cmd')
            self.assertEqual(quiet(ran), hint, extra)
            self.assertIn('WINRUN.ON present', ran[1])
        # Otherwise WINRUN sets it for WIN.COM and clears it afterwards.
        lines = batch_lines(MSDOS / 'windows_run.cmd')
        code = [l for l in lines if l and not l.lower().startswith(('rem', '@echo', 'echo winrun'))]
        self.assertEqual(code[:6], [r'if not exist C:\USOSW3\WINRUN.ON goto no_flag', 'goto running', ':no_flag',
                                    'if not "%USOSWIN%"=="1" goto start', 'goto running', ':start'])
        self.assertEqual(code[6], 'set USOSWIN=1')
        self.assertLess(lines.index(':end'), lines.index('set USOSWIN='))
        self.assertLess(lines.index('set USOSWIN='), lines.index(':running'))
        # The start files: set before WIN.COM, cleared at :end.
        for name in ('windows_early_auto.cmd', 'windows_auto.cmd'):
            lines = batch_lines(MSDOS / name)
            first_win = min(n for n, l in enumerate(lines) if l.upper().startswith(('WIN.COM', 'WIN386.EXE')))
            self.assertLess(lines.index('set USOSWIN=1'), first_win, name)
            self.assertEqual(lines[lines.index(':end') + 1], 'set USOSWIN=', name)

    def test_default_items(self):
        # X470 PASS 2026-10-09 (Windows 2.03 via D6): every default item loads
        # USOSV10 first and USOSKBC /R; the USOSWHER overlay only in diagnostics
        for config in ('WINSTD', 'WINREAL', 'DOSONLY'):
            ran, names = self.loaded(config)
            self.assertEqual(names[0], 'USOSV10.COM', config)
            self.assertIn(r'C:\DOS\USOSKBC.COM /R /M', ran)
            self.assertNotIn('USOSWHER.COM', names, config)
        self.assertIn('menudefault=WINSTD,8', self.config)
        self.assertIn('submenu=DIAG,Diagnostics (D1-D6, for tests only)', self.config)

    def test_diag_log(self):
        for config, tag in (('D1WHERE', 'D1'), ('D2NOKBC', 'D2'), ('D4CLEAN', 'D4'), ('D5MIN', 'D5'),
                            ('D6V10', 'D6')):
            ran = run_early_auto(config)
            log = r'>>C:\USOS\DIAG\%s.TXT' % tag
            writes = [r for r in ran if r.endswith(log)]
            self.assertTrue(any(r.startswith(r'C:\DOS\MEM.EXE /D') for r in writes), config)
            win = ran.index('WIN.COM')
            self.assertTrue(all(ran.index(w) < win for w in writes if 'returned' not in w))
            self.assertIn('echo ==== WIN returned' + log, ran)
            self.assertLess(win, ran.index('echo ==== WIN returned' + log))
        self.assertFalse(any('DIAG' in r for r in run_early_auto('WINSTD')))
        # USOSV10 reports its deepest stack use into the log (not in D5)
        for config, tag in (('D1WHERE', 'D1'), ('D6V10', 'D6')):
            ran = run_early_auto(config)
            report = r'C:\DOS\USOSV10.COM>>C:\USOS\DIAG\%s.TXT' % tag
            self.assertEqual(ran.count(report), 2, config)
            self.assertLess(ran.index(report), ran.index('WIN.COM'))
        self.assertFalse(any(r.startswith(r'C:\DOS\USOSV10.COM') for r in run_early_auto('D5MIN')))

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
        # 1.2: CGA mode 6 (the 2.x logo, CGA.LGO) and the INT 09h snapshot row
        self.assertIn('cgaout:', where)
        self.assertIn('cmp al, 6', where)
        self.assertIn('mov ax, 0x2509', where)
        self.assertIn('JMPFAR old09', where)
        # 1.4: #UD (INT 06h) dump screen and the EXEC trace (INT 01h ring) armed by WIN's 4B00h
        self.assertIn('mov ax, 0x2506', where)
        self.assertIn('mov ax, 0x2501', where)
        self.assertIn('cmp ax, 0x4b00', where)
        self.assertIn('cmp word ptr ds:[8], 0x4957', where)
        self.assertIn('cmp ax, 0xc000', where)
        self.assertIn('CALLFAR old08', where)
        self.assertNotIn('    call dword ptr', where)
        self.assertIn('USOSWHERE 1.4', where)
        # USOSV10: built, staged by INSTALL.BAT and in the payload (unit run:
        # tools/tests/legacy_bios/test_usosv10.py)
        self.assertIn("dos_out / 'USOSV10.COM'", build)
        self.assertIn(r'copy %USRC%\USOSV10.COM C:\DOS /y >nul', batch_lines(MSDOS / 'install.cmd'))
        # copied with or without CSMWrap (the video BIOS stack depth does not depend on it)
        lines = batch_lines(MSDOS / 'install.cmd')
        self.assertLess(lines.index(r'copy %USRC%\USOSV10.COM C:\DOS /y >nul'),
                        lines.index(r'if not exist %USRC%\CSMWRAP.TAG goto csm_dos_done'))
        self.assertIn('USOSV10.COM', (ROOT / 'installer/cmd/usos-payload-pack/main.go').read_text(encoding='utf-8'))
        v10 = (ROOT / 'src/platform/bios/win9x/usosv10.S').read_text(encoding='ascii')
        self.assertIn('mov sp, offset stktop', v10)


if __name__ == '__main__':
    unittest.main()
