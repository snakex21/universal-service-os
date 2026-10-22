"""Combined operator rejects device/transport injection before host mutations."""
from pathlib import Path
import importlib.util,json,unittest
s=importlib.util.spec_from_file_location('nt4_combo_actions',Path(__file__).with_name('coverage')/'boot_nt4_combo.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
class Actions(unittest.TestCase):
 def test_mutually_exclusive_device_and_stage_actions(self):
  for a in ({'hid':{'device':'target','state':'remove'}},{'usb':'format'},{'usb':'insert','hid':{'device':'mouse','state':'remove'}},{'expect_msc':'HOT','pointer':{'dx':1},'keys':['ret']},{'keys':['ret;quit']},{'finish':True,'hid':{'device':'keyboard','state':'remove'}}):
   with self.assertRaises(ValueError):m.parse_action(json.dumps(a))
 def test_console_limit_and_negative_control_supported(self):
  a={'hid':{'device':'keyboard','state':'remove'},'keys':['a','b']};line=json.dumps(a)
  self.assertEqual(m.parse_action(line+' '*(450-len(line))),a)
  with self.assertRaises(ValueError):m.parse_action(line+' '*(451-len(line)))
if __name__=='__main__':unittest.main()
