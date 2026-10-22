"""Actual public TTY payload regression; never launches or queries a VM."""
from pathlib import Path
import importlib.util,json,unittest
p=Path(__file__).parent/'coverage/nt4page_snapshot/installed03/operator_payload.py'
s=importlib.util.spec_from_file_location('own_nt4_public_operator_payload',p);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
class OperatorPayload(unittest.TestCase):
 def test_original_shift_letter_line_rejected_before_write(self):
  special={' ':'spc',':':'shift-semicolon','\\':'backslash','.':'dot','>':'shift-dot','_':'shift-minus'}
  keys=[special.get(c,'shift-'+c.lower() if c.isupper() else c) for c in 'echo NT4_PREPARED_FIRST_LOGON_READY>c:\\usos\\coverage\\armed.txt']+['ret']
  self.assertLessEqual(len(keys),64)
  with self.assertRaises(ValueError):m.bounded_action(keys)
 def test_relative_caps_lock_payload_exact_roundtrip(self):
  special={' ':'spc','.':'dot','>':'shift-dot','_':'shift-minus'}
  keys=['caps_lock']+[special.get(c,c) for c in 'echo nt4_prepared_first_logon_ready>armed.txt']+['ret','caps_lock']
  line=m.bounded_action(keys);self.assertEqual(len(keys),48);self.assertEqual(len(line),284)
  self.assertEqual(json.loads(line),{'keys':keys,'settle':2})
 def test_key_count_control_unicode_and_nonfinite_rejected(self):
  for keys,settle in [(['a']*65,2),(['a\nb'],2),(['ż'],2),(['a'],float('nan')),(['a'],float('inf'))]:
   with self.subTest(keys=keys[:1],settle=settle):
    with self.assertRaises(ValueError):m.bounded_action(keys,settle)
if __name__=='__main__':unittest.main()
