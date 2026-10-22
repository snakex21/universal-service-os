from pathlib import Path
import ctypes,hashlib,importlib.util,json,os,random,struct,subprocess,unittest
HERE=Path(__file__).resolve().parent;OUT=HERE/'message-tests03';ZIG=Path(r'C:\Users\ASRock\usos-work\dokumentacja-9x\tools\zig\zig.exe')
class View(ctypes.Structure):_fields_=[('text',ctypes.c_void_p),('bytes',ctypes.c_uint),('unicode',ctypes.c_uint)]
def synthetic(payload=b'Own synthetic public error.\0',flags=0):return struct.pack('<IIIIHH',1,1010,1010,16,4+len(payload),flags)+payload
class ActualMessageTable(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  if OUT.exists():raise ValueError('Fresh output required')
  OUT.mkdir();tmp=OUT/'tmp';tmp.mkdir();dll=OUT/'actual.dll';env=dict(os.environ,TEMP=str(tmp),TMP=str(tmp),ZIG_GLOBAL_CACHE_DIR=str(OUT/'zig-global'),ZIG_LOCAL_CACHE_DIR=str(OUT/'zig-local'))
  subprocess.run([str(ZIG),'cc','-target','x86_64-windows-gnu','-Os','-shared','-nostdlib','-fno-builtin','-fno-stack-protector','-Wall','-Wextra','-Werror','-Wno-unused-function','-isystem',str(ZIG.parent/'lib/libc/include/any-windows-any'),str(HERE/'message_test.c'),'-Wl,--entry,DllMain','-o',str(dll)],check=True,env=env)
  cls.lib=ctypes.WinDLL(str(dll));cls.lib.actual_message.argtypes=[ctypes.c_void_p,ctypes.c_uint,ctypes.c_ulong,ctypes.POINTER(View)];cls.lib.actual_message.restype=ctypes.c_int;cls.lib.actual_controls.argtypes=[ctypes.c_wchar_p,ctypes.c_wchar_p,ctypes.c_uint];cls.lib.actual_controls.restype=ctypes.c_int
 def parse(self,blob,id=1010):
  data=ctypes.create_string_buffer(bytes(blob));v=View();ok=self.lib.actual_message(data,len(blob),id,ctypes.byref(v));return None if not ok else (ctypes.string_at(v.text,v.bytes),v.unicode)
 def test_ansi_and_unicode_original_views(self):
  self.assertTrue(self.parse(synthetic())==(b'Own synthetic public error.',0));self.assertTrue(self.parse(synthetic('Own synthetic public error.\0'.encode('utf-16le'),1))==('Own synthetic public error.'.encode('utf-16le'),1))
 def test_truncation_and_missing_id_rejected(self):
  data=synthetic()
  for n in range(len(data)):self.assertIsNone(self.parse(data[:n]))
  self.assertIsNone(self.parse(data,1011))
 def test_header_offsets_counts_flags_and_terminator_rejected(self):
  for at,value,size in ((0,257,4),(8,1009,4),(12,0,4),(16,3,2),(16,65535,2),(18,2,2)):
   data=bytearray(synthetic());struct.pack_into('<I' if size==4 else '<H',data,at,value);self.assertIsNone(self.parse(data))
  self.assertIsNone(self.parse(synthetic(b'No terminator',0)));self.assertIsNone(self.parse(synthetic(b'A\0X',0)));self.assertIsNone(self.parse(synthetic(b'A\0\0',1)))
 def test_ambiguous_overlapping_blocks_rejected(self):
  payload=b'Own public error.\0';data=struct.pack('<I',2)+struct.pack('<III',1010,1010,28)*2+struct.pack('<HH',4+len(payload),0)+payload;self.assertIsNone(self.parse(data))
 def test_message_control_sequences_preserve_inserts(self):
  out=ctypes.create_unicode_buffer(768);self.assertTrue(self.lib.actual_controls('Own %1!s! public%nmessage%0ignored',out,768)>0);self.assertTrue(out.value=='Own %1!s! public message');self.assertEqual(self.lib.actual_controls('X'*768,out,768),0)
 def test_bounded_mutated_tables_never_return_outside_input(self):
  rng=random.Random(1010);base=synthetic()
  for i in range(1500):
   data=bytearray(base)
   for unused in range(1+i%4):data[rng.randrange(len(data))]=rng.randrange(256)
   parsed=self.parse(data)
   if parsed is not None:self.assertLessEqual(len(parsed[0]),len(data));self.assertIn(parsed[1],(0,1))
if __name__=='__main__':
 result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ActualMessageTable));(OUT/'result.json').write_text(json.dumps({'scope':'Actual compiled C message table parser; synthetic negative cases; original kernel1010 test remains in local artifact application','tests':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'mutations':1500,'passed':result.wasSuccessful(),'source_sha256':hashlib.sha256((HERE/'message_table.h').read_bytes()).hexdigest(),'raw_microsoft_text_exported':False},indent=2)+'\n',encoding='utf-8');raise SystemExit(not result.wasSuccessful())
