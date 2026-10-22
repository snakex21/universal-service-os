"""Execute actual marker read/gate with memory-only Win32 I/O; no host registry."""
from pathlib import Path
import os,re,subprocess,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]
class MarkerGate(unittest.TestCase):
 def test_missing_empty_valid_and_read_error_use_actual_read_and_gate(self):
  source=(ROOT/'tools/nt3/usosnt3/src/usosnt3.c').read_text(encoding='utf-8')
  read=re.search(r'static int read_text\(.*?\n\}',source,re.S).group()
  entry=source[source.index('static void nt351_network(void)'):];boundary='    if (!get_version) return;';entry=entry[:entry.index(boundary)+len(boundary)]+'\n}\n'
  prefix=r'''#include <stdint.h>
#include <stdlib.h>
#include <string.h>
typedef uint32_t DWORD;typedef void *HANDLE;typedef void *HKEY;
#define WINAPI
#define MAX_PATH 260
#define DIR "C:\\USOS\\NT3\\"
#define INVALID_HANDLE_VALUE ((void *)(intptr_t)-1)
#define GENERIC_READ 1
#define FILE_SHARE_READ 1
#define OPEN_EXISTING 3
#define FILE_ATTRIBUTE_NORMAL 128
#define lstrcpyA strcpy
#define lstrcatA strcat
static int mode,opens,reads,closes,lookups;
static HANDLE CreateFileA(const char *path,int a,int b,void *c,int d,int e,void *f){
 (void)a;(void)b;(void)c;(void)d;(void)e;(void)f;opens++;
 if(strcmp(path,DIR "NET351.ON"))abort();return mode==0?INVALID_HANDLE_VALUE:(HANDLE)(intptr_t)1;
}
static int ReadFile(HANDLE handle,char *buffer,DWORD cap,DWORD *got,void *overlap){
 const char text[]="network=on\r\n";(void)overlap;reads++;
 if(handle!=(HANDLE)(intptr_t)1 || cap<sizeof text)abort();
 if(mode==3)return 0;*got=mode==2?(DWORD)strlen(text):0;if(*got)memcpy(buffer,text,*got);return 1;
}
static int CloseHandle(HANDLE handle){if(handle!=(HANDLE)(intptr_t)1)abort();closes++;return 1;}
static void *GetModuleHandleA(const char *name){if(strcmp(name,"kernel32.dll"))abort();return (void *)(intptr_t)1;}
static void *GetProcAddress(void *module,const char *name){if(module!=(void *)(intptr_t)1 || strcmp(name,"GetVersion"))abort();lookups++;return NULL;}
'''
  main=r'''
int main(void){
 for(mode=0;mode<4;mode++){
  opens=reads=closes=lookups=0;nt351_network();
  if(opens!=1)return 10+mode;
  if(reads!=(mode!=0) || closes!=(mode!=0))return 20+mode;
  if(lookups!=(mode==2))return 30+mode;
 }
 return 0;
}
'''
  parent=ROOT/'artifacts/nt351-network/marker-gate-tests';parent.mkdir(parents=True,exist_ok=True)
  with tempfile.TemporaryDirectory(dir=parent) as temporary:
   directory=Path(temporary);env=dict(os.environ,TEMP=str(directory),TMP=str(directory))
   for name,body in (('fixed',entry),('old-guard',entry.replace('read_text("NET351.ON", meta, sizeof meta) <= 0','!read_text("NET351.ON", meta, sizeof meta)'))):
    c=directory/(name+'.c');exe=directory/(name+'.exe');c.write_text(prefix+read+'\n'+body+main,encoding='utf-8')
    build=subprocess.run(['C:/msys64/mingw64/bin/gcc.exe','-std=c99','-Wall','-Werror','-Wno-unused-variable','-Wno-misleading-indentation',str(c),'-o',str(exe)],capture_output=True,text=True,env=env)
    self.assertEqual(build.returncode,0,build.stdout+build.stderr)
    run=subprocess.run([str(exe)],capture_output=True,env=env)
    self.assertEqual(run.returncode,0 if name=='fixed' else 30)
if __name__=='__main__':unittest.main()
