"""The real operator parser refuses truncation/injection before guest actions."""
from pathlib import Path
import importlib.util,json,unittest
s=importlib.util.spec_from_file_location('nt4_hid_actions',Path(__file__).with_name('coverage')/'boot_nt4_hid.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
class Actions(unittest.TestCase):
 def test_encoded_console_boundary(self):
  line=json.dumps({'keys':['ret']});self.assertEqual(m.parse_action(line+' '*(450-len(line)))['keys'],['ret'])
  with self.assertRaises(ValueError):m.parse_action(line+' '*(451-len(line)))
 def test_guest_input_injection_refused(self):
  for action in ({'keys':['ret;quit']},{'pointer':{'dx':2049}},{'hid':{'device':'target','state':'remove'}},{'finish':True,'keys':['ret']}):
   with self.assertRaises(ValueError):m.parse_action(json.dumps(action))
 def test_replug_keeps_fixed_ports(self):
  self.assertEqual(m.descriptor('keyboard')['port'],'1');self.assertEqual(m.descriptor('mouse')['port'],'2')
if __name__=='__main__':unittest.main()
