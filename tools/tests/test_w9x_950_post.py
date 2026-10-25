"""tools/w9x_950_post.sh: the 950 SETUP.INI / MONITOR.INF filters (host sh)."""
from pathlib import Path
import shutil, sys, unittest
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


if __name__ == '__main__':
    unittest.main()
