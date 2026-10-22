"""Explicit new own pins preserve the actual-logon and completed-test gates."""
from pathlib import Path
import importlib.util,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]
p=ROOT/'tools/tests/coverage/nt4page_snapshot/installed03/network07_policy.py';s=importlib.util.spec_from_file_location('own_policy07_test',p);policy=importlib.util.module_from_spec(s);s.loader.exec_module(policy)
@unittest.skipUnless((policy.MATRIX/'tools/tests/coverage/collect_nt4_success.py').is_file(),'owned original collector snapshot unavailable')
class ExplicitPolicy(unittest.TestCase):
 def setUp(self):
  self.c=policy.collector();self.meta={'private_profile':True,'folder':'Windows NT 4.0','usability_logger_sha256':policy.LOGGER,'observer_kind':'nt4-test-run','observer_token':'USOS_COVERAGE_FIRST_LOGON_'+'a'*32,'nt4_observer_helper_sha256':policy.OBSERVER,'nt4_network_evidence':True}
  self.work=Path(r'G:\USOS-Kolekcja\_vm\synthetic-policy07');self.assets=Path(r'G:\USOS-Kolekcja\_assets\synthetic-policy07');self.out=policy.MATRIX/'artifacts/coverage/synthetic-policy07'
 def validate(self,**kw):return self.c.validate(self.meta,self.work,self.assets,self.out,Path(r'G:\USOS-Kolekcja'),policy.MATRIX,**kw)
 def test_only_exact_new_pair_preflights(self):
  self.validate(preflight=True)
  for key in ('usability_logger_sha256','nt4_observer_helper_sha256'):
   original=self.meta[key];self.meta[key]='0'*64
   with self.assertRaises(ValueError):self.validate(preflight=True)
   self.meta[key]=original
 def test_prepared_target_cannot_replace_actual_logon(self):
  with self.assertRaisesRegex(ValueError,'Observed actual first logon'):self.validate(first_logon=False)
 def test_dora_and_pinned_sys_do_not_override_failed_observer(self):
  scratch=ROOT/'artifacts/nt4-network07-policy-tests';scratch.mkdir(parents=True,exist_ok=True)
  with tempfile.TemporaryDirectory(dir=scratch) as directory:
   capture={'policy':'NT4_DHCP_ONLY_AFTER_ACTUAL_FIRST_LOGON','error':None,'first_logon_observed':True,'connected':True,'mac':'52:54:00:55:53:01','netdev':'usabilitynet','analysis':{'dora_observed':True,'exchanges':[{'address':'10.0.2.15','routers':['10.0.2.2'],'dns':['10.0.2.3']} ]}}
   result=self.c.correlate({'driver_hash_matches':True,'observer_status':'FIRSTLO_FAILED'},Path(directory),capture)
   self.assertFalse(result['dhcp_pass']);self.assertFalse(result['gateway_pass']);self.assertFalse(result['dns_pass'])
if __name__=='__main__':unittest.main()
