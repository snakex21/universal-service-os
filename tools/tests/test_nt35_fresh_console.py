import importlib.util,subprocess,sys,unittest
from pathlib import Path
P=Path(__file__).with_name('start_nt35_irq_fresh.py')
class Console(unittest.TestCase):
 def test_pipe_and_nul_refuse_before_vm(self):
  for mode in ('pipe','nul'):
   with self.subTest(mode=mode):
    kw={'input':b''} if mode=='pipe' else {'stdin':subprocess.DEVNULL}
    r=subprocess.run([sys.executable,'-B',str(P)],capture_output=True,timeout=10,**kw)
    self.assertNotEqual(r.returncode,0)
    self.assertIn(b'Live Windows operator console required',r.stderr)
if __name__=='__main__':unittest.main()
