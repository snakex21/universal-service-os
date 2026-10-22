"""A closed operator pipe must refuse before launching the Windows VM."""
from pathlib import Path
import subprocess
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]

class OperatorContract(unittest.TestCase):
    def test_windows_nul_is_not_a_live_operator_console(self):
        for phase in ('apply03','cold01'):
            with self.subTest(phase=phase):
                result=subprocess.run([sys.executable,'-I','-B',str(ROOT/'tools/tests/coverage/boot_nt35_client.py'),'--phase',phase],
                                      stdin=subprocess.DEVNULL,capture_output=True,timeout=5)
                self.assertNotEqual(result.returncode,0)
                self.assertIn(b'Live operator PTY required before any VM start',result.stdout+result.stderr)
                self.assertNotIn(b'COLD_BOOT_STARTED',result.stdout+result.stderr)

    def test_redirected_stdin_is_rejected_before_vm_launch(self):
        result=subprocess.run([sys.executable,'-I','-B',str(ROOT/'tools/tests/coverage/boot_nt35_client.py')],
                              input=b'',capture_output=True,timeout=5)
        self.assertNotEqual(result.returncode,0)
        self.assertIn(b'Live operator PTY required before any VM start',result.stdout+result.stderr)
        self.assertNotIn(b'COLD_BOOT_STARTED',result.stdout+result.stderr)

    def test_preparation_rejects_output_path_traversal_before_disk_access(self):
        result=subprocess.run([sys.executable,'-I','-B',str(ROOT/'tools/tests/coverage/prepare_nt35_client.py'),'--tag','../../outside'],
                              input=b'',capture_output=True,timeout=5)
        self.assertNotEqual(result.returncode,0)
        self.assertIn(b'Fixed owned apply tag required',result.stdout+result.stderr)

if __name__=='__main__':unittest.main()
