"""A diagnostic registry section must preserve the profile's real AddReg list."""
from pathlib import Path
import importlib.util
import subprocess
import unittest

spec=importlib.util.spec_from_file_location('fixture',Path(__file__).with_name('prepare_stick.py'))
fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)
AWK=Path(r'C:\Program Files\Git\usr\bin\awk.exe')


@unittest.skipUnless(AWK.exists(),'POSIX awk from Git for Windows is not installed')
class LegacyObserverTests(unittest.TestCase):
    def test_keeps_install_answers_and_addreg(self):
        source=b'[Setup]\r\nTimeZone=Greenwich\r\n[Install]\r\nAddReg=USOS.RunOnce,USOS.CsmReg\r\n[USOS.CsmReg]\r\n'
        result=subprocess.run([str(AWK),fixture.LEGACY_OBSERVER_AWK],input=source,capture_output=True,check=True).stdout
        self.assertIn(b'AddReg=USOS.RunOnce,USOS.CsmReg,USOS.Coverage\r\n',result)
        self.assertIn(b'TimeZone=Greenwich\r\n',result)
        self.assertIn(b'command.com /c C:\\USOS9X\\COVOBS.BAT',result)
        token='USOS_COVERAGE_FIRST_LOGON_'+'0'*32
        self.assertIn(token.encode(),fixture.trace_overlay(token))

    def test_rejects_unexpected_source_instead_of_replacing_answers(self):
        run=subprocess.run([str(AWK),fixture.LEGACY_OBSERVER_AWK],input=b'[Setup]\n',capture_output=True)
        self.assertNotEqual(run.returncode,0)


if __name__=='__main__':unittest.main()
