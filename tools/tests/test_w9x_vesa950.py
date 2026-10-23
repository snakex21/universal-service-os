"""Execute the pinned MIT derivative recipe, including fail-closed cases."""
from pathlib import Path
import hashlib, shutil, sys, unittest
sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_w9x_phase1_qemu import sh, scratch

ROOT = Path(__file__).resolve().parents[2]
LIB = (ROOT / 'tools/w9x_vesa950.sh').as_posix()
VENDOR = ROOT / 'tools/vendor/vmdisp9x/1.2025.0.119'
AFTER = '3658d7c3c3314f50ac6f05a034109dd88993433b6d1b216f07297f96c66bdd67'

class Vesa950(unittest.TestCase):
    def setUp(self):
        self.tmp = scratch('vesa950-')
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.driver = self.tmp / 'VESAMINI.DRV'
        self.original = (VENDOR / 'vesamini.drv').read_bytes()
        self.driver.write_bytes(self.original)
        (self.tmp / 'VMDISP9X.TXT').write_bytes(b'MIT license notice preserved\r\n')

    def run_recipe(self, version='4 0 0 950'):
        return sh(f'. "{LIB}"\nw9x_vesa950_prepare "{self.tmp.as_posix()}" "{version}"')

    def test_exact_derivative_preserves_ne_abi_and_vendor(self):
        rc, out, err = self.run_recipe()
        self.assertEqual(rc, 0, out + err)
        changed = self.driver.read_bytes()
        self.assertEqual(hashlib.sha256(changed).hexdigest(), AFTER)
        self.assertEqual([i for i, pair in enumerate(zip(self.original, changed)) if pair[0] != pair[1]], list(range(7873, 7877)))
        self.assertEqual(len(changed), len(self.original))
        self.assertEqual((VENDOR / 'vesamini.drv').read_bytes(), self.original)
        self.assertIn(b'MIT license notice preserved', (self.tmp / 'VMDISP9X.TXT').read_bytes())
        self.assertIn(b'USOS MODIFICATION', (self.tmp / 'VMDISP9X.TXT').read_bytes())
        self.assertFalse((self.tmp / 'VES950.TMP').exists())

    def test_non950_sources_are_noop_even_without_driver(self):
        for version in ('4 0 0 1068', '4 0 0 1111', '', '4.0.0.950'):
            rc, out, err = self.run_recipe(version)
            self.assertEqual(rc, 0, out + err)
            self.assertEqual(self.driver.read_bytes(), self.original)
        self.driver.unlink()
        self.assertEqual(self.run_recipe('4 0 0 1111')[0], 0)

    def test_unknown_or_already_modified_input_is_rejected_untouched(self):
        bad = bytearray(self.original)
        bad[-1] ^= 1
        self.driver.write_bytes(bad)
        notice = (self.tmp / 'VMDISP9X.TXT').read_bytes()
        self.assertNotEqual(self.run_recipe()[0], 0)
        self.assertEqual(self.driver.read_bytes(), bad)
        self.assertEqual((self.tmp / 'VMDISP9X.TXT').read_bytes(), notice)
        self.assertFalse((self.tmp / 'VES950.TMP').exists())

    def test_idempotence_and_unowned_temporary_file_guard(self):
        temp = self.tmp / 'VES950.TMP'
        temp.write_bytes(b'preserve')
        self.assertNotEqual(self.run_recipe()[0], 0)
        self.assertEqual(temp.read_bytes(), b'preserve')
        self.assertEqual(self.driver.read_bytes(), self.original)
        temp.unlink()
        self.assertEqual(self.run_recipe()[0], 0)
        first = {p.name: p.read_bytes() for p in self.tmp.iterdir()}
        self.assertEqual(self.run_recipe()[0], 0)
        self.assertEqual({p.name: p.read_bytes() for p in self.tmp.iterdir()}, first)

    def test_target_and_initrd_wiring(self):
        target = (ROOT / 'tools/w9x_csmwrap_target.sh').read_text()
        block = target[target.index('# The pinned MIT VESA driver'):target.index('# Display: the answer')]
        self.assertIn('95:4 0 0 950', block)
        self.assertIn('|| fail', block)
        self.assertIn('w9x_vesa950_prepare "$work/c/USOS9X" "$setup_version"', block)
        self.assertLess(target.index(block), target.index('usos_display_stage'))
        self.assertIn('("tools/w9x_vesa950.sh", "usr/lib/usos/w9x_vesa950.sh")', (ROOT / 'tools/build_micro_linux.py').read_text())

if __name__ == '__main__':
    unittest.main()
