"""Execute the production CMD selection/registration flow with inert I/O.

No host hive, driver or device is touched: every I/O command is replaced
before cmd.exe runs. The original branching and error handling is preserved.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest
import sys

ROOT = Path(__file__).resolve().parents[2]


class Fallback(unittest.TestCase):
    def test_packaged_script_and_driver_match_the_sources(self):
        archive = ROOT / 'zig-out/windows-native/modern-support.cpio'
        if not archive.exists():
            self.skipTest('Run build.bat to verify the packaged helpers')
        sys.path.insert(0, str(ROOT / 'tools'))
        from build_micro_linux import parse_newc
        members = {name: e.data for name, e in parse_newc(archive.read_bytes()).items()}
        self.assertEqual((ROOT / 'tools/windows_x86_csmwrap.cmd').read_bytes().replace(b'\r\n', b'\n'),
                         members['usos-x86-csmwrap.cmd'].replace(b'\r\n', b'\n'))
        self.assertEqual((ROOT / 'tools/nt4/usosusb/bin/nt6/i386/usosusb.sys').read_bytes(),
                         members['usosusb-nt6.sys'])

    def test_registration_failure_prevents_the_next_setup_step(self):
        script = (ROOT / 'tools/windows_x86_csmwrap.cmd').read_text()
        gate = script.split('call :nt60_usb\n', 1)[1].split('call :nvme\n', 1)[0]
        scratch = ROOT / 'tools/tests/artifacts/win7-usb-cmd'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as temp:
            harness = Path(temp) / 'failure.cmd'
            harness.write_text('@echo off\ncmd /d /c exit /b 1\n' + gate + '\necho NEXT-STAGE\n')
            result = subprocess.run(['cmd', '/d', '/c', str(harness)], capture_output=True, text=True)
            self.assertEqual(1, result.returncode)
            self.assertNotIn('NEXT-STAGE', result.stdout)

    def test_missing_second_msu_glob_does_not_override_a_real_first_package(self):
        script = (ROOT / 'tools/windows_x86_csmwrap.cmd').read_text()
        line = next(s for s in script.splitlines() if s.startswith('for %%M in '))
        scratch = ROOT / 'tools/tests/artifacts/win7-usb-cmd'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as temp:
            folder = Path(temp)
            (folder / 'Updates').mkdir()
            wanted = folder / 'Updates/windows6.1-kb2685811-x86_test.msu'
            wanted.write_bytes(b'filename selection only')
            harness = folder / 'select.cmd'
            harness.write_text('@echo off\nset "USOS_KMDF_MSU="\n' + line + '\necho SELECTED=%USOS_KMDF_MSU%\n')
            result = subprocess.run(['cmd', '/d', '/c', str(harness)],
                                    env=dict(os.environ, USOS_DATA=temp), capture_output=True, text=True)
            self.assertEqual(0, result.returncode)
            self.assertIn('SELECTED=' + str(wanted), result.stdout)

    def run_step(self, nt='6.1', build='7601', package=False, conflict=False, fail=''):
        script = (ROOT / 'tools/windows_x86_csmwrap.cmd').read_text(encoding='utf-8')
        step = script.split('\n:nt60_usb\n', 1)[1].split('\n:nvme_pe_driver\n', 1)[0]
        step = re.sub(r'^"%~dp0usos-x86-csmwrap.exe" target .*$',
                      lambda _: f'>"%TEMP%\\usos-target.txt" echo C: {nt} {build}', step, flags=re.M)
        step = re.sub(r'^for /f .*reg query .*Current.*$', 'set "USOS_CS=1"', step, flags=re.M)
        step = step.replace('copy /y ', 'call :copy_mock ')
        step = step.replace('"%~dp0usos-x86-csmwrap.exe" samefile ', 'call :samefile_mock ')
        step = step.replace('reg ', 'call :reg_mock ')
        step = step.replace('"%~dp0usos-log-x86.exe"', 'echo LOG-COLLECTOR')
        self.assertNotRegex(step, r'(?im)^\s*(reg |copy |"%~dp0[^"\n]*\.exe")')
        scratch = ROOT / 'tools/tests/artifacts/win7-usb-cmd'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as temp:
            directory = Path(temp)
            (directory / 'usosusb-nt6.sys').write_bytes(b'inert-test-file')
            harness = directory / 'step.cmd'
            mocks = r'''
:copy_mock
echo COPY>>"%TRACE%"
if "%FAIL%"=="copy" exit /b 1
exit /b 0
:samefile_mock
if "%FAIL%"=="readback" exit /b 1
exit /b 0
:reg_mock
echo REG %*>>"%TRACE%"
if "%~1"=="load" if "%FAIL%"=="load" exit /b 1
if "%~1"=="add" if "%FAIL%"=="add" exit /b 1
if "%~1"=="query" if "%FAIL%"=="query" exit /b 1
if "%~3"=="/s" exit /b %CONFLICT_RESULT%
exit /b 0
'''
            harness.write_text('@echo off\n' + step + '\n' + mocks)
            trace = directory / 'trace.txt'
            env = dict(os.environ, TEMP=temp, TMP=temp, TRACE=str(trace), FAIL=fail,
                       USOS_USB3_INSTALLED='1' if package else '', CONFLICT_RESULT='0' if conflict else '1')
            result = subprocess.run(['cmd', '/d', '/c', str(harness)], env=env, capture_output=True, text=True)
            return result, trace.read_text() if trace.exists() else ''

    def test_plain_win7_sp1_needs_no_data_files_or_profile(self):
        result, trace = self.run_step()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn('phase=nt61-usb', result.stdout)
        self.assertIn('Services\\usosusb" /v Start /t REG_DWORD /d 1', trace)
        self.assertIn('REG unload HKLM\\USOS_SYS', trace)

    def test_successful_external_package_wins(self):
        result, trace = self.run_step(package=True)
        self.assertEqual(0, result.returncode)
        self.assertEqual('', trace)

    def test_existing_or_partially_installed_xhci_service_wins(self):
        result, trace = self.run_step(conflict=True)
        self.assertEqual(0, result.returncode)
        self.assertIn('existing xHCI service', result.stdout)
        self.assertNotIn('REG add ', trace)
        self.assertIn('REG unload ', trace)

    def test_failures_stop_and_loaded_hive_is_released(self):
        for fail in ('copy', 'readback', 'load', 'query', 'add'):
            with self.subTest(fail=fail):
                result, trace = self.run_step(fail=fail)
                self.assertNotEqual(0, result.returncode, result.stdout)
                if fail in ('query', 'add'):
                    self.assertIn('REG unload ', trace)

    def test_vista_sp2_keeps_its_bundled_driver(self):
        result, trace = self.run_step(nt='6.0', build='6002')
        self.assertEqual(0, result.returncode)
        self.assertIn('REG add ', trace)

    def test_other_systems_are_not_changed(self):
        for nt, build in (('6.0', '6001'), ('6.1', '7600'), ('6.2', '9200'), ('6.3', '9600'), ('10.0', '19045')):
            with self.subTest(nt=nt, build=build):
                result, trace = self.run_step(nt, build)
                self.assertEqual(0, result.returncode)
                self.assertEqual('', trace)


if __name__ == '__main__':
    unittest.main()
