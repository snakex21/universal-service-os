"""Negative cases for the explicit installed08 driver, retaining strict gates."""
from pathlib import Path
import importlib.util,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]
p=ROOT/'tools/tests/coverage/nt4page_snapshot/installed03/network08_policy.py';s=importlib.util.spec_from_file_location('own_policy08_test',p);policy=importlib.util.module_from_spec(s);s.loader.exec_module(policy)
class ExplicitIRQPolicy(unittest.TestCase):
 def setUp(self):
  self.c=policy.collector();self.meta={'private_profile':True,'folder':'Windows NT 4.0','usability_logger_sha256':self.c.LOGGER_SHA256,'observer_kind':'nt4-test-run','observer_token':'USOS_COVERAGE_FIRST_LOGON_'+'a'*32,'nt4_observer_helper_sha256':self.c.OBSERVER_HELPER_SHA256,'nt4_network_evidence':True,'nt4_network_driver_sha256':policy.DRIVER,'nt4_network_driver_bytes':policy.DRIVER_BYTES}
  self.work=Path(r'G:\USOS-Kolekcja\_vm\synthetic-policy08');self.assets=Path(r'G:\USOS-Kolekcja\_assets\synthetic-policy08');self.out=Path(r'C:\Users\ASRock\usos-work\macierz-windows\artifacts\coverage\synthetic-policy08')
 def validate(self,**kwargs):return self.c.validate(self.meta,self.work,self.assets,self.out,Path(r'G:\USOS-Kolekcja'),self.out.parents[2],**kwargs)
 def test_exact_driver_preflights_unknown_and_missing_rejected(self):
  self.validate(preflight=True)
  for key,bad in [('nt4_network_driver_sha256','0'*64),('nt4_network_driver_bytes',21376),('nt4_network_driver_bytes',True)]:
   old=self.meta[key];self.meta[key]=bad
   with self.assertRaises(ValueError):self.validate(preflight=True)
   self.meta[key]=old
  del self.meta['nt4_network_driver_sha256']
  with self.assertRaises(ValueError):self.validate(preflight=True)
 def test_new_driver_does_not_replace_actual_logon(self):
  with self.assertRaisesRegex(ValueError,'Observed actual first logon'):self.validate(first_logon=False)
 def test_actual_guest_command_has_exact_new_size_and_hash(self):
  script=self.c.commands()
  self.assertIn('if [ "$(wc -c </tmp/raw/driver)" -eq 21248 ]; then',script)
  self.assertNotIn('-eq 21376',script)
  self.assertIn('if [ "$digest" = '+policy.DRIVER+' ]; then',script)
  self.assertIn('rm -f /tmp/raw/driver',script)
 def test_driver_pin_does_not_replace_completed_observer(self):
  scratch=ROOT/'artifacts/nt4-network08-policy-tests';scratch.mkdir(parents=True,exist_ok=True)
  with tempfile.TemporaryDirectory(dir=scratch) as directory:
   capture={'policy':'NT4_DHCP_ONLY_AFTER_ACTUAL_FIRST_LOGON','error':None,'first_logon_observed':True,'connected':True,'mac':'52:54:00:55:53:01','netdev':'usabilitynet','analysis':{'dora_observed':True,'exchanges':[{'address':'10.0.2.15','routers':['10.0.2.2'],'dns':['10.0.2.3']}]}}
   result=self.c.correlate({'driver_hash_matches':True,'observer_status':'FIRSTLO_FAILED'},Path(directory),capture)
   self.assertFalse(result['dhcp_pass']);self.assertFalse(result['gateway_pass']);self.assertFalse(result['dns_pass'])
if __name__=='__main__':unittest.main()
