"""Windows 7 SP1 x64 on the PE10 path: Setup's NVMe disk check (hwcompat.txt).

Runs only the :nvme_setup fragment of tools/windows7_modern_startup.cmd on
temporary folders (registry query stubbed, SystemDrive redirected); never
Windows Setup, the finalizer, reg load or a reboot.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'tools/windows7_modern_startup.cmd'
REG_QUERY = r'reg query "HKLM\SYSTEM\CurrentControlSet\Services\stornvme\Enum" /v Count'


class Windows7X64NvmeSetup(unittest.TestCase):
    def setUp(self):
        self.text = SCRIPT.read_text()

    def section(self, start, stop):
        return self.text[self.text.index('\n' + start + '\n'):self.text.index('\n' + stop + '\n')]

    def test_called_before_setup_only_with_the_packages(self):
        launch = self.text.index('run-from "%USOS_SETUP%"')
        call = self.text.index('if exist "%~dp0usos-nvme-packages.flag" call :nvme_setup')
        self.assertLess(call, launch)
        # The Setup copy is the working directory of the launch, then left.
        self.assertIn('if defined USOS_NVME_SETUP pushd "%USOS_SRC%\\sources"', self.text[call:launch])
        self.assertIn('if defined USOS_NVME_SETUP popd', self.text[launch:])
        # The boot entry check runs after Setup, before the target EFI step.
        after = self.text.index('if defined USOS_NVME_SETUP call :nvme_target')
        self.assertLess(launch, after)
        self.assertLess(after, self.text.index('after-modern'))

    def test_no_driver_injected_into_the_pe(self):
        # A PE-loaded driver would be migrated through the Windows 10 driver
        # store, which refuses NT 6.1 images (0x80070032, x86 path).
        for forbidden in ('PnpCustomizationsWinPE', 'drvload', 'pnputil'):
            self.assertNotIn(forbidden, self.text)

    def test_target_boot_entry(self):
        s = self.section(':nvme_target', ':nvme_target_done')
        self.assertIn(r'drivers\stornvme.sys', s)
        self.assertIn(r'CriticalDeviceDatabase\pci#cc_010802"', s)
        self.assertIn('/v Service /t REG_SZ /d stornvme', s)
        self.assertIn('{4D36E97B-E325-11CE-BFC1-08002BE10318}', s)
        self.assertIn('/v Start /t REG_DWORD /d 0 ', s)
        self.assertNotRegex(s, r'exit /b [1-9]')
        self.assertIn('reg unload HKLM\\USOS_SYS', self.text[self.text.index('\n:nvme_target_done\n'):])

    def run_fragment(self, count='0x1', boot_wim=True, hwcompat=True):
        fragment = self.section(':nvme_setup', ':nvme_target')
        self.assertEqual(1, fragment.count(REG_QUERY))
        fragment = fragment.replace(REG_QUERY, 'type "%USOS_TEST_REG%"')
        scratch = ROOT / 'zig-out/w7x64-nvme-setup-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        temp = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(temp.cleanup)
        folder = Path(temp.name)
        sources = folder / 'iso/sources'
        (sources / 'pl-PL').mkdir(parents=True)
        (sources / 'setup.exe').write_bytes(b'setup')
        (sources / 'pl-PL/setup.exe.mui').write_bytes(b'mui')
        (sources / 'install.wim').write_bytes(b'image')
        if boot_wim:
            (sources / 'boot.wim').write_bytes(b'boot')
        if hwcompat:
            (sources / 'hwcompat.txt').write_bytes(b'disk.inf:\r\nGenDisk\r\n')
        system = folder / 'X'
        system.mkdir()
        reg = folder / 'reg.txt'
        reg.write_text('' if count is None else '\nHKEY_LOCAL_MACHINE\\x\n    Count    REG_DWORD    ' + count + '\n')
        harness = folder / 'nvme.cmd'
        harness.write_text('@echo off\nset "USOS_NVME_SETUP="\nset "USOS_SETUP=%USOS_SOURCE%\\sources\\setup.exe"\n'
                           'call :nvme_setup\necho SETUP=%USOS_SETUP%\necho FLAG=%USOS_NVME_SETUP%\nexit /b 0\n'
                           + fragment.lstrip('\n') + '\n')
        # System32 first: a POSIX find.exe on PATH (Git Bash) is not find.exe.
        path = os.path.join(os.environ.get('SystemRoot', r'C:\Windows'), 'System32') + os.pathsep + os.environ.get('PATH', '')
        env = dict(os.environ, PATH=path, USOS_SOURCE=str(folder / 'iso'), SystemDrive=str(system), USOS_TEST_REG=str(reg))
        result = subprocess.run(['cmd', '/d', '/c', str(harness)], env=env, capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        return result.stdout, folder, system / 'USOS-src/sources'

    def test_copy_with_nvme_entry(self):
        out, folder, copy = self.run_fragment()
        self.assertIn('SETUP=' + str(copy / 'setup.exe'), out)
        self.assertIn('FLAG=1', out)
        self.assertTrue((copy / 'pl-PL/setup.exe.mui').is_file())
        self.assertTrue((copy / 'boot.wim').is_file())
        self.assertFalse((copy / 'install.wim').exists())
        lines = (copy / 'hwcompat.txt').read_text().splitlines()
        self.assertEqual(['disk.inf:', 'GenDisk'], lines[:2])
        self.assertEqual(['stornvme.inf:', 'PCI\\CC_010802'], lines[-2:])
        # The media itself is never changed.
        self.assertEqual(b'disk.inf:\r\nGenDisk\r\n', (folder / 'iso/sources/hwcompat.txt').read_bytes())

    def test_copy_without_boot_wim(self):
        out, _, copy = self.run_fragment(boot_wim=False)
        self.assertIn('FLAG=1', out)
        self.assertFalse((copy / 'boot.wim').exists())

    def test_no_controller_keeps_original_setup(self):
        for count in (None, '0x0'):
            with self.subTest(count=count):
                out, folder, copy = self.run_fragment(count=count)
                self.assertIn('SETUP=' + str(folder / 'iso/sources/setup.exe'), out)
                self.assertIn('FLAG=\n', out.replace('\r', ''))
                self.assertFalse(copy.exists())

    def test_media_without_hwcompat_keeps_original_setup(self):
        out, folder, copy = self.run_fragment(hwcompat=False)
        self.assertIn('SETUP=' + str(folder / 'iso/sources/setup.exe'), out)
        self.assertFalse(copy.exists())


if __name__ == '__main__':
    unittest.main()
