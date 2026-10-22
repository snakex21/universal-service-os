"""The real staging path policy accepts original ISO empty extensions only."""
import importlib.util
from pathlib import Path
import unittest
s=importlib.util.spec_from_file_location('nt31_prepare',Path(__file__).with_name('prepare_nt31_fullmac.py'))
p=importlib.util.module_from_spec(s);s.loader.exec_module(p)
class SourcePolicy(unittest.TestCase):
    def test_actual_nt31_command_compatibility(self):
        text=p.native_commands()
        self.assertNotIn(b'IPCONFIG',text.upper())
        self.assertNotIn(b'/WAIT',text.upper())
        self.assertNotIn(b' -w ',text)
        self.assertIn(b'ping -n 3 10.0.2.2',text)
        self.assertIn(b'cd \\USOS\\NET31',text)
        self.assertIn(b'NATIVE_COMMANDS_ISSUED',text)
    def test_original_empty_extensions(self):
        self.assertEqual(p.source_path('i386/disk1.'),'N31SRC/DISK1')
        self.assertEqual(p.source_path('i386/setupldr.'),'N31SRC/SETUPLDR')
    def test_original_compressed_name(self):
        self.assertEqual(p.source_path('i386/oemnadlb.in_'),'N31SRC/OEMNADLB.IN_')
    def test_no_arbitrary_renaming(self):
        for name in ('i386/not-short-name.inf','i386/file.long','i386/../file','i386/foo..','amd64/file.sys','i386/a/b/c/d/e'):
            with self.subTest(name=name),self.assertRaises(ValueError):p.source_path(name)
if __name__=='__main__':unittest.main()
