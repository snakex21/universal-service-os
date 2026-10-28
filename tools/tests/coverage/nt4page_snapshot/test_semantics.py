from pathlib import Path
import ctypes,hashlib,json,os,subprocess,unittest
HERE=Path(__file__).resolve().parent
ZIG=Path(__import__('os').environ.get('USOS_ZIG') or next((str(p/'tools/zig/zig.exe') for p in Path(__file__).resolve().parents if (p/'tools/zig/zig.exe').is_file()),'zig.exe'))
OUT=HERE/'semantic09'
class RealCPolicy(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  if OUT.exists():__import__('shutil').rmtree(OUT)
  OUT.mkdir();tmp=OUT/'tmp';tmp.mkdir();dll=OUT/'semantic.dll'
  env=dict(os.environ,TEMP=str(tmp),TMP=str(tmp),ZIG_GLOBAL_CACHE_DIR=str(OUT/'zig-global'),ZIG_LOCAL_CACHE_DIR=str(OUT/'zig-local'))
  subprocess.run([str(ZIG),'cc','-target','x86_64-windows-gnu','-Os','-shared','-nostdlib','-fno-builtin','-fno-stack-protector','-isystem',str(ZIG.parent/'lib/libc/include/any-windows-any'),str(HERE/'semantic.c'),'-Wl,--entry,DllMain','-lkernel32','-luser32','-o',str(dll)],check=True,env=env)
  cls.lib=ctypes.WinDLL(str(dll));cls.lib.test_child_exit.argtypes=[ctypes.c_uint32];cls.lib.test_child_exit.restype=ctypes.c_uint32;cls.lib.test_read_gate.argtypes=[ctypes.c_wchar_p,ctypes.c_int];cls.lib.test_read_gate.restype=ctypes.c_uint32;cls.lib.test_public_match.argtypes=[ctypes.c_wchar_p,ctypes.c_wchar_p];cls.lib.test_public_match.restype=ctypes.c_int
 def test_actual_remember_never_reads_edit(self):
  for name in ('Edit','EDIT','edit'):
   self.assertEqual(self.lib.test_read_gate(name,0),256)
 def test_other_private_control_classes_are_not_read(self):
  for name in ('RichEdit20W','ComboBox','SysListView32','CustomPrivateControl'):
   self.assertEqual(self.lib.test_read_gate(name,0),0)
 def test_static_button_and_only_top_dialog_are_read(self):
  for name in ('Static','BUTTON'):
   self.assertEqual(self.lib.test_read_gate(name,0),65537)
  self.assertEqual(self.lib.test_read_gate('#32770',0),0);self.assertEqual(self.lib.test_read_gate('#32770',1),65537)
 def test_com_open_failure_still_launches_native_and_preserves_exact_exit(self):
  for code in (0,19,259,0xc0000005):self.assertEqual(self.lib.test_child_exit(code),code)
 def test_file_observation_completes_when_com_is_unavailable(self):
  self.assertEqual(self.lib.test_file_observation_without_com(),1)
 def test_childexit_during_capture_cannot_interleave_final_flag(self):
  self.assertEqual(self.lib.test_childexit_during_capture(),1)
 def test_public_normalized_match_not_arbitrary_text(self):
  self.assertEqual(self.lib.test_public_match('  &Dalej >\r\n','Dalej >'),1)
  self.assertEqual(self.lib.test_public_match('PRIVATE TEST VALUE','Dalej >'),0)
if __name__=='__main__':
 result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(RealCPolicy))
 (OUT/'result.json').write_text(json.dumps({'tests':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'passed':result.wasSuccessful(),'scope':'Actual compiled C entry/callback with fake Win32; no host process/COM/registry operation','source_sha256':{n:hashlib.sha256((HERE/n).read_bytes()).hexdigest() for n in ('page.c','core.h','semantic.c')}},indent=2)+'\n',encoding='utf-8');raise SystemExit(not result.wasSuccessful())
