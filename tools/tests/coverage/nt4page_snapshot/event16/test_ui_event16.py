from pathlib import Path
import asyncio,importlib.util,json,unittest
HERE=Path(__file__).resolve().parent
def load(name,file):
 s=importlib.util.spec_from_file_location(name,HERE/file);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
old=load('old_event_test','test_ui_event_policy.py');m=load('new_event_adapter','ui_event_rsp16.py');runner=load('new_event_runner','run_ui_event16.py')
class PersistentPolicy(unittest.TestCase):
 def make(self,caller=0x12340456,duplicate=False,api='MessageBoxW',rva=0x456):
  modules=[{'module':'OWN_ORACLE.DLL','preferred_base':0x1000000,'image_size':0x4000,'executable_ranges':[{'start':0x100,'size':0x1000}],'allowlisted_return_sites':[{'return_rva':rva,'api':api}]}]
  if duplicate:modules.append(dict(modules[0],module='SECOND.DLL'))
  policy=m.WordPolicy([{'address':0x2001000,'api':'MessageBoxW','public_prefix_4':'558bec53','numeric_template_argument_offset':None}],modules)
  fake=old.Fake(caller=caller);unused,public=asyncio.run(policy.event(fake));return policy,fake,public
 def test_unique_low16_is_only_relocated_candidate(self):
  policy,fake,event=self.make();public=policy.relocated_candidate()
  self.assertEqual(public,{'caller_enum':'CANDIDATE_RELOCATED_CALLSITE','ACK_authorized':False,'caller_module':'OWN_ORACLE.DLL','caller_rva':'0x456'})
  self.assertEqual(fake.calls,[0x2001000,0x120000]);self.assertNotIn('12340456',json.dumps(event)+json.dumps(public));self.assertEqual(policy._paused_context['caller'],0x12340456)
 def test_collision_never_selects_first_match(self):
  policy,unused,event=self.make(duplicate=True);public=policy.relocated_candidate();self.assertEqual(public['caller_enum'],'RELOCATED_CALLSITE_NOT_UNIQUE');self.assertNotIn('caller_module',public)
 def test_api_mismatch_or_low16_mismatch_is_not_candidate(self):
  for kwargs in ({'api':'MessageBoxA'},{'caller':0x12340457}):
   policy,unused,event=self.make(**kwargs);self.assertNotIn('caller_module',policy.relocated_candidate())
 def test_relocated_base_must_be_user_aligned_and_image_bounded(self):
  for caller in (0x456,0x80000456):
   policy,unused,event=self.make(caller=caller);self.assertNotIn('caller_module',policy.relocated_candidate())
 def test_site_must_be_in_exact_original_executable_range(self):
  policy,unused,event=self.make(caller=0x12341456,rva=0x1456);self.assertNotIn('caller_module',policy.relocated_candidate())
 def test_context_required(self):
  policy=m.WordPolicy([],[])
  with self.assertRaises(ValueError):policy.relocated_candidate()
 def test_operator_export_rejects_addresses_text_or_ack(self):
  for value in ({'caller':123,'ACK_authorized':False},{'text':'secret','ACK_authorized':False},{'ACK_authorized':True},{'caller_module':'C:\\SECRET.TXT','ACK_authorized':False},{'caller_rva':'not-rva','ACK_authorized':False}):
   with self.assertRaises(ValueError):runner.public_metadata(value)
 def test_operator_exports_only_public_module_rva_candidate(self):
  policy,unused,event=self.make();self.assertEqual(runner.public_metadata(policy.relocated_candidate()),policy.relocated_candidate())
if __name__=='__main__':unittest.main(verbosity=2)
