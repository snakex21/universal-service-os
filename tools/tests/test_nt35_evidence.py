"""Scoped NT35 evidence archive/transport/policy tests; never starts a VM."""
from pathlib import Path
from types import SimpleNamespace
import base64,gzip,hashlib,importlib.util,io,json,subprocess,tarfile,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('nt35_collect',ROOT/'tools/tests/coverage/collect_nt35_success.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
def archive(records):
 out=io.BytesIO()
 with tarfile.open(fileobj=out,mode='w:gz') as t:
  for name,data in records:
   info=tarfile.TarInfo('./'+name);info.size=len(data);t.addfile(info,io.BytesIO(data))
 return out.getvalue()
class NT35Evidence(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  parent=ROOT/'artifacts/coverage/nt35-evidence-tests';parent.mkdir(parents=True,exist_ok=True)
  cls.review_tmp=tempfile.TemporaryDirectory(prefix='runner-',dir=parent);directory=Path(cls.review_tmp.name)
  subprocess.run(['git','init','-q',str(directory)],check=True,capture_output=True)
  for name in ('boot_menu.py','run_plan.py'):
   rel='tools/tests/coverage/'+name;dst=directory/rel;dst.parent.mkdir(parents=True,exist_ok=True)
   dst.write_bytes(subprocess.check_output(['git','show','015ddddfe328b44066768d12fb2840171689e33c:'+rel],cwd=ROOT))
  subprocess.run(['git','apply',str(ROOT/'tools/tests/coverage/nt35-runner-015ddddf.patch')],cwd=directory,check=True,capture_output=True)
  cls.review=(directory/'tools/tests/coverage/boot_menu.py').read_text(encoding='utf-8')
 @classmethod
 def tearDownClass(cls):cls.review_tmp.cleanup()
 def setUp(self):
  parent=ROOT/'artifacts/coverage/nt35-evidence-tests';parent.mkdir(parents=True,exist_ok=True)
  self.tmp=tempfile.TemporaryDirectory(dir=parent);self.addCleanup(self.tmp.cleanup);self.work=Path(self.tmp.name)
  self.collection=self.work/'collection';self.fixture=self.collection/'_vm/case';self.assets=self.collection/'_assets/frozen'
  self.fixture.mkdir(parents=True);self.assets.mkdir(parents=True);self.output=self.work/'out'
 def test_policy_is_literal_keyless_and_scoped(self):
  for folder in ('Windows NT 3.5','Windows NT 3.5 Server'):
   c.validate({'folder':folder,'private_profile':False},self.fixture,self.assets,ROOT/'artifacts/coverage/test',self.collection,ROOT,False)
  for private in (None,0,'false',True):
   with self.assertRaises(ValueError):c.validate({'folder':'Windows NT 3.5','private_profile':private},self.fixture,self.assets,ROOT/'artifacts/coverage/test',self.collection,ROOT,False)
  for folder in ('Windows NT 3.51','Windows NT 4.0','Windows NT 3.1','Windows NT 3.5 '):
   with self.assertRaises(ValueError):c.validate({'folder':folder,'private_profile':False},self.fixture,self.assets,ROOT/'artifacts/coverage/test',self.collection,ROOT,False)
 def test_paths_and_absent_stopped_target_fail_closed(self):
  meta={'folder':'Windows NT 3.5','private_profile':False}
  with self.assertRaises(FileNotFoundError):c.validate(meta,self.fixture,self.assets,ROOT/'artifacts/coverage/test',self.collection,ROOT)
  with self.assertRaises(ValueError):c.validate(meta,self.work,self.assets,ROOT/'artifacts/coverage/test',self.collection,ROOT,False)
  with self.assertRaises(ValueError):c.validate(meta,self.fixture,self.assets,ROOT/'docs',self.collection,ROOT,False)
 def test_valid_archive_hash_is_preparation_only(self):
  data=archive([(n,b'own evidence\n') for n in c.FILES]+[('DRIVER-READBACK.SHA256',(c.DRIVER_SHA256+'\n').encode())])
  framed='NT35_OWN_EVIDENCE_BEGIN\n'+base64.b64encode(data).decode()+'\nNT35_OWN_EVIDENCE_END\n'
  got=c.export_evidence(c.decode_transport(framed),self.output)
  self.assertEqual(got['missing'],[]);self.assertTrue(got['driver_hash_matches']);self.assertFalse(got['installed_runtime_pass'])
 def test_unexpected_or_duplicate_system_data_never_written(self):
  for records in ([('SYSTEM',b'not allowed')],[('../POST.LOG',b'not allowed')],[('POST.LOG',b'a'),('POST.LOG',b'b')],[('POST.LOG',b'\0binary')]):
   with self.assertRaises(ValueError):c.export_evidence(archive(records),self.output)
   self.assertFalse(self.output.exists())
 def test_transport_is_strict_and_quoted_before_output(self):
  for text in ('NT35_OWN_EVIDENCE_BEGIN\nAAAA!\nNT35_OWN_EVIDENCE_END','NT35_OWN_EVIDENCE_BEGIN\nAA==\nNT35_OWN_EVIDENCE_BEGIN\nNT35_OWN_EVIDENCE_END'):
   with self.assertRaises(ValueError):c.decode_transport(text)
  script=c.serial_shell.wrap(c.commands());self.assertTrue(script.startswith("exec /bin/sh <<'USOS_COLLECTOR_"));self.assertIn('NT35_OWN_EVIDENCE_BEGIN',script)
  self.assertIn('usosnet35.sys',script);self.assertNotIn('usosnet351.sys',script);self.assertNotIn('/CONFIG/SYSTEM',script)
 def test_pinned_hash_matches_actual_candidate(self):
  binary=(ROOT/'tools/nt/usosnet/bin/i386/usosnet35.sys').read_bytes()
  self.assertEqual(len(binary),c.DRIVER_BYTES);self.assertEqual(hashlib.sha256(binary).hexdigest(),c.DRIVER_SHA256)
 def test_actual_runner_preflight_rejects_wrong_capture_policy(self):
  source=self.review
  a=source.index("    collect_nt351=getattr");b=source.index("    if metadata['result']['result']",a)
  ns={'Path':Path,'__file__':str(ROOT/'tools/tests/coverage/boot_menu.py'),'fixture':SimpleNamespace(COLLECTION=self.collection),'nt35_own':c}
  exec('def check(args,metadata,work):\n'+source[a:b],ns)
  def args(**kw):
   values=dict(collect_nt35_success=True,capture_nt35_network=True,nic='igb',evidence_assets=self.assets,out=ROOT/'artifacts/coverage/test');values.update(kw);return SimpleNamespace(**values)
  ns['check'](args(),{'folder':'Windows NT 3.5','private_profile':False},self.fixture)
  for kw in ({'collect_nt35_success':False},{'nic':'e1000'},{'collect_nt4_success':True},{'capture_nt351_network':True}):
   with self.assertRaises(ValueError):ns['check'](args(**kw),{'folder':'Windows NT 3.5','private_profile':False},self.fixture)
  with self.assertRaises(ValueError):ns['check'](args(),{'folder':'Windows NT 3.51','private_profile':False},self.fixture)
 def test_runner_collection_precedes_image_cleanup(self):
  source=self.review
  self.assertIn('if capture_nt351 or capture_nt35 or capture_nt4:',source)
  self.assertLess(source.index('await nt35_own.main'),source.rindex('.unlink('))
  self.assertIn('readonly=on',(ROOT/'tools/tests/coverage/collect_nt35_success.py').read_text(encoding='utf-8'))
if __name__=='__main__':unittest.main()
