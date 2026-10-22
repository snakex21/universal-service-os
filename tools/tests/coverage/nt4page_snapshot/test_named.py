from pathlib import Path
import ctypes,json,os,subprocess,unittest
HERE=Path(__file__).resolve().parent;OUT=HERE/'named-tests02';ZIG=Path(r'C:\Users\ASRock\usos-work\dokumentacja-9x\tools\zig\zig.exe')
class ActualNamedDialog(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  if OUT.exists():raise ValueError('Fresh test output required')
  OUT.mkdir();tmp=OUT/'tmp';tmp.mkdir();env=dict(os.environ,TEMP=str(tmp),TMP=str(tmp),ZIG_GLOBAL_CACHE_DIR=str(OUT/'zig-global'),ZIG_LOCAL_CACHE_DIR=str(OUT/'zig-local'));dll=OUT/'actual.dll'
  subprocess.run([str(ZIG),'cc','-target','x86_64-windows-gnu','-Os','-shared','-nostdlib','-fno-builtin','-fno-stack-protector','-isystem',str(ZIG.parent/'lib/libc/include/any-windows-any'),str(HERE/'named_test.c'),'-Wl,--entry,DllMain','-lkernel32','-luser32','-o',str(dll)],check=True,env=env)
  cls.lib=ctypes.WinDLL(str(dll));cls.lib.actual_named.argtypes=[ctypes.c_uint];cls.lib.actual_named.restype=ctypes.c_uint
 def test_original_named_path_reaches_actual_parser_and_exports_only_id(self):self.assertEqual(self.lib.actual_named(1),257)
 def test_unavailable_named_resource_is_not_matched(self):self.assertEqual(self.lib.actual_named(0),0)
if __name__=='__main__':
 result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ActualNamedDialog));(OUT/'result.json').write_text(json.dumps({'scope':'Actual named FindResource path and C dialog parser, own synthetic resource only','tests':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'passed':result.wasSuccessful()},indent=2)+'\n',encoding='utf-8');raise SystemExit(not result.wasSuccessful())
