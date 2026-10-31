#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import asyncio,os,sys,tempfile,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'minios'))
import diagnostic_boot_runner as runner

class Tests(unittest.TestCase):
    def test_guest_exit_33_is_observed_and_logs_are_bounded(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[2]/'runtime') as tmp:
            scope=runner.Scope(Path(tmp))
            rc=asyncio.run(runner.run_guest(['pwsh','-NoProfile','-Command','Write-Output diagnostic; exit 33'],scope,os.environ.copy(),b'HEAD=test DIRTY=0\n',60))
            self.assertEqual(rc,33)
            self.assertIn('diagnostic',(Path(tmp)/'debug.stdout').read_text())
            self.assertTrue((Path(tmp)/'debug.stdout').read_bytes().startswith(b'HEAD=test DIRTY=0\n'))

    def test_undeclared_output_and_timeout_rejected_before_launch(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[2]/'runtime') as tmp:
            scope=runner.Scope(Path(tmp))
            with self.assertRaises(ValueError):scope.open('other')
            with self.assertRaises(ValueError):asyncio.run(runner.run_guest(['does-not-exist'],scope,os.environ.copy(),b'',59))
            self.assertEqual(list(Path(tmp).iterdir()),[])

if __name__=='__main__':unittest.main()
