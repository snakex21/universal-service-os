"""Regress actual R24 zero-byte redirected own log without weakening bounds."""
from pathlib import Path
import importlib.util,unittest
s=importlib.util.spec_from_file_location('nt31_collect',Path(__file__).with_name('collect_nt31_fullmac.py'))
c=importlib.util.module_from_spec(s);s.loader.exec_module(c)
class FatEntry:
    def __init__(self,size,attr=0):self.size=size;self.attr=attr
    def find(self,path):
        if path!='USOS/NET31/SVC31.LOG':raise AssertionError(path)
        return 0,self.attr,self.size
class OwnLogs(unittest.TestCase):
    def test_policy_is_only_named_presence_and_start(self):
        rows={'p/lanmanworkstation':{'start':(4,b'\x02\0\0\0'),'secret':(1,b'private')},'p/other':{'secret':(1,b'private')}}
        result=c.policy_services(rows,'p/')
        self.assertEqual(result['lanmanworkstation'],dict(present=True,start=2))
        self.assertEqual(result['lanmanserver'],dict(present=False))
        self.assertNotIn('other',result)
        self.assertNotIn('private',str(result))
    def test_real_empty_redirect_shape(self):
        def not_called(*args):raise AssertionError('No cluster reader for empty file')
        self.assertEqual(c.own_log(FatEntry(0),'SVC31.LOG',not_called),b'')
    def test_nonempty_is_still_bounded(self):
        def read(fs,path,bound):
            self.assertEqual((path,bound),('USOS/NET31/SVC31.LOG',65536));return b'193\r\n',[]
        self.assertEqual(c.own_log(FatEntry(5),'SVC31.LOG',read),b'193\r\n')
    def test_directory_or_oversize_refused(self):
        for fs in (FatEntry(0,0x10),FatEntry(65537)):
            with self.assertRaises(ValueError):c.own_log(fs,'SVC31.LOG',None)
    def test_unknown_or_traversal_refused(self):
        for name in ('../SYSTEM','SAM','OTHER.LOG'):
            with self.assertRaises(ValueError):c.own_log(None,name,None)
    def test_nul_refused(self):
        with self.assertRaises(ValueError):c.own_log(FatEntry(1),'SVC31.LOG',lambda *args:(b'\0',[]))
if __name__=='__main__':unittest.main()
