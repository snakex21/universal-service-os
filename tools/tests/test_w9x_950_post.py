"""tools/w9x_950_post.sh: the 950 SETUP.INI / MONITOR.INF filters (host sh)."""
from pathlib import Path
import shutil, subprocess, sys, unittest
sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_w9x_phase1_qemu import sh, scratch
ROOT = Path(__file__).resolve().parents[2]
LIB = (ROOT / 'tools/w9x_950_post.sh').as_posix()

# Shape of the X470 950 PL C:\WINDOWS\SETUP.INI (2026-10-25, w95rtm-micron3),
# CP1250 bytes kept.
SETUP_INI = (b'[progman.groups]\r\ngroup3=Grupa g\xb3\xf3wna\r\ngroup4=Akcesoria\r\n\r\n'
             b'[group4]\r\n"Notatnik"\r\n\r\n'
             b'[progman.only]\r\nPMGroup3=Grupa g\xb3\xf3wna\r\n\r\n'
             b'[PMGroup3]\r\n"Panel sterowania",control.exe,shell32.dll,35\r\n"Tryb MS-DOS"\r\n\r\n'
             b'[groupDoc]\r\n"x"\r\n')
# Shape of the 950 MONITOR.INF (the same lines on the PL and EN CDs).
MONITOR_INF = (b'[1600]\r\nHKR,,MaxResolution,,"1600,1200"\r\n\r\n[DPMS]\r\nHKR,,DPMS,,1\r\n\r\n'
               b'[VESADDC.Install]\r\nDelReg=DEL_CURRENT_REG\r\nAddReg=VESADDC.AddReg, 1600, DPMS\r\n\r\n'
               b'[Laptop640.Install]\r\nDelReg=DEL_CURRENT_REG\r\nAddReg=640, DPMS \r\n\r\n'
               b'[NEC1.Install]\r\nAddReg=NEC1.AddReg, 1600, DPMS\r\n\r\n'
               b'[VESADDC.AddReg]\r\nHKR,"MODES\\1600,1200"\r\n\r\n[Strings]\r\nx="\xb3"\r\n')


class Filters(unittest.TestCase):
    def setUp(self):
        self.tmp = scratch('w950post-')
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def run_filter(self, kind, data):
        (self.tmp / 'in').write_bytes(data)
        rc, out, err = sh(f'. "{LIB}"\nw9x_950_{kind}_filter < "{(self.tmp / "in").as_posix()}" > "{(self.tmp / "out").as_posix()}"')
        return rc, (self.tmp / 'out').read_bytes(), err

    def test_setupini_drops_only_the_progman_only_entries(self):
        rc, out, err = self.run_filter('setupini', SETUP_INI)
        self.assertEqual(rc, 0, err)
        self.assertEqual(out, SETUP_INI.replace(b'PMGroup3=Grupa g\xb3\xf3wna\r\n', b''))
        self.assertIn(b'[progman.only]\r\n\r\n[PMGroup3]', out)
        # Already clean (second run) or no such section: exit 3, caller keeps the file.
        self.assertEqual(self.run_filter('setupini', out)[0], 3)
        self.assertEqual(self.run_filter('setupini', b'[progman.groups]\r\ngroup1=x\r\n')[0], 3)

    def test_monitorinf_only_vesaddc_gets_its_own_max_resolution(self):
        rc, out, err = self.run_filter('monitorinf', MONITOR_INF)
        self.assertEqual(rc, 0, err)
        self.assertIn(b'[VESADDC.Install]\r\nDelReg=DEL_CURRENT_REG\r\nAddReg=VESADDC.AddReg, USOS.MaxRes, DPMS\r\n', out)
        # The shared [1600] section and other models stay as they were.
        self.assertIn(b'[1600]\r\nHKR,,MaxResolution,,"1600,1200"\r\n', out)
        self.assertIn(b'[NEC1.Install]\r\nAddReg=NEC1.AddReg, 1600, DPMS\r\n', out)
        self.assertIn(b'AddReg=640, DPMS \r\n', out)
        self.assertTrue(out.endswith(b'[USOS.MaxRes]\r\nHKR,,MaxResolution,,"1920,1200"\r\nHKR,"MODES\\1920,1200"\r\n'))
        self.assertIn(b'x="\xb3"\r\n', out)
        self.assertEqual(out.count(b'\n'), out.count(b'\r\n'))
        # Unknown layout (no 1600 in VESADDC.Install): exit 3.
        self.assertEqual(self.run_filter('monitorinf', MONITOR_INF.replace(b'VESADDC.AddReg, 1600', b'VESADDC.AddReg, 1280'))[0], 3)

    def test_prepare_runs_it_for_950_only_after_phase1(self):
        text = (ROOT / 'tools/w9x_csmwrap_prepare.sh').read_text(encoding='utf-8')
        call = text.index('w9x_950_post_inject')
        self.assertLess(text.index('PHASE1 PASS'), call)
        self.assertIn('[ "$W9X_VM_95_SETUP950" = 1 ]', text[call - 400:call])
        staged = (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8')
        self.assertIn('("tools/w9x_950_post.sh", "usr/lib/usos/w9x_950_post.sh")', staged)


class NativeTwin(unittest.TestCase):
    """Native phase 1: VESBIND PMDROP / MAXRES give the awk filters' bytes,
    W950POST.BAT runs them before FIRSTBT.BAT and writes PHASE1.OK."""

    @classmethod
    def setUpClass(cls):
        from test_w9x_vesbind import host_binary
        cls.vesbind = host_binary()

    def setUp(self):
        self.tmp = scratch('w950dos-')
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def awk(self, kind, data):
        (self.tmp / 'in').write_bytes(data)
        rc, _, err = sh(f'. "{LIB}"\nw9x_950_{kind}_filter < "{(self.tmp / "in").as_posix()}" > "{(self.tmp / "out").as_posix()}"')
        return rc, (self.tmp / 'out').read_bytes()

    def dos(self, verb, data):
        (self.tmp / 'din').write_bytes(data)
        out = self.tmp / 'dout'
        if out.exists():
            out.unlink()
        r = subprocess.run([str(self.vesbind), verb, str(self.tmp / 'din'), str(out)], capture_output=True)
        self.assertFalse(r.stdout + r.stderr)
        return r.returncode, out.read_bytes() if out.exists() else None

    def same(self, kind, verb, data):
        arc, aout = self.awk(kind, data)
        drc, dout = self.dos(verb, data)
        if arc == 0:
            self.assertEqual(drc, 0)
            self.assertEqual(dout, aout)
        else:
            self.assertEqual((arc, drc), (3, 1))
        return drc, dout

    def test_pmdrop_matches_the_awk_filter(self):
        cases = [SETUP_INI, SETUP_INI.replace(b'\r\n', b'\n'), SETUP_INI + b'[progman.only]\r\nx=1',
                 SETUP_INI.replace(b'[progman.only]', b' [ProgMan . Only] '),
                 SETUP_INI.replace(b'PMGroup3', b'; comment\r\n\t\r\nPMGroup3'),
                 b'[progman.groups]\r\ngroup1=x\r\n', b'']
        for data in cases:
            with self.subTest(data=data[:40]):
                self.same('setupini', 'PMDROP', data)
        rc, out = self.dos('PMDROP', SETUP_INI)
        self.assertEqual(rc, 0)
        self.assertEqual(self.dos('PMDROP', out)[0], 1)  # the batch's check run

    def test_maxres_matches_the_awk_filter(self):
        cases = [MONITOR_INF, MONITOR_INF.replace(b'\r\n', b'\n'),
                 MONITOR_INF.replace(b'AddReg=VESADDC.AddReg, 1600, DPMS', b'ADDREG \t= ,VESADDC.AddReg,,1600 ,DPMS,'),
                 MONITOR_INF.replace(b'VESADDC.AddReg, 1600', b'VESADDC.AddReg, 1280'),
                 MONITOR_INF.replace(b'DelReg=DEL_CURRENT_REG\r\nAddReg=VESADDC', b'AddReg=1600\r\nAddReg=VESADDC'),
                 MONITOR_INF + b'[x]\r\nlast line', b'']
        for data in cases:
            with self.subTest(data=data[-40:]):
                self.same('monitorinf', 'MAXRES', data)
        rc, out = self.dos('MAXRES', MONITOR_INF)
        self.assertEqual(rc, 0)
        self.assertEqual(self.dos('MAXRES', out)[0], 1)  # marker: already done, as the inject's grep

    def test_missing_input_and_overlong_lines_fail_closed(self):
        r = subprocess.run([str(self.vesbind), 'PMDROP', str(self.tmp / 'none'), str(self.tmp / 'o')], capture_output=True)
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.dos('MAXRES', b'[VESADDC.Install]\r\nAddReg=' + b'x' * 900 + b'\r\n')[0], 2)

    def test_w950post_bat(self):
        rc, _, err = sh(f'. "{LIB}"\nw9x_950_post_dos_write "{self.tmp.as_posix()}"')
        self.assertEqual(rc, 1, 'needs VESBIND.EXE next to it')
        (self.tmp / 'VESBIND.EXE').write_bytes(b'MZ')
        rc, _, err = sh(f'. "{LIB}"\nw9x_950_post_dos_write "{self.tmp.as_posix()}"')
        self.assertEqual(rc, 0, err)
        data = (self.tmp / 'W950POST.BAT').read_bytes()
        self.assertEqual(data.count(b'\n'), data.count(b'\r\n'))
        lines = data.decode('ascii').splitlines()
        self.assertTrue(all(len(l) < 127 for l in lines))
        self.assertEqual(lines[2:6], [r'IF EXIST C:\USOS9X\PHASE1.OK GOTO END', r'IF NOT EXIST C:\WINDOWS\WIN.COM GOTO END',
                                      # a Product ID staged for Setup's page (USOSPID.KEY) goes at the latest here
                                      r'IF EXIST C:\USOS9X\USOSPID.KEY DEL C:\USOS9X\USOSPID.KEY',
                                      r'IF NOT EXIST C:\WINDOWS\SYSTEM.DAT GOTO END'])
        for verb, src, new in (('PMDROP', r'C:\WINDOWS\SETUP.INI', r'C:\USOS9X\SETUPINI'),
                               ('MAXRES', r'C:\WINDOWS\INF\MONITOR.INF', r'C:\USOS9X\MONINF')):
            run = lines.index(rf'C:\USOS9X\VESBIND.EXE {verb} {src} {new}.NEW')
            self.assertEqual(lines[run + 1:run + 3], ['IF ERRORLEVEL 2 GOTO %sBAD' % verb[:2].replace('MA', 'MN'),
                                                     'IF ERRORLEVEL 1 GOTO %sNONE' % verb[:2].replace('MA', 'MN')])
            self.assertEqual(lines[run + 4], rf'COPY /Y {new}.NEW {src} > NUL')
            self.assertEqual(lines[run + 5], rf'C:\USOS9X\VESBIND.EXE {verb} {src} {new}.CHK')
        mark = lines.index(':MARK')
        self.assertEqual(lines[mark + 1:], [r'ECHO phase1=native> C:\USOS9X\PHASE1.OK', ':END'])
        labels = {l for l in lines if l.startswith(':')}
        for l in lines:
            if 'GOTO ' in l:
                self.assertIn(':' + l.split('GOTO ')[1], labels)

    def test_install_bat_and_target_wire_it_for_native_950_only(self):
        install = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='latin-1').splitlines()
        post = install.index(r'ECHO @IF EXIST C:\USOS9X\W950POST.BAT CALL C:\USOS9X\W950POST.BAT>>C:\AUTOEXEC.BAT')
        first = install.index(r'ECHO @IF EXIST C:\USOS9X\FIRSTBT.BAT CALL C:\USOS9X\FIRSTBT.BAT>>C:\AUTOEXEC.BAT')
        self.assertLess(post, first)
        self.assertGreater(post, install.index(':CSMAUTO'))
        target = (ROOT / 'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
        call = target.index('w9x_950_post_dos_write "$work/c/USOS9X"')
        self.assertIn('''if [ "${VM_PHASE1:-0}" != 1 ] && [ "$SYSTEM_TAG:${setup_version:-}" = '95:4 0 0 950' ]; then''',
                      target[call - 300:call])
        self.assertIn('rm -f "$work/c/USOS9X/W950POST.BAT"', target[call - 400:call])
        self.assertLess(target.index('w9x_firstboot_write'), call)
        self.assertLess(call, target.index('> "$work/AUTOEXEC.BAT"'))
        # The VM path writes PHASE1.OK itself and injects the same fixes.
        self.assertIn('PHASE1.OK', (ROOT / 'tools/w9x_phase1_qemu.sh').read_text(encoding='utf-8'))
        # FIRSTBT.BAT waits for exactly that marker.
        self.assertIn(r'IF NOT EXIST C:\USOS9X\PHASE1.OK GOTO END', (ROOT / 'tools/w9x_firstboot.sh').read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
