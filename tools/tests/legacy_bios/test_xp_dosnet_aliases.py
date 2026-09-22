"""Exercise DOSNET parsing, including untrusted path and collision rejection."""
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AWK = shutil.which('awk') or r'C:\Program Files\Git\usr\bin\awk.exe'


class AliasTests(unittest.TestCase):
    def parse(self, text, system='windows-xp'):
        return subprocess.run([AWK, '-v', 'nt5_system='+system, '-f', str(ROOT / 'tools/xp_dosnet_aliases.awk')],
                              input=text, text=True, capture_output=True)

    def test_multiple_local_names_and_original_boot_destinations(self):
        result = self.parse('[Directories]\r\nd1 = \\I386\r\n[Files]\r\n'
                            'd1,mshta.mui\r\nd1,mshta.mui,mshta.mu_\r\n'
                            'd1,usetup.exe,system32\\smss.exe\r\n'
                            'd1,mshta.mui,mshta.mu_\r\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['MSHTA.MUI|MSHTA.MU_', 'USETUP.EXE|SYSTEM32/SMSS.EXE'])

    def test_only_files_section_and_subdirectories(self):
        result = self.parse('[Directories]\nd11="\\i386\\NLDRV\\001"\n'
                            '[FloppyFiles.1]\nd1,disk1,disk101\n[Files]\n'
                            'd11,driver.sys,other.sys ; comment\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'NLDRV/001/DRIVER.SYS|NLDRV/001/OTHER.SYS')

    def test_rejects_escaping_paths_and_conflicting_names(self):
        for row in ['d1,a,../escape', 'd1,a,/absolute', 'd1,a,C:\\escape',
                    'd1,../source,a', 'd1,a,a|b', 'd2,a,b', 'd1,a,c\nd1,b,c']:
            with self.subTest(row=row):
                result = self.parse('[Directories]\nd1=\\I386\n[Files]\n' + row)
                self.assertNotEqual(result.returncode, 0)

    def test_stock_source_without_aliases(self):
        result = self.parse('[Directories]\nd1=\\I386\n[Files]\nd1,ntldr\n')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_windows_2000_relative_root_is_explicit_and_bounded(self):
        source = '[Directories]\nd1=\\\n[Files]\nd1,usetup.exe,system32\\smss.exe\n'
        result = self.parse(source, 'windows-2000')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'USETUP.EXE|SYSTEM32/SMSS.EXE')
        self.assertNotEqual(self.parse(source).returncode, 0)
        self.assertNotEqual(self.parse(source.replace('d1=\\', 'd2=\\'), 'windows-2000').returncode, 0)
        self.assertNotEqual(self.parse(source.replace('d1=\\', 'd1=\\..'), 'windows-2000').returncode, 0)


if __name__ == '__main__':
    unittest.main()
