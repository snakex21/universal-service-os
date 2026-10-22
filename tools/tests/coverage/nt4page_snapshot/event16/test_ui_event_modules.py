from pathlib import Path
import asyncio,importlib.util,json,unittest
s=importlib.util.spec_from_file_location('own_modules',Path(__file__).with_name('ui_event_modules.py'));m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
class Fake:
 def __init__(self):
  self.regs={'fs_base':(20,64)};self.calls=[];self.memory={0x700018:0x700000,0x700030:0x710000,0x71000c:0x720000,0x720014:0x730008,0x720018:0x730008,0x73000c:0x720014,0x730018:0x1000000,0x730020:0x4000,0x730008:0x720014,0x73002c:28|(32<<16),0x730030:0x740000}
  for offset in range(0,32,4):self.memory[0x740000+offset]=int.from_bytes(('OWN_ORACLE.DLL'+'\0').encode('utf-16le').ljust(32,b'\0')[offset:offset+4],'little')
 async def register(self,kind):assert kind=='fs_base';return 0x700000
 async def word(self,address,permit):
  if not permit(address):raise ValueError('Boundary')
  self.calls.append(address);return self.memory[address].to_bytes(4,'little')
def run(fake,caller=0x1000456):
 manifest={'modules':[{'module':'OWN_ORACLE.DLL','image_size':0x4000,'executable_ranges':[{'start':0x100,'size':0x1000}]}]}
 return asyncio.run(m.inspect(fake,{'caller':caller},manifest))
class LoaderPolicy(unittest.TestCase):
 def test_unique_loaded_mapping_exports_only_public_module_and_rva(self):
  fake=Fake();value=run(fake);self.assertEqual(value['caller_module'],'OWN_ORACLE.DLL');self.assertEqual(value['caller_rva'],'0x456');self.assertFalse(value['ACK_authorized']);self.assertNotIn('1000456',json.dumps(value));self.assertNotIn(0x730024,fake.calls)
 def test_never_reads_full_path_fields(self):
  fake=Fake();run(fake);self.assertNotIn(0x730024,fake.calls);self.assertNotIn(0x730028,fake.calls)
 def test_invalid_teb_self_rejected_before_peb(self):
  fake=Fake();fake.memory[0x700018]=0
  with self.assertRaises(ValueError):run(fake)
  self.assertEqual(fake.calls,[0x700018])
 def test_bad_backlink_rejected(self):
  fake=Fake();fake.memory[0x73000c]=0x730008
  with self.assertRaises(ValueError):run(fake)
 def test_cycle_rejected(self):
  fake=Fake();fake.memory[0x730008]=0x730008
  with self.assertRaises(ValueError):run(fake)
 def test_name_path_or_oversized_length_rejected(self):
  for length in (1,130,0x1000):
   fake=Fake();fake.memory[0x73002c]=length|(132<<16)
   with self.assertRaises(ValueError):run(fake)
 def test_unmatched_caller_does_not_read_any_module_name(self):
  fake=Fake();value=run(fake,0x2000000);self.assertNotIn('caller_module',value);self.assertNotIn(0x73002c,fake.calls)
 def test_caller_outside_exact_original_executable_section_not_exported(self):
  fake=Fake();value=run(fake,0x1002000);self.assertNotIn('caller_module',value)
if __name__=='__main__':unittest.main(verbosity=2)
