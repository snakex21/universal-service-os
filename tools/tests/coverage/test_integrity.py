"""Regression tests for the coverage media helpers (macOS download helpers live on the macOS DLC branches)."""
from pathlib import Path
from unittest import mock
import importlib.util
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


def module(name):
    spec = importlib.util.spec_from_file_location('coverage_test_'+name,HERE/(name+'.py'))
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


cab = module('unpack_bytes')


class Integrity(unittest.TestCase):
    def test_cab_uses_seekable_input_and_removes_it(self):
        location = Path.cwd()/'artifacts/coverage/tests'
        location.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=location) as folder:
            root = Path(folder)
            def seven(command,**kwargs):
                self.assertNotIn('-si',command)
                self.assertEqual(Path(command[3]).read_bytes(),b'MSCFsynthetic')
                return mock.Mock(returncode=0,stdout=b'MZsynthetic',stderr=b'')
            with mock.patch.object(cab.subprocess,'run',side_effect=seven):
                self.assertEqual(cab.unpack(b'MSCFsynthetic',scratch=root),b'MZsynthetic')
            self.assertEqual(list(root.iterdir()),[])


if __name__ == '__main__': unittest.main()
