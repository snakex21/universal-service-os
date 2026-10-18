"""Host test: USB mouse for DOS programs (docs/dos-mouse-2026-10-18.md).

* FreeDOS and MS-DOS RAM sessions load VBADOS VBMOUSE.EXE (INT 33h over the
  BIOS PS/2 services, which SeaBIOS under CSMWrap serves for the USB mouse);
  the files reach the RAM disk and the stick's payload.
* Windows 95/98/98 SE under CSMWrap: DOSMOUSE.BAT runs VBMOUSE for one
  MS-DOS mode session (DOSSTART.BAT) and unloads it before Windows starts,
  never inside a DOS box (INWIN.COM); AUTOEXEC.BAT adds the DOSSTART line,
  not on Me; USOSKEY.COM still never touches INT 15h C207h by itself.
QEMU: tools/tests/legacy_bios/run_dos_mouse_probe.py (both modes).
"""
from pathlib import Path
import re, sys, unittest

ROOT = Path(__file__).resolve().parents[2]
BIOS = ROOT / 'src/platform/bios'
sys.path.insert(0, str(ROOT / 'tools'))


def lines(path):
    return [l.strip() for l in path.read_text(encoding='ascii').splitlines()]


def code(path):
    return [l for l in lines(path) if l and not l.upper().startswith('REM')]


class Sessions(unittest.TestCase):
    def test_freedos_autoexec_loads_vbmouse_before_the_file_manager(self):
        l = code(BIOS / 'freedos/fdauto.cmd')
        self.assertLess(l.index(r'if exist C:\VBMOUSE.EXE C:\VBMOUSE.EXE'), l.index(r'call C:\TOOLS.BAT'))

    def test_freedos_ram_disk_and_build_get_the_driver(self):
        zig = (BIOS / 'freedos_tools.zig').read_text(encoding='ascii')
        self.assertIn('"VBMOUSE.EXE", "VBADOS.TXT"', zig)
        build = (ROOT / 'tools/build_freedos_support.py').read_text(encoding='ascii')
        self.assertIn("for name in ('VBMOUSE.EXE','VBADOS.TXT')", build)

    def test_msdos_live_session_loads_vbmouse_before_the_listing(self):
        l = code(BIOS / 'msdos/live.cmd')
        self.assertLess(l.index(r'if exist C:\VBMOUSE.EXE C:\VBMOUSE.EXE'), l.index('cls'))
        zig = (BIOS / 'dos6_native_iso.zig').read_text(encoding='ascii')
        self.assertIn('"VBMOUSE.EXE", "VBADOS.TXT"', zig)

    def test_payload_lists(self):
        go = (ROOT / 'installer/cmd/usos-payload-pack/main.go').read_text(encoding='utf-8')
        golden = (ROOT / 'tools/tests/golden/staged_payloads.tsv').read_text(encoding='utf-8')
        ps1 = (ROOT / 'tools/verify_release_consistency.ps1').read_text(encoding='utf-8')
        for path in ('freedos/VBMOUSE.EXE', 'freedos/VBADOS.TXT', 'win9x/DOSMOUSE.BAT', 'win9x/INWIN.COM'):
            self.assertIn('`EFI/USOS/dos-native/' + path + '`', go)
            self.assertIn('payload_zip\tEFI/USOS/dos-native/' + path + '\n', golden)
        self.assertIn("'DOSZIP.TXT','VBMOUSE.EXE','VBADOS.TXT'", ps1)
        self.assertEqual(ps1.count('dos-native/win9x/DOSMOUSE.BAT'), 2)


class Win9xDosMode(unittest.TestCase):
    def setUp(self):
        self.bat = lines(BIOS / 'win9x/dosmouse.cmd')
        self.code = code(BIOS / 'win9x/dosmouse.cmd')

    def test_batch_lines_fit_command_com(self):
        for line in (BIOS / 'win9x/dosmouse.cmd').read_text(encoding='ascii').splitlines():
            self.assertLessEqual(len(line), 127, line)

    def test_labels_unique_in_eight_characters(self):
        labels = [l[1:].upper()[:8] for l in self.code if l.startswith(':')]
        self.assertEqual(len(labels), len(set(labels)), labels)
        for target in re.findall(r'GOTO (\w+)', '\n'.join(self.code)):
            self.assertIn(target.upper()[:8], labels)

    def test_never_inside_windows_and_driver_unloaded_before_exit(self):
        c = self.code
        inwin, load = c.index(r'C:\USOS9X\INWIN.COM'), c.index(r'C:\USOS9X\VBMOUSE.EXE')
        self.assertEqual(c[inwin + 1], 'IF ERRORLEVEL 1 GOTO INWIN')
        self.assertLess(inwin, load)
        shell, unload, leave = c.index('%COMSPEC%'), c.index(r'C:\USOS9X\VBMOUSE.EXE UNINSTALL'), c.index('EXIT')
        self.assertLess(load, shell)
        self.assertLess(shell, unload)
        self.assertEqual(c[unload + 1], 'IF ERRORLEVEL 1 GOTO STUCK')
        self.assertLess(unload, leave)
        # A failed unload never reaches EXIT (back to Windows): it loops to the shell.
        stuck = c.index(':STUCK')
        self.assertEqual(c[stuck + 3], 'GOTO SHELL')
        # EXIT ignored by a primary shell: the batch ends instead of falling into STUCK.
        self.assertEqual(c[leave + 1], 'GOTO END')

    def test_setup_appends_once_with_a_line_break_first(self):
        c = self.code
        s = c.index(':SETUP')
        self.assertIn(r'FIND.EXE /I "DOSMOUSE" C:\WINDOWS\DOSSTART.BAT >NUL', c[s + 3])
        self.assertEqual(c[s + 4], 'IF NOT ERRORLEVEL 1 GOTO END')
        add = c.index(':ADD')
        self.assertEqual(c[add + 1], r'ECHO.>>C:\WINDOWS\DOSSTART.BAT')
        self.assertEqual(c[add + 2], r'ECHO CALL C:\USOS9X\DOSMOUSE.BAT>>C:\WINDOWS\DOSSTART.BAT')
        # No IF with a redirection (COMMAND.COM opens the file even when false).
        for line in c:
            if line.startswith('IF ') and '>>' in line:
                self.fail(line)

    def test_install_bat_wiring(self):
        l = lines(BIOS / 'dos_startup.cmd')
        self.assertIn(r'FOR %%F IN (DOSMOUSE.BAT INWIN.COM) DO COPY /Y A:\%%F C:\USOS9X >NUL', l)
        key = l.index(r'ECHO @C:\USOS9X\USOSKEY.COM>>C:\AUTOEXEC.BAT')
        me = l.index('IF "%U9SYS%"=="ME" GOTO DMDONE')
        line = l.index(r'ECHO @IF EXIST C:\USOS9X\DOSMOUSE.BAT CALL C:\USOS9X\DOSMOUSE.BAT SETUP>>C:\AUTOEXEC.BAT')
        self.assertLess(key, me)
        self.assertLess(me, line)
        self.assertEqual(l[line + 1], ':DMDONE')
        # Inside the CSMWrap AUTOEXEC branch (U9CSM=1) only.
        self.assertLess(l.index(':CSMAUTO'), me)
        self.assertLess(line, l.index(':AUTODONE'))
        for raw in (BIOS / 'dos_startup.cmd').read_text(encoding='ascii').splitlines():
            if 'DOSMOUSE' in raw or 'DMDONE' in raw:
                self.assertLessEqual(len(raw), 127, raw)

    def test_staged_for_both_paths(self):
        import build_win9x_support as b
        for name in ('DOSMOUSE.BAT', 'INWIN.COM'):
            self.assertIn(name, b.FILES)
            self.assertIn(name, b.STAGED)
        zig = (BIOS / 'dos_native_iso.zig').read_text(encoding='ascii')
        self.assertIn('"DOSMOUSE.BAT", "INWIN.COM"', zig)

    def test_inwin_reads_the_windows_install_check(self):
        s = (BIOS / 'win9x/inwin.S').read_text(encoding='ascii')
        for needle in ('mov ax, 0x1600', 'int 0x2f', 'test al, 0x7f', 'mov ah, 0x4c'):
            self.assertIn(needle, s)

    def test_usoskey_tsr_never_registers_the_bios_mouse_itself(self):
        # Hand-over rule: in DOS VBMOUSE owns C207h; in Windows USOSMOUS.DRV
        # registers the TSR's mcb. The TSR itself makes no C2xxh call.
        s = (BIOS / 'msdos/usoskey.S').read_text(encoding='ascii')
        self.assertNotRegex(s, re.compile(r'mov\s+ax,\s*0xc20', re.I))


if __name__ == '__main__':
    unittest.main()
