from pathlib import Path
import asyncio,importlib.util,unittest
s=importlib.util.spec_from_file_location('own_tcpframe',Path(__file__).with_name('ui_event_modules.py'));m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
class Fake:
 def __init__(self,rva,delta=0x24):self.rva=rva;self.delta=delta;self.calls=[]
 async def register(self,kind):self.calls.append(kind);assert kind=='fp';return 0x120000+self.delta
 async def word(self,address,permit):
  assert address==0x120028 and permit(address);self.calls.append(address);return (0x74000000+self.rva).to_bytes(4,'little')
class ExactTcpFrame(unittest.TestCase):
 def test_each_exact_return_site_maps_only_public_resource_id(self):
  for rva,expected in ((0x117e8,0x62ce),(0x11862,0x62d0),(0x1196a,0x62d1)):
   fake=Fake(rva);result=asyncio.run(m.tcp_resource(fake,{'stack':0x120000},0x74000000));self.assertEqual(result,{'resource_enum':'EXACT_ORIGINAL_TCPCFG_STR','resource_id':expected});self.assertEqual(fake.calls,['fp',0x120028])
 def test_wrong_frame_delta_rejected_before_memory(self):
  fake=Fake(0x117e8,0x28)
  with self.assertRaises(ValueError):asyncio.run(m.tcp_resource(fake,{'stack':0x120000},0x74000000))
  self.assertEqual(fake.calls,['fp'])
 def test_neighbour_return_site_never_matched(self):
  fake=Fake(0x117e9);result=asyncio.run(m.tcp_resource(fake,{'stack':0x120000},0x74000000));self.assertNotIn('resource_id',result)
if __name__=='__main__':unittest.main(verbosity=2)
