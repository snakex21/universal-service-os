"""Vista first boot: autochk limited to the system volume (tools/vista_autochk.h,
used by tools/windows_vista_oobe_gate.c). Host-only; no registry is touched."""
from pathlib import Path
import os, subprocess, unittest
ROOT = Path(__file__).resolve().parents[2]


class VistaAutochk(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        work = ROOT / 'zig-out/vista-autochk-tests'
        work.mkdir(parents=True, exist_ok=True)
        cls.exe = work / 'vista-autochk.exe'
        env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / 'tools/cache/zig-global'), ZIG_LOCAL_CACHE_DIR=str(work / 'zig-cache'))
        subprocess.run([str(ROOT / 'tools/zig/zig.exe'), 'cc', '-target', 'x86_64-windows-gnu', '-municode',
                        str(ROOT / 'tools/tests/vista_autochk_harness.c'), '-o', str(cls.exe)], env=env, check=True)

    def run_case(self, mask, system='C', current='autocheck autochk *'):
        out = subprocess.run([str(self.exe), f'{mask:x}', system, current], capture_output=True, text=True, check=True).stdout
        lines = dict(line.split('=', 1) for line in out.splitlines())
        return lines['DEFAULT'] == '1', lines['VALUE']

    def test_other_fixed_volumes_are_excluded_system_kept(self):
        # C: system, D: recovery, E: data disk.
        default, value = self.run_case((1 << 2) | (1 << 3) | (1 << 4))
        self.assertTrue(default)
        self.assertEqual('autocheck autochk /k:D /k:E *||', value)

    def test_system_letter_not_c(self):
        default, value = self.run_case((1 << 2) | (1 << 3), system='d')
        self.assertEqual('autocheck autochk /k:C *||', value)

    def test_only_the_system_volume_keeps_the_default(self):
        self.assertEqual('', self.run_case(1 << 2)[1])

    def test_floppy_letters_are_ignored(self):
        self.assertEqual('', self.run_case(0b111)[1])

    def test_only_the_exact_default_is_replaced(self):
        self.assertTrue(self.run_case(1 << 2, current='AUTOCHECK AUTOCHK *')[0])
        self.assertFalse(self.run_case(1 << 2, current='autocheck autochk /k:D *')[0])
        self.assertFalse(self.run_case(1 << 2, current='autocheck custom *')[0])
        self.assertFalse(self.run_case(1 << 2, current='')[0])


if __name__ == '__main__':
    unittest.main()
