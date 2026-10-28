from pathlib import Path
import asyncio,importlib.util,unittest
HERE=Path(__file__).resolve().parent;s=importlib.util.spec_from_file_location('own_rsp',HERE/'ui_event_rsp.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
class Fake:
 def __init__(self,template=None,cs=3,caller=0x1000456):self.calls=[];self.cs=cs;self.caller=caller;self.template=template
 async def register(self,kind):return {'pc':0x2001000,'sp':0x120000,'cs':self.cs}[kind]
 async def word(self,address,permit):
  if not permit(address):raise ValueError('Boundary')
  self.calls.append(address);values={0x2001000:bytes.fromhex('558bec53'),0x120000:self.caller.to_bytes(4,'little')}
  if self.template is not None:values[0x120008]=self.template.to_bytes(4,'little')
  return values[address]
def policy(template=False):
 return m.WordPolicy([{'address':0x2001000,'api':'DialogBoxParamW' if template else 'MessageBoxW','public_prefix_4':'558bec53','numeric_template_argument_offset':8 if template else None}],[{'module':'OWN_ORACLE','preferred_base':0x1000000,'executable_ranges':[{'start':0x100,'size':0x1000}],'allowlisted_return_sites':[{'return_rva':0x456,'api':'DialogBoxParamW' if template else 'MessageBoxW'}]}])
class StrictEventPolicy(unittest.TestCase):
 def test_messagebox_never_reads_text_or_any_argument_word(self):
  fake=Fake();unused,result=asyncio.run(policy().event(fake));self.assertEqual(fake.calls,[0x2001000,0x120000]);self.assertEqual(result['caller_rva'],'0x456');self.assertNotIn('template_id',result)
 def test_exact_numeric_template_only(self):
  fake=Fake(template=8170);unused,result=asyncio.run(policy(True).event(fake));self.assertEqual(fake.calls,[0x2001000,0x120000,0x120008]);self.assertEqual(result['template_id'],8170)
 def test_named_pointer_is_never_dereferenced_or_exported(self):
  fake=Fake(template=0x12345678);unused,result=asyncio.run(policy(True).event(fake));self.assertEqual(result['template_enum'],'NAMED_OR_POINTER_UNREAD');self.assertNotIn('template_id',result);self.assertNotIn(0x12345678,fake.calls);self.assertNotIn('305419896',str(result))
 def test_range_match_is_explicit_unverified_candidate(self):
  fake=Fake(caller=0x1000457);unused,result=asyncio.run(policy().event(fake));self.assertEqual(result['caller_enum'],'CANDIDATE_UNVERIFIED_CALLSITE');self.assertEqual(result['caller_rva'],'0x457')
 def test_kernel_mode_is_rejected_before_stack_read(self):
  fake=Fake(cs=0)
  with self.assertRaises(ValueError):asyncio.run(policy().event(fake))
  self.assertEqual(fake.calls,[0x2001000])
 def test_arbitrary_rsp_commands_and_bulk_registers_rejected(self):
  client=m.Rsp({0x2001000});client.regs={'rip':(16,64)}
  for command in ('g','m120000,4','m120000,100','M120000,4:00000000','P10=0','p7','Z1,12345678,1'):
   with self.assertRaises(ValueError):client.validate(command)
  client.validate('p10');client.validate('Z1,2001000,1')
 def test_payload_escape_repetition_and_malformed_bounds(self):
  self.assertEqual(m.Rsp.decode_payload(b'A* '+bytes((125,3))),b'AAAA#')
  for data in (b'* ',b'A*',b'A*\x01',b'A}'):
   with self.assertRaises(ValueError):m.Rsp.decode_payload(data)
 def test_packet_checksum_and_truncation_fail_closed(self):
  class Writer:
   def write(self,data):pass
   async def drain(self):pass
  async def run(packet):
   client=m.Rsp(set());client.reader=asyncio.StreamReader();client.writer=Writer();client.reader.feed_data(packet);client.reader.feed_eof();return await client.receive()
  self.assertEqual(asyncio.run(run(b'$OK#9a')),b'OK')
  with self.assertRaises(ValueError):asyncio.run(run(b'$OK#00'))
  with self.assertRaises(asyncio.IncompleteReadError):asyncio.run(run(b'$OK#'))
 def test_outside_exact_executable_range_is_not_exported(self):
  for value in (0x10000ff,0x1001100):
   fake=Fake(caller=value);unused,result=asyncio.run(policy().event(fake));self.assertEqual(result['caller_enum'],'NOT_ALLOWLISTED');self.assertNotIn('caller_rva',result)
if __name__=='__main__':unittest.main(verbosity=2)
