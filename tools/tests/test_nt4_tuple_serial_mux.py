"""Execute the actual archived class definitions, without importing a VM runner."""
import ast,asyncio,re,unittest
from pathlib import Path
SNAPSHOT=Path(__file__).parent/'coverage/nt4page_snapshot/installed03/tuple09'
def actual_class(filename,name):
 path=SNAPSHOT/filename;tree=ast.parse(path.read_text(encoding='utf-8'))
 nodes=[n for n in tree.body if isinstance(n,ast.ClassDef) and n.name==name]
 if len(nodes)!=1:raise ValueError('One exact archived runtime class required')
 namespace={'asyncio':asyncio,'re':re}
 exec(compile(ast.Module(body=nodes,type_ignores=[]),str(path),'exec'),namespace)
 return namespace[name]
class ActualTupleSerial(unittest.IsolatedAsyncioTestCase):
 def setUp(self):
  self.c=actual_class('reused-msc-runtime-source.py','Completions')()
  self.token='USOS_COVERAGE_FIRST_LOGON_'+'a'*32;self.seen=[]
  self.mux=actual_class('runtime-source.py','TokenMux')(self.c,self.token,lambda:self.seen.append(True))
 async def test_actual_net_boundary_is_exact_and_one_shot(self):
  for line in (b'prefix'+self.token.encode(),self.token.encode()+b' suffix',b'x'*129):self.mux.line(line)
  self.assertEqual(self.seen,[])
  self.mux.line(self.token.encode()+b'\r');self.mux.line(self.token.encode())
  self.assertEqual(self.seen,[True])
 async def test_net_token_cannot_complete_armed_msc_operation(self):
  future=self.c.arm('STARTUP');self.mux.line(self.token.encode())
  self.assertFalse(future.done());self.assertEqual(self.seen,[True])
  self.mux.line(b'USOS_MSC4_DONE=STARTUP:0\r')
  self.assertEqual(await future,0)
 async def test_unarmed_and_duplicate_msc_completion_still_fail_closed(self):
  with self.assertRaises(RuntimeError):self.mux.line(b'USOS_MSC4_DONE=HOT:0\r')
  future=self.c.arm('HOT');self.mux.line(b'USOS_MSC4_DONE=HOT:0\r');self.assertEqual(await future,0)
  with self.assertRaises(RuntimeError):self.mux.line(b'USOS_MSC4_DONE=HOT:0\r')
  self.assertEqual(self.seen,[])
if __name__=='__main__':unittest.main()
