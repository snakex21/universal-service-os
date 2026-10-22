"""Exercise the real compatibility code with an absent NT3.1 API table."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[3]
HEADER=ROOT/'src/platform/bios/win9x/usoslog_compat.h'
HARNESS=r'''
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
static int mode, legacy_calls;
static void mset(void *out,int value,DWORD n) { memset(out,value,n); }
static HMODULE WINAPI fake_module(LPCSTR name) { (void)name;return (HMODULE)1; }
static BOOL WINAPI fake_extended(OSVERSIONINFOA *v) {
    v->dwMajorVersion=10;v->dwMinorVersion=0;v->dwBuildNumber=19045;v->dwPlatformId=2;
    return mode==1;
}
static FARPROC WINAPI fake_proc(HMODULE m,LPCSTR name) {
    (void)m;
    return mode && !strcmp(name,"GetVersionExA") ? (FARPROC)fake_extended : 0;
}
static DWORD WINAPI fake_version(void) { legacy_calls++;return 0x02100a03UL; }
#define GetModuleHandleA fake_module
#define GetProcAddress fake_proc
#define GetVersion fake_version
#include "HEADER"
int main(int argc,char **argv) {
    OSVERSIONINFOA v;
    char out[5]={'#','x','x','x','#'};
    if(argc!=2)return 2;
    mode=!strcmp(argv[1],"modern") ? 1 : !strcmp(argv[1],"failed-modern") ? 2 : 0;
    if(!strcmp(argv[1],"copy")) {
        if(compat_strcopy(out+1,"long",0)!=out+1 || out[1]!='x')return 3;
        compat_strcopy(out+1,"long",3);
        if(out[0]!='#' || out[1]!='l' || out[2]!='o' || out[3] || out[4]!='#')return 4;
        compat_strcopy(out+1,"long",1);
        if(out[0]!='#' || out[1] || out[4]!='#')return 5;
        puts("bounded-copy=PASS");return 0;
    }
    if(!compat_os_version(&v))return 6;
    printf("%lu.%lu build=%lu platform=%lu fallback=%d csd=%s\n",
        v.dwMajorVersion,v.dwMinorVersion,v.dwBuildNumber,v.dwPlatformId,legacy_calls,v.szCSDVersion);
    return 0;
}
'''


class Nt3CompatibilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cc=shutil.which('gcc') or (r'C:\msys64\mingw64\bin\gcc.exe' if Path(r'C:\msys64\mingw64\bin\gcc.exe').is_file() else None)
        if not cc:raise unittest.SkipTest('A Windows host C compiler is required')
        scratch=ROOT/'artifacts/nt3-logger/tests';scratch.mkdir(parents=True,exist_ok=True)
        cls.temporary=tempfile.TemporaryDirectory(dir=scratch)
        cls.addClassCleanup(cls.temporary.cleanup)
        directory=Path(cls.temporary.name)
        source=directory/'compat.c';source.write_text(HARNESS.replace('HEADER',HEADER.as_posix()),encoding='utf-8')
        cls.exe=directory/'compat.exe'
        subprocess.run([cc,'-Wall','-Wextra','-Werror','-Wno-cast-function-type','-O2',str(source),'-o',str(cls.exe)],check=True,capture_output=True)

    def invoke(self,mode):return subprocess.run([str(self.exe),mode],check=True,capture_output=True,text=True).stdout

    def test_original_nt31_without_version_ex_uses_the_legacy_api(self):
        self.assertIn('3.10 build=528 platform=2 fallback=1 csd=',self.invoke('legacy'))

    def test_existing_extended_api_keeps_its_complete_result(self):
        self.assertIn('10.0 build=19045 platform=2 fallback=0',self.invoke('modern'))

    def test_failed_extended_api_does_not_leave_partial_modern_fields(self):
        self.assertIn('3.10 build=528 platform=2 fallback=1 csd=',self.invoke('failed-modern'))

    def test_bounded_copy_preserves_guards_and_zero_capacity(self):
        self.assertIn('bounded-copy=PASS',self.invoke('copy'))


if __name__=='__main__':unittest.main()
