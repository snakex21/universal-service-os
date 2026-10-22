"""Actual observer hidden() launches a real separate native console child."""
from pathlib import Path
import os,shutil,subprocess,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2];SRC=ROOT/'tools/tests/coverage/nt4_observer'
class NativeHiddenChild(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  scratch=ROOT/'artifacts/nt4-hidden-observer-host';scratch.mkdir(parents=True,exist_ok=True)
  cls.temp=tempfile.TemporaryDirectory(dir=scratch);cls.addClassCleanup(cls.temp.cleanup);cls.work=Path(cls.temp.name)
  code=(SRC/'observer.c').read_text(encoding='utf-8')
  harness=r'''
#include <stdio.h>
int main(int argc,char **argv) {
 if(argc==3 && !lstrcmpA(argv[2],"stage")) {
  if(lstrlenA(argv[1])>=MAX_PATH)return 21;
  lstrcpyA(directory,argv[1]);printf("staged=%d\n",staged(0));return 0;
 }
 if(argc==3 && !lstrcmpA(argv[1],"child")) {
  DWORD mode;FILE *file=fopen(argv[2],"wb");HWND window=GetConsoleWindow();
  if(!file)return 19;
  fprintf(file,"console=%d visible=%d\n",!!GetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE),&mode),window?!!IsWindowVisible(window):0);
  fclose(file);Sleep(150);return 0;
 }
 if(argc!=2||lstrlenA(argv[1])>=MAX_PATH)return 21;
 lstrcpyA(directory,argv[1]);{
  DWORD start=GetTickCount();int ok=hidden(0,0);
  printf("hidden_ok=%d elapsed=%lu\n",ok,GetTickCount()-start);
 }
 return 0;
}
'''
  cls.exes={};cc=shutil.which('gcc') or r'C:\msys64\mingw64\bin\gcc.exe'
  for variant,source in (('new',code),):
   c=cls.work/(variant+'.c');exe=cls.work/(variant+'.exe');c.write_text(source+harness,encoding='utf-8')
   subprocess.run([cc,'-std=c99','-O1','-Wall','-Wextra','-I',str(SRC),str(c),'-ladvapi32','-luser32','-o',str(exe)],check=True,capture_output=True,env=dict(os.environ,TEMP=str(cls.work),TMP=str(cls.work)))
   cls.exes[variant]=exe
 def run_child(self,variant,exit_code):
  directory=self.work/(variant+'-'+str(exit_code));directory.mkdir();probe=directory/'probe.txt'
  (directory/'FIRSTLO.CMD').write_bytes(('@echo off\r\n"'+str(self.exes[variant])+'" child "'+str(probe)+'"\r\nexit '+str(exit_code)+'\r\n').encode('ascii'))
  result=subprocess.run([str(self.exes[variant]),str(directory)],check=True,capture_output=True,text=True,timeout=20,cwd=directory,env=dict(os.environ,TEMP=str(directory),TMP=str(directory)))
  self.assertTrue(probe.is_file());return result.stdout,probe.read_text(encoding='ascii')
 def test_new_console_is_available_hidden_and_waited(self):
  out,probe=self.run_child('new',0);self.assertIn('hidden_ok=1',out);self.assertIn('console=1 visible=0',probe)
  self.assertGreaterEqual(int(out.split('elapsed=')[1].strip()),150)
 def test_child_nonzero_is_not_ready(self):
  out,probe=self.run_child('new',7);self.assertIn('hidden_ok=0',out);self.assertIn('console=1 visible=0',probe)
 def test_actual_staging_accepts_only_new_logger_size(self):
  directory=self.work/'stage';directory.mkdir()
  for name in ('FIRSTLO.CMD','TESTNET.CMD'):(directory/name).write_bytes(b' '*64)
  logger=directory/'USOSLOG.EXE';logger.write_bytes(b'\0'*1023488)
  def run():return subprocess.run([str(self.exes['new']),str(directory),'stage'],check=True,capture_output=True,text=True).stdout
  self.assertIn('staged=0',run());logger.write_bytes(b'\0'*1024000);self.assertIn('staged=1',run())
if __name__=='__main__':unittest.main()
