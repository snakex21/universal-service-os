"""Run only CMD dispatch with dummy children; never invoke Windows Setup."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class StartupExit(unittest.TestCase):
    def test_repair_success_and_failure_both_stop_before_setup(self):
        script=(ROOT/'tools/windows7_modern_startup.cmd').read_text()
        start=script.index('"%~dp0usos-win7-kmdf-repair.exe"')
        stop=script.index('rem Stage optional')
        fragment=script[start:stop].replace('"%~dp0usos-win7-kmdf-repair.exe"','call "%~dp0repair-stub.cmd"')
        scratch=ROOT/'zig-out/startup-exit-tests';scratch.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as temp:
            folder=Path(temp)
            harness=folder/'gate.cmd';harness.write_text('@echo off\n'+fragment+'\necho NEXT-STAGE\nexit /b 0\n')
            for code in (0,1,10,9009):
                with self.subTest(code=code):
                    (folder/'repair-stub.cmd').write_text('@echo off\nexit /b '+str(code)+'\n')
                    result=subprocess.run(['cmd','/d','/c',str(harness)],capture_output=True,text=True)
                    self.assertEqual(code==10,'NEXT-STAGE' in result.stdout)
                    self.assertEqual(0 if code==10 else code,result.returncode)
    def test_modern_setup_failure_reaches_launcher(self):
        script = (ROOT / 'tools/windows_iso_startup.cmd').read_text()
        # Start after mounting; the dummy modern child returns before generic Setup.
        fragment = script[script.index('echo Selected Windows installation ISO'):]
        scratch = ROOT / 'zig-out/startup-exit-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as temp:
            folder = Path(temp)
            (folder / 'usos-modern-win7.flag').write_text('1')
            (folder / 'usos-modern-win7.cmd').write_text('@echo off\nexit /b 31\n')
            harness = folder / 'dispatch.cmd'
            harness.write_text('@echo off\n' + fragment)
            result = subprocess.run(['cmd', '/d', '/c', str(harness)], capture_output=True, text=True)
            self.assertEqual(31, result.returncode, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
