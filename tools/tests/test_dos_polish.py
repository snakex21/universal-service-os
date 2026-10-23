"""Host test: MS-DOS / Windows 1.x-3.x polish (2026-10-24).

A. WIN typed at the DOS prompt behaves like the start menu: W3AUTO.BAT /
   W1AUTO.BAT load the DOSKEY macro win=C:\\USOSW3\\WINRUN.BAT $* after
   Windows or the menu item (a macro wins over WIN.COM in the current
   directory); WINRUN.BAT without arguments uses the default item's mode
   (3.1: /S /B, WfW: /3 /B, 3.0: /S) and passes arguments through.
B. The start menus name the installed product (tools/dos_win3_menu.sh
   dos_win_name / dos_menu_names, run here under the host's POSIX shell).
C. DOS.INI (src/flow/answer/dos.zig) -> COUNTRY / DISPLAY.SYS / MODE CON
   CODEPAGE / KEYB lines in the start files (dos_regional_apply), manual =
   nothing written and W3PL.KEY dropped; the wiring through
   w9x_csmwrap_prepare.sh, dos_csmwrap_target.sh, INSTALL.BAT and the
   micro-Linux image.
"""
from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MSDOS = ROOT / 'src/platform/bios/msdos'
LIB = ROOT / 'tools/dos_win3_menu.sh'
SH = shutil.which('sh') or shutil.which('bash')


def text(name: str) -> str:
    return (MSDOS / name).read_text(encoding='ascii')


def lf(data: bytes) -> bytes:
    # BusyBox sed/awk (micro-Linux) keep the CR of each line; the MSYS ones
    # of a Windows host drop it, so files they edited compare as LF here.
    return data.replace(b'\r\n', b'\n')


def crlf(name: str) -> bytes:
    return text(name).replace('\r\n', '\n').replace('\n', '\r\n').encode('ascii')


class WinMacro(unittest.TestCase):
    def test_winrun_modes(self):
        run = text('windows_run.cmd')
        lines = [l for l in run.splitlines() if not l.lower().startswith('rem')]
        self.assertIn('if not "%1"=="" goto pass', lines)
        self.assertIn('C:\\WINDOWS\\WIN.COM /S /B', lines)
        self.assertIn('C:\\WINDOWS\\WIN.COM /3 /B', lines)
        self.assertIn('C:\\WINDOWS\\WIN.COM /S', lines)
        self.assertIn('C:\\WINDOWS\\WIN.COM %1 %2 %3 %4 %5 %6 %7 %8 %9', lines)
        # The same choice as W3AUTO.BAT: WfW only in 386 enhanced mode.
        self.assertIn('if exist C:\\WINSETUP\\WFWSETUP.DL_ goto enhanced', lines)
        self.assertIn('if exist C:\\WINSETUP\\WFWSETUP.DL_ goto enhanced', text('windows_auto.cmd'))
        self.assertIn('if exist C:\\USOSW3\\EARLY.TAG goto early', lines)
        # Never WIN.COM /S together with the user's switches (WIN.COM takes /S first).
        self.assertNotIn('/S %1', run)

    def test_macro_loaded_after_windows(self):
        macro = 'C:\\DOS\\DOSKEY.COM win=C:\\USOSW3\\WINRUN.BAT $* >nul'
        for name in ('windows_auto.cmd', 'windows_early_auto.cmd'):
            t = text(name)
            self.assertEqual(t.count(macro), 1, name)
            # After every path that ends in :end (WIN returned, DOS item).
            self.assertGreater(t.index(macro), t.index('\n:end\n'), name)
            self.assertLess(t.index(macro), t.index('Aby ponownie') if 'Aby ponownie' in t else len(t))
        early = text('windows_early_auto.cmd')
        head = early[:early.index(macro)]
        # Windows 1.0x/2.x and Windows/386 keep their own WIN / WIN386.
        self.assertIn('if not exist C:\\WINDOWS\\SYSTEM\\DOSX.EXE goto macro_ok', head)
        self.assertIn('if exist C:\\WIN386\\WIN386.EXE goto macro_ok', head)
        self.assertIn('if exist C:\\WINDOWS\\WIN386.EXE goto macro_ok', head)

    def test_install_and_payload(self):
        install = text('install.cmd')
        self.assertIn('copy %USRC%\\WINRUN.BAT C:\\USOSW3 /y >nul', install)
        self.assertIn("('windows_run.cmd', 'WINRUN.BAT')", (ROOT / 'tools/build_dos_native_support.py').read_text())
        self.assertIn('EFI/USOS/dos-native/msdos/WINRUN.BAT', (ROOT / 'installer/cmd/usos-payload-pack/main.go').read_text())
        self.assertIn('"WINRUN.BAT"', (ROOT / 'src/platform/bios/dos6_native_iso.zig').read_text())
        for line in text('windows_run.cmd').splitlines():
            self.assertLessEqual(len(line), 127)


@unittest.skipUnless(SH, 'no POSIX shell')
class MenuLib(unittest.TestCase):
    def sh(self, script: str, cwd: Path) -> str:
        r = subprocess.run([SH, '-c', '. "$1"; ' + script, 'sh', LIB.as_posix()], cwd=cwd, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def staged(self, d: Path):
        for src, dst in (('windows_config.sys', 'W3CONFIG.SYS'), ('windows_config.sys', 'W3CONFIG.CSM'),
                         ('windows_auto.cmd', 'W3AUTO.BAT'), ('windows_auto.cmd', 'W3AUTO.CSM'),
                         ('windows_early_config.sys', 'W1CONFIG.SYS'), ('windows_early_config.sys', 'W1CONFIG.CSM'),
                         ('windows_early_auto.cmd', 'W1AUTO.BAT'), ('windows_early_auto.cmd', 'W1AUTO.CSM')):
            (d / dst).write_bytes(crlf(src))
        (d / 'W3PL.KEY').write_bytes(b'key')

    def test_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            out = self.sh('for s in windows-1-01 windows-2-03 windows-2-11-286 windows-2-11-386 windows-3-1 windows-wfw-3-11; do dos_win_name $s "/d/x.iso"; done;'
                          ' dos_win_name windows-3-0 "/d/Images/Windows 3.0a EN.iso"; dos_win_name windows-3-0 "Windows 3.0a EN (720K floppies)";'
                          ' dos_win_name windows-3-0 "/d/Windows 3.0 EN.iso"; dos_win_name windows-3-1 "Windows 3.11 OEM.iso"; dos_win_name ms-dos x || echo none', d)
            self.assertEqual(out.splitlines(), ['Windows 1.01', 'Windows 2.03', 'Windows/286 2.11', 'Windows/386 2.11', 'Windows 3.1',
                                                'Windows for Workgroups 3.11', 'Windows 3.0a', 'Windows 3.0a', 'Windows 3.0', 'Windows 3.1', 'none'])

    def menu(self, system: str, image: str) -> dict[str, bytes]:
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            self.staged(d)
            self.sh(f'dos_menu_names . {system} "{image}"', d)
            return {p.name: lf(p.read_bytes()) for p in d.iterdir()}

    def test_menu_31(self):
        files = self.menu('windows-3-1', 'Windows 3.1 PL.iso')
        for name in ('W3CONFIG.SYS', 'W3CONFIG.CSM'):
            cfg = files[name]
            self.assertIn(b'menuitem=WINSTD,Windows 3.1 - tryb standardowy (domyslny)\n', cfg)
            self.assertIn(b'menuitem=WIN386,Windows 3.1 - tryb rozszerzony 386 (alternatywny)\n', cfg)
            self.assertIn(b'menuitem=WINSET,Ustawienia myszy PS/2 - Windows 3.1 Setup\n', cfg)
        self.assertIn(b'echo Windows 3.1 - tryb standardowy, bez cache dysku.\n', files['W3AUTO.BAT'])
        for line in files['W3CONFIG.SYS'].split(b'\n'):
            self.assertLessEqual(len(line), 80)

    def test_menu_wfw_and_early(self):
        wfw = self.menu('windows-wfw-3-11', 'WfW.iso')['W3CONFIG.SYS']
        self.assertIn(b'menuitem=WINSTD,Windows for Workgroups 3.11 - tryb rozszerzony 386 (domyslny)\n', wfw)
        self.assertIn(b'menuitem=WIN386,Windows for Workgroups 3.11 - tryb 386 z SMARTDRV\n', wfw)
        w30 = self.menu('windows-3-0', 'Windows 3.0a EN.iso')['W1CONFIG.SYS']
        self.assertIn(b'menuitem=WINSTD,Windows 3.0a (domyslny)\n', w30)
        self.assertIn(b'menuitem=WINREAL,Windows 3.0a - tryb standardowy (WIN /S, test)\n', w30)
        w386 = self.menu('windows-2-11-386', 'x.iso')['W1CONFIG.CSM']
        self.assertIn(b'menuitem=WINSTD,Windows/386 2.11 (domyslny)\n', w386)
        self.assertNotIn(b'WINREAL', w386.split(b'[DIAG]')[0])

    def regional(self, ini: str) -> dict[str, bytes]:
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            self.staged(d)
            (d / 'DOS.INI').write_bytes(ini.replace('\n', '\r\n').encode())
            self.sh('dos_regional_apply . DOS.INI', d)
            self.raw = {p.name: p.read_bytes() for p in d.iterdir()}
            return {k: lf(v) for k, v in self.raw.items()}

    def test_regional_polish(self):
        files = self.regional('; x\n[dos]\nmode=auto\ncountry=048\ncodepage=852\ncpi=EGA.CPI\nkeyb=PL\nkeybfile=KEYBOARD.SYS\n')
        cfg = b'COUNTRY=048,852,C:\\DOS\\COUNTRY.SYS\r\nDEVICE=C:\\DOS\\DISPLAY.SYS CON=(EGA,,1)\r\n'
        auto = (b'C:\\DOS\\MODE.COM CON CODEPAGE PREPARE=((852) C:\\DOS\\EGA.CPI) >nul\r\n'
                b'C:\\DOS\\MODE.COM CON CODEPAGE SELECT=852 >nul\r\nC:\\DOS\\KEYB.COM PL,,C:\\DOS\\KEYBOARD.SYS\r\n')
        self.assertEqual(self.raw['REGCFG.SYS'], cfg)
        self.assertEqual(self.raw['REGAUTO.BAT'], auto)
        cfg, auto = lf(cfg), lf(auto)
        for name in ('W3CONFIG.SYS', 'W3CONFIG.CSM', 'W1CONFIG.SYS', 'W1CONFIG.CSM'):
            self.assertTrue(files[name].endswith(b'[common]\n' + cfg), name)
        for name in ('W3AUTO.BAT', 'W3AUTO.CSM', 'W1AUTO.BAT', 'W1AUTO.CSM'):
            self.assertIn(b'set TEMP=C:\\TEMP\n' + auto, files[name], name)
        self.assertIn('W3PL.KEY', files)

    def test_regional_us_manual_and_bad(self):
        us = self.regional('[dos]\nmode=auto\ncountry=001\ncodepage=437\n')
        self.assertEqual(self.raw['REGCFG.SYS'], b'COUNTRY=001,437,C:\\DOS\\COUNTRY.SYS\r\n')
        self.assertNotIn('REGAUTO.BAT', us)
        self.assertNotIn(b'MODE.COM', us['W3AUTO.BAT'])
        manual = self.regional('[dos]\nmode=manual\n')
        self.assertNotIn('REGCFG.SYS', manual)
        self.assertNotIn('W3PL.KEY', manual)
        self.assertEqual(manual['W3CONFIG.SYS'], lf(crlf('windows_config.sys')))
        none = self.regional('[dos]\nmode=auto\n')
        self.assertNotIn('REGCFG.SYS', none)
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            self.staged(d)
            (d / 'DOS.INI').write_bytes(b'[dos]\r\nmode=auto\r\ncountry=048\r\ncodepage=852\r\ncpi=../X\r\n')
            r = subprocess.run([SH, '-c', '. "$1"; dos_regional_apply . DOS.INI', 'sh', LIB.as_posix()], cwd=d, capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0)
            self.assertFalse((d / 'REGCFG.SYS').exists())


class Wiring(unittest.TestCase):
    def test_flow(self):
        prepare = (ROOT / 'tools/w9x_csmwrap_prepare.sh').read_text()
        self.assertIn('cp /mnt/esp/EFI/USOS/answer/DOS.INI /run/dos-regional.ini', prepare)
        self.assertIn('DOS_REGIONAL="$dos_regional"', prepare)
        self.assertIn('DOS_WIN_SYSTEM=', prepare)
        target = (ROOT / 'tools/dos_csmwrap_target.sh').read_text()
        self.assertIn('. "$LIB/dos_win3_menu.sh"', target)
        # Before the Setup answers (manual drops W3PL.KEY before it is copied).
        self.assertLess(target.index('dos_regional_apply "$U"'), target.index('cp "$U/W3PL.KEY" "$U/SETUP.KEY"'))
        self.assertIn('("tools/dos_win3_menu.sh", "usr/lib/usos/dos_win3_menu.sh")', (ROOT / 'tools/build_micro_linux.py').read_text())
        install = text('install.cmd')
        dos_done = install[install.index(':dos_done'):]
        self.assertIn('type %USRC%\\REGCFG.SYS>>C:\\CONFIG.SYS', dos_done)
        self.assertIn('type %USRC%\\REGAUTO.BAT>>C:\\AUTOEXEC.BAT', dos_done)
        # No IF with a redirection (COMMAND.COM opens the file even when false).
        for line in install.splitlines():
            if line.lower().startswith('if ') and '>>' in line:
                self.fail(line)
        staging = (ROOT / 'src/platform/uefi/answer_profiles.zig').read_text()
        self.assertIn('answer.dos.render(profile, &rendered)', staging)
        self.assertIn('for (answer.dos.staged)', staging)


if __name__ == '__main__':
    unittest.main()
