"""Execute the actual351 takeover body with a finite fake OS, never host SCM."""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT/'tools/nt3/usosnt3/src/usosnt3.c'


class Takeover(unittest.TestCase):
    def test_actual_takeover_missing_empty_version_copy_readback_status(self):
        body = re.search(r'static int nt351_network\(void\)\n\{.*?\n\}', SOURCE.read_text(), re.S).group()
        prefix = r'''
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t DWORD;
typedef unsigned char BYTE;
typedef void *HKEY;
#define WINAPI
#define MAX_PATH 260
#define DIR "C:\\USOS\\NT3\\"
#define SVC_KEY "SYSTEM\\CurrentControlSet\\Services\\"
#define HKEY_LOCAL_MACHINE ((HKEY)123)
#define KEY_READ 1
#define KEY_WRITE 2
#define ERROR_FILE_NOT_FOUND 2
#define ERROR_PATH_NOT_FOUND 3
#define REG_DWORD 4
#define REG_SZ 1
#define REG_EXPAND_SZ 2
#define FALSE 0
static int meta_len, present, reads, copies, equal, binding, opens, sets;
static int open_fail, copy_fail, value_fail, image_bad, flush_fail;
static DWORD last_error, version;
static char g_text[4096];
static int len(const char *s){return (int)strlen(s);}
#define lstrcpyA strcpy
#define lstrcatA strcat
#define lstrcmpiA strcmp
static void say(const char *s){(void)s;}
static DWORD GetLastError(void){return last_error;}
static DWORD GetFileAttributesA(const char *p){(void)p;return present?0:0xffffffff;}
static int read_text(const char *p,char *out,int cap){(void)p;(void)cap;reads++;if(meta_len>0)strcpy(out,"own351\r\n");return meta_len;}
static DWORD fake_version(void){return version;}
static void *GetModuleHandleA(const char *s){(void)s;return (void*)1;}
static void *GetProcAddress(void *m,const char *s){(void)m;(void)s;return (void*)fake_version;}
static int RegOpenKeyExA(HKEY root,const char *p,DWORD z,DWORD a,HKEY *out){
 (void)root;(void)p;(void)z;(void)a;opens++;*out=(HKEY)1;return open_fail;}
static int RegQueryValueExA(HKEY h,const char *name,void *z,DWORD *type,BYTE *out,DWORD *size){
 (void)h;(void)z;
 if(!strcmp(name,"Medium")||!strcmp(name,"EnableDHCP")){
  DWORD v=!strcmp(name,"Medium")?0:1;*type=REG_DWORD;*size=4;memcpy(out,&v,4);return 0;}
 if(!strcmp(name,"ImagePath")){
  const char *s=sets?(image_bad?"bad":"\\SystemRoot\\System32\\drivers\\usosnet351.sys"):"loop.sys";
  *type=sets?REG_EXPAND_SZ:REG_SZ;*size=(DWORD)strlen(s)+1;strcpy((char*)out,s);return 0;}
 return 2;
}
static int RegCloseKey(HKEY h){(void)h;return 0;}
static int net351_has_binding(HKEY h){(void)h;return binding;}
static int GetSystemDirectoryA(char *s,unsigned cap){(void)cap;strcpy(s,"C:\\WINNT\\system32");return 17;}
static int CopyFileA(const char *a,const char *b,int flag){(void)a;(void)b;(void)flag;copies++;return !copy_fail;}
static int net351_equal_files(const char *a,const char *b){(void)a;(void)b;return equal;}
static int net351_dword(HKEY h,const char *n,DWORD value){(void)h;(void)n;(void)value;return !value_fail;}
static int RegSetValueExA(HKEY h,const char *n,DWORD z,DWORD t,const BYTE *s,DWORD size){
 (void)h;(void)n;(void)z;(void)t;(void)s;(void)size;sets++;return 0;}
static int write_file_checked(const char *p,const char *s){(void)p;(void)s;return !flush_fail;}
static void reset(void){
 meta_len=8;present=1;reads=copies=opens=sets=0;equal=binding=1;last_error=2;version=0x3303;
 open_fail=copy_fail=value_fail=image_bad=flush_fail=0;
}
#define REQUIRE(x) do {if(!(x)){fprintf(stderr,"line%d:%s\n",__LINE__,#x);return 1;}}while(0)
'''
        main = r'''
int main(void){
 reset();meta_len=-1;present=0;REQUIRE(nt351_network()==1 && !opens && !copies && !sets);
 reset();meta_len=0;REQUIRE(nt351_network()==0 && !opens && !copies && !sets);
 reset();meta_len=-1;REQUIRE(nt351_network()==0 && !opens);
 reset();meta_len=-1;present=0;last_error=5;REQUIRE(nt351_network()==0 && !opens);
 reset();meta_len=767;REQUIRE(nt351_network()==0 && !opens);
 reset();version=0x3203;REQUIRE(nt351_network()==0 && !opens);
 reset();version=0x80003303;REQUIRE(nt351_network()==0 && !opens);
 reset();REQUIRE(nt351_network()==2 && copies==1 && sets==1);
 reset();binding=0;REQUIRE(nt351_network()==0 && !copies && !sets);
 reset();open_fail=5;REQUIRE(nt351_network()==0 && !copies && !sets);
 reset();copy_fail=1;REQUIRE(nt351_network()==0 && copies==1 && !sets);
 reset();equal=0;REQUIRE(nt351_network()==0 && !sets);
 reset();value_fail=1;REQUIRE(nt351_network()==0 && !sets);
 reset();image_bad=1;REQUIRE(nt351_network()==0 && sets==1);
 reset();flush_fail=1;REQUIRE(nt351_network()==0 && sets==1);
 puts("ACTUAL351 TAKEOVER:15casesPASS");return 0;
}
'''
        parent = ROOT/'artifacts/nt351-client-auto/host-tests'
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as temp:
            directory = Path(temp)
            source = directory/'takeover.c'
            source.write_text(prefix+body+main, encoding='utf-8', newline='\n')
            exe = directory/'takeover.exe'
            env = dict(os.environ, TEMP=temp, TMP=temp, APPDATA=temp, LOCALAPPDATA=temp)
            built = subprocess.run(['C:/msys64/mingw64/bin/gcc.exe', '-std=c99', '-Wall', '-Werror',
                                    str(source), '-o', str(exe)], env=env, capture_output=True)
            self.assertEqual(built.returncode, 0, (built.stdout+built.stderr).decode(errors='replace'))
            run = subprocess.run([str(exe)], env=env, capture_output=True)
            self.assertEqual(run.returncode, 0, (run.stdout+run.stderr).decode(errors='replace'))

    def test_actual_post_refuses_policy_before_any_post_mutation(self):
        body = re.search(r'static int post\(void\)\n\{.*?\n\}', SOURCE.read_text(), re.S).group()
        self.assertLess(body.index('if (!client_request()) return 0;'), body.index('GetSystemDirectoryA('))
        self.assertLess(body.index('nt351_network()'), body.index('client_prepare(selected_state)'))
        self.assertIn('g_client_config->minor == 51 ? network351_state : network35_state', body)
        self.assertIn('if (!network351_state || !network35_state)', body)


if __name__ == '__main__':
    unittest.main()
