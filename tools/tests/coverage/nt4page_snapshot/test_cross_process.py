"""Actual WM_GETTEXT across processes; synthetic own windows only, no user UI read."""
from pathlib import Path
import ctypes,hashlib,json,os,subprocess,sys,threading,time,unittest
from ctypes import wintypes as w
HERE=Path(__file__).resolve().parent
OUT=HERE/'cross-process03'
ZIG=Path(r'C:\Users\ASRock\usos-work\dokumentacja-9x\tools\zig\zig.exe')
def child():
 u=ctypes.WinDLL('user32',use_last_error=True);k=ctypes.WinDLL('kernel32',use_last_error=True)
 proc_type=ctypes.WINFUNCTYPE(ctypes.c_ssize_t,w.HWND,w.UINT,w.WPARAM,w.LPARAM)
 u.CreateWindowExW.argtypes=[w.DWORD,w.LPCWSTR,w.LPCWSTR,w.DWORD,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_int,w.HWND,w.HMENU,w.HINSTANCE,w.LPVOID];u.CreateWindowExW.restype=w.HWND
 u.SetWindowLongPtrW.argtypes=[w.HWND,ctypes.c_int,ctypes.c_ssize_t];u.SetWindowLongPtrW.restype=ctypes.c_ssize_t
 u.CallWindowProcW.argtypes=[ctypes.c_void_p,w.HWND,w.UINT,w.WPARAM,w.LPARAM];u.CallWindowProcW.restype=ctypes.c_ssize_t
 u.GetMessageW.argtypes=[ctypes.POINTER(w.MSG),w.HWND,w.UINT,w.UINT]
 counts={x:0 for x in ('static','button','edit','hung')};handles={};callbacks=[];previous={}
 for name,cls,text in (('static','Static','Public synthetic static'),('button','Button','&Dalej >'),('edit','Edit','SYNTHETIC TEST CONTENT'),('hung','Static','Public synthetic hung')):
  hwnd=u.CreateWindowExW(0,cls,text,0x90000000,-30000,-30000,100,50,None,None,None,None)
  if not hwnd:raise ctypes.WinError(ctypes.get_last_error())
  handles[name]=int(hwnd)
  def factory(name):
   @proc_type
   def callback(hwnd,msg,wp,lp):
    if msg==13:
     counts[name]+=1
     if name=='hung':time.sleep(5)
    return u.CallWindowProcW(previous[name],hwnd,msg,wp,lp)
   return callback
  callback=factory(name);callbacks.append(callback);previous[name]=u.SetWindowLongPtrW(hwnd,-4,ctypes.cast(callback,ctypes.c_void_p).value)
  if not previous[name]:raise ctypes.WinError(ctypes.get_last_error())
 print(json.dumps({'pid':os.getpid(),'handles':handles}),flush=True)
 def commands():
  for line in sys.stdin:
   if line.strip()=='REPORT':print(json.dumps({'counts':counts}),flush=True)
 threading.Thread(target=commands,daemon=True).start()
 msg=w.MSG()
 while u.GetMessageW(ctypes.byref(msg),None,0,0)>0:u.TranslateMessage(ctypes.byref(msg));u.DispatchMessageW(ctypes.byref(msg))
class RealCrossProcess(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  if OUT.exists():raise ValueError('Fresh test output required')
  OUT.mkdir();tmp=OUT/'tmp';tmp.mkdir();dll=OUT/'cross.dll'
  env=dict(os.environ,TEMP=str(tmp),TMP=str(tmp),ZIG_GLOBAL_CACHE_DIR=str(OUT/'zig-global'),ZIG_LOCAL_CACHE_DIR=str(OUT/'zig-local'))
  subprocess.run([str(ZIG),'cc','-target','x86_64-windows-gnu','-Os','-shared','-nostdlib','-fno-builtin','-fno-stack-protector','-isystem',str(ZIG.parent/'lib/libc/include/any-windows-any'),str(HERE/'cross_process.c'),'-Wl,--entry,DllMain','-lkernel32','-luser32','-o',str(dll)],check=True,env=env)
  cls.lib=ctypes.WinDLL(str(dll));cls.lib.real_read.argtypes=[w.HWND,w.LPCWSTR,w.DWORD];cls.lib.real_read.restype=w.DWORD
  cls.target=subprocess.Popen([sys.executable,'-I','-B',str(Path(__file__).resolve()),'--child'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf-8',creationflags=subprocess.CREATE_NO_WINDOW,env=env)
  hello=json.loads(cls.target.stdout.readline());cls.handles=hello['handles']
  if hello['pid']==os.getpid():raise AssertionError('Must use a different process')
 @classmethod
 def tearDownClass(cls):
  cls.target.terminate();cls.target.wait(timeout=10)
 def counts(self):
  self.target.stdin.write('REPORT\n');self.target.stdin.flush();return json.loads(self.target.stdout.readline())['counts']
 def test_01_actual_static_and_button_cross_process(self):
  self.assertEqual(self.lib.real_read(self.handles['static'],'public synthetic static',0),1)
  self.assertEqual(self.lib.real_read(self.handles['button'],'dalej >',0),1)
  counts=self.counts();self.assertEqual(counts['static'],1);self.assertEqual(counts['button'],1)
 def test_02_actual_edit_never_receives_wm_gettext(self):
  self.assertEqual(self.lib.real_read(self.handles['edit'],'anything',0),2)
  self.assertEqual(self.counts()['edit'],0)
 def test_03_expired_total_budget_reads_nothing(self):
  before=self.counts()['static'];self.assertEqual(self.lib.real_read(self.handles['static'],'public synthetic static',15000),4)
  self.assertEqual(self.counts()['static'],before)
 def test_04_hung_cross_process_respects_remaining_total_budget(self):
  start=time.monotonic();self.assertEqual(self.lib.real_read(self.handles['hung'],'public synthetic hung',14900),0);elapsed=time.monotonic()-start
  self.assertGreaterEqual(elapsed,0.07);self.assertLess(elapsed,0.75)
if __name__=='__main__':
 if '--child' in sys.argv:child();raise SystemExit()
 result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(RealCrossProcess))
 OUT.mkdir(exist_ok=True);(OUT/'result.json').write_text(json.dumps({'tests':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'passed':result.wasSuccessful(),'scope':'Actual compiled page.c reader, actual distinct own Windows process, synthetic controls only; WM_GETTEXT receipt counted in target. EDIT not read. Hung message and whole-capture deadline covered.','source_sha256':{n:hashlib.sha256((HERE/n).read_bytes()).hexdigest() for n in ('page.c','core.h','cross_process.c','test_cross_process.py')}},indent=2)+'\n',encoding='utf-8');raise SystemExit(not result.wasSuccessful())
