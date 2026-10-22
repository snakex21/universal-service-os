"""Regression for exact completed R17 echo fragments; no permissive decoder."""
from pathlib import Path
import importlib.util,hashlib,unittest
ROOT=Path(__file__).resolve().parents[2]
s=importlib.util.spec_from_file_location('r17_history',ROOT/'tools/tests/recover_nt3_r17_transport.py');r=importlib.util.module_from_spec(s);s.loader.exec_module(r)
class HistoricalFrame(unittest.TestCase):
 def test_real_fragment_shapes_preserve_all_76_payload_characters(self):
  payload='R3+88MH9vH+0woWwjT/iYMLYUhxUKOYL3sdNeXH7Je2ifDHbdP3VeMHbdNub+/rRD+4L3vVj9KL1'
  self.assertEqual(len(payload),76)
  for _,(kind,part) in r.PATCHES.items():
   line=part if kind=='line' else payload+part if kind=='suffix' else part+payload
   self.assertEqual(r.strip_observed(line,kind,part),'' if kind=='line' else payload)
 def test_unknown_extra_or_missing_characters_are_refused(self):
  for kind,part in r.PATCHES.values():
   line=part if kind=='line' else 'A'*76+part if kind=='suffix' else part+'A'*76
   for bad in (line+'X',line[:-1]):
    with self.assertRaises(ValueError):r.strip_observed(bad,kind,part)
 def test_whole_historical_hash_is_mandatory(self):
  for raw in (b'',b'COVERAGE_EVIDENCE_BEGIN\nAAAA\nCOVERAGE_EVIDENCE_END\n'):
   with self.assertRaisesRegex(ValueError,'exact completed historical'):r.recover(raw)
 @unittest.skipUnless(r.SERIAL.is_file(),'Original completed historical transport is local-only')
 def test_actual_completed_transport_recovers_pinned_complete_payload(self):
  payload=r.recover(r.SERIAL.read_bytes())
  self.assertEqual(len(payload),57362);self.assertEqual(hashlib.sha256(payload).hexdigest(),r.PAYLOAD_SHA)
if __name__=='__main__':unittest.main()
