"""Synthetic host tests only: native plan, shell staging and flow wiring."""
from pathlib import Path
import hashlib,importlib.util,os,shutil,struct,subprocess,sys,tempfile,unittest,zipfile
ROOT=Path(__file__).resolve().parents[3]
sys.path[:0]=[str(ROOT/'tools'),str(ROOT/'tools/addons')]
sys.path.insert(0,str(ROOT/'tools/tests'))
import depguard
import legacy_manifest as lm
import prepare_legacy_user_files as prepare_user
from build_legacy_stage import build
OUT=ROOT/'artifacts/legacy-pack/flow-tests';OUT.mkdir(parents=True,exist_ok=True)
tempfile.tempdir=str(OUT)
SH=shutil.which('sh') or r'C:\Program Files\Git\usr\bin\sh.exe'
ENV=dict(os.environ,PATH=str(Path(SH).parent)+os.pathsep+os.environ.get('PATH',''))
def q(p):return "'"+str(p).replace('\\','/')+"'"
def shell(code):return subprocess.run([SH,'-c','. '+q(ROOT/'tools/legacy_addons.sh')+'; '+code],env=ENV,cwd=ROOT,capture_output=True)

class Policy(unittest.TestCase):
 def test_public_manifest_urls_rejected_in_every_field_and_comments(self):
  with tempfile.TemporaryDirectory() as d:
   p=Path(d)/'manifest.ini';base=lm.MANIFEST.read_text()
   for value in ('future_field=https://example.invalid/pkg','note=http://example.invalid/pkg','; https://example.invalid/pkg'):
    p.write_text(base+'\n'+value+'\n');self.assertTrue(any('HTTP' in e for e in lm.validate(lm.Manifest.load(p))))
   p.write_text(base+'\nfuture_field=opaque-data\n');self.assertEqual(lm.validate(lm.Manifest.load(p)),[])
 def test_release_classes_and_missing_source_are_explicit(self):
  m=lm.Manifest.load()
  for p in m.packages:
   if p.id.startswith(('ie5','ie6','dcom','dun','wmp','nt4-sp6a-','nt4-srp-')) and p.id!='wmp9-classic-skin':self.assertEqual(p.get('source'),'release',p.id)
   if p.id.startswith(('nt4-sp6a-','nt4-srp-')) or p.id in ('ie55sp2-pl','ie6sp1-pl-9x','ie6sp1-pl-nt4','ie6sp1-en-9x','ie6sp1-en-nt4'):self.assertEqual(p.get('redist'),'no',p.id)
  skin=m.find('wmp9-classic-skin');self.assertEqual((skin.get('source'),skin.get('redist')),('user','unknown'))
  p=m.find('kernelex');self.assertEqual((p.get('source'),p.get('status'),p.tier),('bundled','missing','option'))
  self.assertEqual(m.find('speechsdk51-langpack').get('status'),'missing')
 def test_nt4_sp6a_is_not_planned_twice(self):
  m=lm.Manifest.load()
  for lang in ('PL','EN'):
   self.assertFalse(any(x.startswith('nt4-sp6a') for x in lm.resolve(m,'NT4',lang,'6a',True).order))
 def test_runtime_defers_vm_and_reuses_lan_component(self):
  s=(ROOT/'src/platform/win32_legacy/usosadd/main.c').read_text()
  entry=s.split('void __cdecl ua_start(void)',1)[1]
  self.assertLess(entry.index('if (ua_ieq(g_sys.os,"NT4") && virtual_machine())'),entry.index('run_chain();'))
  self.assertIn('lan_defaults(0);',s);self.assertIn('lan_defaults(1);',s)
  self.assertIn('C:\\\\USOS9X\\\\LOGS',s);self.assertIn('C:\\\\USOS\\\\NT4',s)
  self.assertNotIn('Sleep(5000)',s)
  self.assertIn('usos_wait_desktop(addons_desktop_ready,300000)',s)
  self.assertIn('" /refresh"',s)

class Stage(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  depguard.require_zig('kompilator Zig (build_legacy_stage)')
  cls.exe=build(ROOT,(OUT/'native').resolve(),host=True)
  cls.linux=build(ROOT,(OUT/'linux').resolve())
 def setUp(self):
  self.root=Path(tempfile.mkdtemp(prefix='stage-'));self.addCleanup(shutil.rmtree,self.root)
  self.lib=self.root/'lib';(self.lib/'addons').mkdir(parents=True)
  self.target=self.root/'C';self.data=self.root/'DATA';self.data.mkdir()
  shutil.copyfile(self.exe,self.lib/'addons/legacy-stage-plan')
  (self.lib/'addons/USOSADD.EXE').write_bytes(b'own runner fixture')
  self.cfg=self.root/'config';self.cfg.write_text('preset=praca\noptions=\nexclude=\ndialup=off\n')
  self.manifest='''[pack]
format=1
os=95OSR2,95OSR21,95OSR25,98FE,98SE,ME,NT4
group_9X=95OSR2,95OSR21,95OSR25,98FE,98SE,ME
[presets]
default=praca
[preset:praca]
full=1
[preset:none]
full=0
[pkg:demo]
dir=DEMO
os=9X,NT4
lang=*
tier=full
order=1
file1=SETUP.EXE|demo.bin|HASH|SIZE
'''
  self.blob=b'own synthetic executable stand-in'
  self.hash=hashlib.sha256(self.blob).hexdigest()
  self.write_manifest()
 def write_manifest(self,text=None):
  text=(text or self.manifest).replace('HASH',self.hash).replace('SIZE',str(len(self.blob)))
  for lang in ('PL','EN'):(self.lib/'addons'/('LEGACY.'+lang)).write_bytes(text.replace('\n','\r\n').encode('ascii'))
 def stage(self,os_id='98SE',lang='PL',sp=''):
  return shell('usos_addons_stage '+' '.join(map(q,(self.cfg,self.target,self.lib,self.data,os_id,lang,sp))))
 def test_native_linux_is_static_elf(self):
  self.assertEqual(self.linux.read_bytes()[:4],b'\x7fELF')
  # No dynamic interpreter segment on the Linux initramfs build.
  data=self.linux.read_bytes();phoff=struct.unpack_from('<Q',data,32)[0];size,num=struct.unpack_from('<HH',data,54)
  self.assertNotIn(3,[struct.unpack_from('<I',data,phoff+i*size)[0] for i in range(num)])
 def test_host_user_export_is_flat_pinned_and_does_not_change_inputs(self):
  source=self.root/'own-source.zip'
  with zipfile.ZipFile(source,'w') as z:z.writestr('app/upd_c/odd.exe',self.blob)
  before=source.read_bytes()
  text=self.manifest.replace('demo.bin','WinSPatcher_own.exe!app/upd_c/odd.exe').replace('tier=full','tier=full\nsource=user')
  text=text.replace('HASH',self.hash).replace('SIZE',str(len(self.blob)))
  mpath=self.root/'own.ini';mpath.write_text(text);m=lm.Manifest.load(mpath)
  result=prepare_user.prepare(m,[source],self.root/'prepared')
  self.assertEqual((result['prepared'],result['missing']),(1,0))
  self.assertEqual((self.root/'prepared/USOS/WSP/DEMO/SETUP.EXE').read_bytes(),self.blob)
  self.assertEqual(source.read_bytes(),before);self.assertEqual(mpath.read_text(),text)
  self.assertFalse((self.root/'prepared/.work').exists())
  with self.assertRaises(ValueError):prepare_user.prepare(m,[source],self.root/'prepared')
  with self.assertRaises(ValueError):prepare_user.prepare(m,[self.root],self.root/'nested-target')
 def test_zip32_sfx_offsets_and_malformed_directory(self):
  import io
  for adjusted in (False,True):
   prefix=b'MZ own SFX stub'*19;stream=io.BytesIO(prefix if adjusted else b'')
   if adjusted:stream.seek(0,2)
   with zipfile.ZipFile(stream,'w') as z:z.writestr('ROOT/FILE.DAT',self.blob)
   source=self.root/'sfx.exe';source.write_bytes(stream.getvalue() if adjusted else prefix+stream.getvalue())
   before=source.read_bytes();dest=self.root/'fixed.zip'
   r=subprocess.run([str(self.exe),'prepare-zip',str(source),str(dest)],capture_output=True)
   self.assertEqual(r.returncode,0,r.stderr)
   with zipfile.ZipFile(dest) as z:self.assertEqual(z.read('ROOT/FILE.DAT'),self.blob)
   self.assertEqual(source.read_bytes(),before)
   for offset,fmt,value in ((12,'<I',0x7fffffff),(16,'<I',0xffffffff),(4,'<H',1),(10,'<H',65535)):
    broken=bytearray(before);pos=broken.rfind(b'PK\x05\x06');struct.pack_into(fmt,broken,pos+offset,value);source.write_bytes(broken)
    self.assertNotEqual(subprocess.run([str(self.exe),'prepare-zip',str(source),str(self.root/'bad.zip')]).returncode,0)
 def test_iso_root_reader_and_bad_extents(self):
  image=bytearray(24*2048);pvd=16*2048;image[pvd:pvd+7]=b'\x01CD001\x01'
  def record(lba,size,name,flags=0):
   n=33+len(name);n+=(n%2);r=bytearray(n);r[0]=n;r[25]=flags;r[32]=len(name);r[33:33+len(name)]=name
   struct.pack_into('<I',r,2,lba);struct.pack_into('<I',r,10,size);return r
  root=record(20,2048,b'\0',2);image[pvd+156:pvd+156+len(root)]=root
  a=record(21,len(self.blob),b'SETUP.EXE;1');b=record(999999,10,b'BAD.EXE;1')
  image[20*2048:20*2048+len(a+b)]=a+b;image[21*2048:21*2048+len(self.blob)]=self.blob
  iso=self.root/'own.iso';iso.write_bytes(image);dest=self.root/'iso-out'
  r=subprocess.run([str(self.exe),'unpack-iso',str(iso),str(dest)],capture_output=True)
  self.assertEqual(r.returncode,0,r.stderr);self.assertEqual((dest/'SETUP.EXE').read_bytes(),self.blob);self.assertFalse((dest/'BAD.EXE').exists())
 def test_flat_size_sha_match_and_readback(self):
  (self.data/'arbitrary-name').write_bytes(self.blob);r=self.stage();self.assertEqual(r.returncode,0,r.stderr)
  app=self.target/'USOS/ADDONS';self.assertEqual((app/'PKG/DEMO/SETUP.EXE').read_bytes(),self.blob)
  self.assertIn('staged demo/SETUP.EXE',(self.target/'USOS9X/LOGS/ADDONS.LOG').read_text())
  self.assertFalse(list((app/'TMP').iterdir()))
 def test_staged_package_keeps_runner_and_registration(self):
  (self.data/'demo.bin').write_bytes(self.blob);r=self.stage();self.assertEqual(r.returncode,0,r.stderr)
  app=self.target/'USOS/ADDONS';self.assertTrue((app/'USOSADD.EXE').is_file());self.assertTrue((app/'ADDONS.REG').is_file())
 def test_nothing_staged_removes_runner_no_empty_installer_window(self):
  # X470 Me 2026-10-20: empty DATA\Addons showed an "installed 0/10" box.
  r=self.stage();self.assertEqual(r.returncode,0,r.stderr)
  app=self.target/'USOS/ADDONS';self.assertFalse((app/'USOSADD.EXE').exists());self.assertFalse((app/'ADDONS.REG').exists())
  log=(self.target/'USOS9X/LOGS/ADDONS.LOG').read_text()
  self.assertIn('no package staged; runner not registered',log);self.assertIn('staging complete files=0 missing=1',log)
 def test_wrong_hash_and_absence_do_not_stop_setup(self):
  (self.data/'demo.bin').write_bytes(b'X'*len(self.blob));r=self.stage();self.assertEqual(r.returncode,0,r.stderr)
  self.assertIn(b'missing demo/SETUP.EXE',r.stdout);self.assertFalse((self.target/'USOS/ADDONS/PKG/DEMO/SETUP.EXE').exists())
 def test_unsupported_container_is_missing_and_setup_continues(self):
  (self.data/'broken.zip').write_bytes(self.blob);self.write_manifest(self.manifest+'unpack=zip\n')
  r=self.stage();self.assertEqual(r.returncode,0,r.stderr);self.assertIn(b'unsupported ZIP',r.stdout)
  self.assertFalse((self.target/'USOS/ADDONS/PKG/DEMO/SETUP.EXE').exists())
 def test_nested_zip_input_found_by_digest(self):
  nested=self.root/'nested.zip'
  with zipfile.ZipFile(nested,'w') as z:z.writestr('arbitrary.bin',self.blob)
  with zipfile.ZipFile(self.data/'user.zip','w') as z:z.writestr('nested.zip',nested.read_bytes())
  r=self.stage();self.assertEqual(r.returncode,0,r.stderr);self.assertIn(b'staged demo/SETUP.EXE',r.stdout)
 def test_zip_unpack_strips_root_and_rejects_unsafe_names(self):
  file=self.data/'source.zip'
  expected=self.blob
  with zipfile.ZipFile(file,'w') as z:z.writestr('root/SETUP.EXE',self.blob);z.writestr('root/../ESCAPE.EXE',b'bad')
  self.blob=file.read_bytes();self.hash=hashlib.sha256(self.blob).hexdigest()
  self.write_manifest(self.manifest+'unpack=zip\n')
  r=self.stage();self.assertEqual(r.returncode,0,r.stderr)
  self.assertEqual((self.target/'USOS/ADDONS/PKG/DEMO/SETUP.EXE').read_bytes(),expected);self.assertFalse(list(self.target.rglob('ESCAPE.EXE')))
 def test_none_keeps_target_absent_and_bad_selection_rejected(self):
  self.cfg.write_text('preset=none\noptions=\nexclude=\ndialup=off\n');self.assertEqual(self.stage().returncode,0);self.assertFalse(self.target.exists())
  self.cfg.write_text('preset=praca\noptions=a&cmd\nexclude=\ndialup=off\n');self.assertNotEqual(self.stage().returncode,0);self.assertFalse(self.target.exists())
 def test_language_and_system_matrix_use_real_same_resolver(self):
  for os_id in ('95','98FE','98SE','ME','NT4'):
   for lang in ('PL','EN','XX'):
    r=self.stage(os_id,lang,'6a' if os_id=='NT4' else '');self.assertEqual(r.returncode,0,(os_id,lang,r.stderr))
    self.assertIn('lang='+lang,(self.target/'USOS/ADDONS/SELECT.INI').read_text())
 def test_nt4_without_external_sp_stages_sp6a_and_post_sp_members(self):
  text=(ROOT/'src/addons/legacy-pack.ini').read_text(encoding='utf-8')
  for lang in ('PL','EN'):(self.lib/'addons'/('LEGACY.'+lang)).write_bytes(text.encode('cp1250' if lang=='PL' else 'cp1252',errors='replace'))
  r=self.stage('NT4','PL','');self.assertEqual(r.returncode,0,r.stderr)
  plan=(self.target/'USOS/ADDONS/PLAN.TXT').read_text();self.assertIn('file|nt4-sp6a-pl|',plan);self.assertIn('file|hfnt',plan)
  r=self.stage('NT4','PL','6a');self.assertEqual(r.returncode,0,r.stderr)
  self.assertNotIn('file|nt4-sp6a-',(self.target/'USOS/ADDONS/PLAN.TXT').read_text())
 def test_dun_exclusion_and_me_always_off(self):
  self.write_manifest(self.manifest+'\n[pkg:dun-test]\ndir=DUN\nos=9X\nlang=*\ntier=full\norder=2\n')
  self.assertEqual(self.stage().returncode,0);self.assertIn('exclude=dun-test',(self.target/'USOS/ADDONS/SELECT.INI').read_text())
  self.cfg.write_text('preset=praca\noptions=\nexclude=\ndialup=on\n');self.assertEqual(self.stage('ME').returncode,0)
  self.assertIn('exclude=dun-test',(self.target/'USOS/ADDONS/SELECT.INI').read_text())
 def test_language_uses_document_not_english_setup_stub(self):
  f=self.root/'SETUP.TXT'
  for text,want in (('{\\rtf1\\deflang1045 test}','PL'),('Plik README dla Instalatora','PL'),('      Microsoft Windows 95 - informacje na temat instalacji\r\n','PL'),('Microsoft Windows 95 README for Setup','EN'),('README for Setup','EN'),('unknown language','XX')):
   f.write_text(text);r=subprocess.run([str(self.exe),'language',str(f)],capture_output=True);self.assertEqual(r.stdout.strip().decode(),want)

class Render(unittest.TestCase):
 def test_none_matches_pre_addons_answer_bytes(self):
  depguard.require_zig('kompilator Zig (build_legacy_stage)')
  exe=ROOT/'zig-out/bin/usos-answer.exe'
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);profile=root/'none.ini'
   profile.write_bytes((ROOT/'src/flow/answer/testdata/options.profile.ini').read_bytes()+b'\naddons_preset=none\n')
   for os_id in ('windows-95','windows-98-se','windows-me','windows-nt-4'):
    out=root/'answer';r=subprocess.run([str(exe),'render',str(profile),os_id,'x86',str(out)],capture_output=True)
    self.assertEqual(r.returncode,0,r.stderr)
    expected=ROOT/'tools/tests/data'/('addons-none.'+os_id+'.txt')
    self.assertEqual(out.read_bytes(),expected.read_bytes())
 def test_default_render_and_source_register_run_without_new_ui(self):
  depguard.require_zig('kompilator Zig (build_legacy_stage)')
  exe=ROOT/'zig-out/bin/usos-answer.exe'
  self.assertIn('USOSAddons,,"C:\\USOS\\ADDONS\\USOSADD.EXE"',(ROOT/'src/platform/bios/win9x/msbatch.inf').read_text())
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);p=root/'default.ini';p.write_text('name=Default\nuser=Tester\n')
   for os_id in ('windows-95','windows-98-se','windows-me','windows-nt-4'):
    out=root/'answer';subprocess.run([str(exe),'render',str(p),os_id,'x86',str(out)],check=True,capture_output=True)
    self.assertIn(';USOS-ADDONS-PRESET=praca',out.read_text())
    if os_id!='windows-nt-4':self.assertIn('CurrentVersion\\Run",USOSAddons',out.read_text())

if __name__=='__main__':unittest.main()
