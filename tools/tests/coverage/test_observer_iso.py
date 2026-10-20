"""The scripts CD must expose the exact existing user_script path on Windows."""
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
import pycdlib

spec=importlib.util.spec_from_file_location('fixture',Path(__file__).with_name('prepare_stick.py'))
fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)


class ObserverIsoTests(unittest.TestCase):
    def test_joliet_script_path_and_marker(self):
        scratch=Path(__file__).resolve().parents[3]/'artifacts/coverage/observer-test'
        scratch.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            path=Path(directory)/'observer.iso';token='USOS_COVERAGE_FIRST_LOGON_'+'0'*32
            fixture.make_observer_iso(path,token)
            cd=pycdlib.PyCdlib();cd.open(str(path))
            try:
                cd.get_record(joliet_path='/Systems')
                stream=io.BytesIO();cd.get_file_from_iso_fp(stream,joliet_path='/Scripts/first-logon.cmd')
            finally:cd.close()
            self.assertIn((token+'>COM1').encode(),stream.getvalue())
            self.assertNotIn(b'ProductKey',stream.getvalue())


if __name__=='__main__':unittest.main()
