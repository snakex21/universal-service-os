"""Exercise the actual NT4 launch step without starting a process."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[3]

SHIM=r'''
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
static char dir[MAX_PATH]="C:\\USOS\\NT4\\",system_id[8]="NT4";
static const char *mode;
static int launched,closed;
static int eq(const char *a,const char *b) { return !strcmp(a,b); }
static void local(char *p,const char *n) { strcpy(p,dir);strcat(p,n); }
static void log_line(const char *p) { puts(p); }
static DWORD WINAPI fake_attributes(LPCSTR p) { (void)p;return !strcmp(mode,"missing") ? INVALID_FILE_ATTRIBUTES:0; }
static BOOL WINAPI fake_close(HANDLE h) { (void)h;closed++;return 1; }
static BOOL WINAPI fake_create(LPCSTR exe,LPSTR cmd,LPSECURITY_ATTRIBUTES a,LPSECURITY_ATTRIBUTES b,
                              BOOL inherit,DWORD flags,LPVOID env,LPCSTR cwd,LPSTARTUPINFOA si,LPPROCESS_INFORMATION pi) {
    (void)a;(void)b;(void)flags;(void)env;launched++;
    printf("EXE=%s\nCMD=%s\nCWD=%s hidden=%d inherit=%d\n",exe,cmd,cwd,
           si->dwFlags==STARTF_USESHOWWINDOW && si->wShowWindow==SW_HIDE,inherit);
    pi->hThread=(HANDLE)1;pi->hProcess=(HANDLE)2;
    return strcmp(mode,"failed")!=0;
}
#define GetFileAttributesA fake_attributes
#define CloseHandle fake_close
#define CreateProcessA fake_create
'''


class LaunchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cc=shutil.which('gcc') or r'C:\msys64\mingw64\bin\gcc.exe'
        if not Path(cc).is_file():raise unittest.SkipTest('host MinGW compiler unavailable')
        cls.tmp=tempfile.TemporaryDirectory(prefix='evidence-launch-',dir=ROOT/'artifacts')
        work=Path(cls.tmp.name);c=work/'launch.c';cls.exe=work/'launch.exe'
        src=(ROOT/'tools/windows_usos_lan.c').read_text(encoding='utf-8')
        function=re.search(r'^static void network_evidence\(void\)\{.*?^\}',src,re.M|re.S).group()
        c.write_text(SHIM+function+r'''
int main(int argc,char **argv) { (void)argc;mode=argv[1];if(!strcmp(mode,"w2k"))strcpy(system_id,"W2K");
  network_evidence();printf("COUNTS launched=%d closed=%d\n",launched,closed);return 0; }
''',encoding='utf-8')
        subprocess.run([cc,str(c),'-o',str(cls.exe)],check=True,capture_output=True)
    @classmethod
    def tearDownClass(cls):cls.tmp.cleanup()
    def run_case(self,mode):
        return subprocess.run([str(self.exe),mode],check=True,capture_output=True,text=True).stdout
    def test_one_hidden_launch_uses_the_application_directory(self):
        out=self.run_case('good')
        self.assertIn('hidden=1 inherit=0',out)
        self.assertIn(r'/out "C:\USOS\NT4\USABILITY.TXT"',out)
        self.assertIn('launched=1 closed=2',out)
        self.assertIn('launch alone is not DHCP/ping/DNS PASS',out)
    def test_missing_or_failed_helper_has_no_success_claim(self):
        self.assertIn('launched=0 closed=0',self.run_case('missing'))
        out=self.run_case('failed')
        self.assertIn('launch failed',out)
        self.assertNotIn('silent evidence started',out)
    def test_w2k_is_not_silently_opted_into_nt4_step(self):
        self.assertIn('launched=0 closed=0',self.run_case('w2k'))


if __name__=='__main__':unittest.main()
