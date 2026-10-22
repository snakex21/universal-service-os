from pathlib import Path
import ctypes,hashlib,json,os,subprocess,unittest
HERE=Path(__file__).resolve().parent
ZIG=Path(r'C:\Users\ASRock\usos-work\dokumentacja-9x\tools\zig\zig.exe');OUT=HERE/'template-tests03'
class RealBoundedTemplate(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  if OUT.exists():raise ValueError('Fresh test output required')
  OUT.mkdir();tmp=OUT/'tmp';tmp.mkdir();dll=OUT/'actual.dll';env=dict(os.environ,TEMP=str(tmp),TMP=str(tmp),ZIG_GLOBAL_CACHE_DIR=str(OUT/'zig-global'),ZIG_LOCAL_CACHE_DIR=str(OUT/'zig-local'))
  subprocess.run([str(ZIG),'cc','-target','x86_64-windows-gnu','-Os','-shared','-nostdlib','-fno-builtin','-fno-stack-protector','-Wall','-Wextra','-Werror','-Wno-unused-function','-isystem',str(ZIG.parent/'lib/libc/include/any-windows-any'),str(HERE/'template_test.c'),'-Wl,--entry,DllMain','-o',str(dll)],check=True,env=env)
  cls.lib=ctypes.WinDLL(str(dll));cls.lib.actual_template.argtypes=[ctypes.c_wchar_p,ctypes.c_wchar_p];cls.lib.actual_template.restype=ctypes.c_int;cls.lib.actual_fragment.argtypes=[ctypes.c_wchar_p,ctypes.c_wchar_p];cls.lib.actual_fragment.restype=ctypes.c_int
 def test_exact_public_literal_still_matches(self):self.assertEqual(self.lib.actual_template('  &Dalej >\r\n','Dalej >'),1)
 def test_numbered_insert_and_all_public_literals_match(self):
  for pattern in ('A public failure while opening registry key %1.','A public failure while opening registry key %1!s!.'):
   self.assertEqual(self.lib.actual_template('A public failure while opening registry key SYNTHETIC.',pattern),1)
 def test_printf_string_and_numeric_insert(self):
  self.assertEqual(self.lib.actual_template('A public failure while opening key SYNTHETIC with error 19.','A public failure while opening key %ws with error %lu.'),1)
 def test_whole_message_is_anchored(self):
  pattern='A public failure while opening registry key %1.'
  for actual in ('OTHER A public failure while opening registry key SYNTHETIC.','A public failure while opening registry key SYNTHETIC. OTHER','A private failure while opening registry key SYNTHETIC.'):
   self.assertEqual(self.lib.actual_template(actual,pattern),0)
 def test_short_or_adjacent_placeholders_rejected(self):
  for pattern in ('Value %1','Public %1','A public failure while opening registry key %1%2.','A public failure while opening registry key %q.'):
   self.assertEqual(self.lib.actual_template('A public failure while opening registry key SYNTHETIC.',pattern),0)
 def test_insert_bound_and_unsupported_pattern_fail_closed(self):
  self.assertEqual(self.lib.actual_template('A public failure while opening registry key '+'X'*257+'.','A public failure while opening registry key %1.'),0)
  for pattern in ('A public failure while opening registry key %1!*! .','A public failure while opening registry key %1!abcdefghijklmnopq!.'):
   self.assertEqual(self.lib.actual_template('A public failure while opening registry key SYNTHETIC.',pattern),0)
 def test_wrong_fixed_middle_and_too_many_inserts_fail(self):
  self.assertEqual(self.lib.actual_template('A public failure while opening key ONE wrong fixed middle TWO.','A public failure while opening key %1 correct fixed middle %2.'),0)
  self.assertEqual(self.lib.actual_template('A public failure while opening ONE key TWO with THREE error FOUR.','A public failure while opening %1 key %2 with %3 error %4.'),0)
 def test_public_fragment_is_diagnostic_and_never_whole_match(self):
  literal='A public failure while opening registry.';actual='Public heading: '+literal+' Public suffix.'
  self.assertEqual(self.lib.actual_fragment(actual,literal),1);self.assertEqual(self.lib.actual_template(actual,literal),0)
 def test_partial_matching_rejects_short_variable_or_changed_literals(self):
  for literal in ('Public error','A public failure while opening %1.','A public failure while opening PRIVATE.'):
   self.assertEqual(self.lib.actual_fragment('Public heading: A public failure while opening registry. Public suffix.',literal),0)
if __name__=='__main__':
 result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(RealBoundedTemplate));(OUT/'result.json').write_text(json.dumps({'scope':'Actual compiled bounded C matcher, synthetic public templates only','tests':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'passed':result.wasSuccessful(),'source_sha256':hashlib.sha256((HERE/'template.h').read_bytes()).hexdigest()},indent=2)+'\n',encoding='utf-8');raise SystemExit(not result.wasSuccessful())
