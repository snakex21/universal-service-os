"""Actual production C/header and shell selector; no host SCM/registry/VM."""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest

from test_w9x_phase1_qemu import shell

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT/'tools/nt3/usosnt3/src/usosnt3.c'


class ClientPrepare(unittest.TestCase):
    def setUp(self):
        parent = ROOT/'artifacts/nt35-client-auto/host-tests'
        parent.mkdir(parents=True, exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(dir=parent)
        self.addCleanup(self.directory.cleanup)
        self.tmp = Path(self.directory.name)
        self.env = dict(os.environ, TEMP=str(self.tmp), TMP=str(self.tmp),
                        APPDATA=str(self.tmp), LOCALAPPDATA=str(self.tmp))

    def compile_run(self, source):
        exe = self.tmp/'contract.exe'
        built = subprocess.run(['C:/msys64/mingw64/bin/gcc.exe', '-std=c99', '-Wall', '-Werror',
                                str(source), '-o', str(exe)], env=self.env, capture_output=True)
        self.assertEqual(built.returncode, 0, (built.stdout+built.stderr).decode(errors='replace'))
        run = subprocess.run([str(exe)], env=self.env, capture_output=True)
        self.assertEqual(run.returncode, 0, (run.stdout+run.stderr).decode(errors='replace'))

    def test_actual_production_header_nineteen_cases(self):
        self.compile_run(ROOT/'tools/tests/client35_prepare_contract.c')

    def test_actual_done_restart_emitter_propagates_failures(self):
        actual = re.search(r'static void WINAPI service_main\(.*?\n\}',
                           SOURCE.read_text(encoding='utf-8'), re.S).group()
        prefix = r'''
#include <stdint.h>
#include <stdio.h>
#define WINAPI
typedef uint32_t DWORD;
typedef char *LPSTR;
typedef struct {DWORD dwServiceType,dwCurrentState,dwControlsAccepted,dwWin32ExitCode;} SERVICE_STATUS;
#define SERVICE_RUNNING 4
#define SERVICE_STOPPED 1
#define SERVICE_WIN32_OWN_PROCESS 16
#define SERVICE_DISABLED 4
#define ERROR_GEN_FAILURE 31
#define SVC_NAME "usosnt3"
static SERVICE_STATUS g_status;
static void *g_status_handle;
static int g_client35_requested,g_post_failed,post_result,commit_result,polished,done,restarted,slept,disabled;
static void handler(DWORD control) {(void)control;}
static void *RegisterServiceCtrlHandlerA(const char *name,void(*h)(DWORD)){(void)name;(void)h;return (void*)1;}
static void SetServiceStatus(void *handle,SERVICE_STATUS *status){(void)handle;(void)status;}
static void open_log(const char *name){(void)name;}
static void say(const char *text){(void)text;}
static int post(void){return post_result;}
static void polish(void){polished++;}
static int client35_commit_installer(void){if(commit_result)done++;return commit_result;}
static void set_dword(const char *s,void *p,const char *n,DWORD v){(void)s;(void)p;(void)n;(void)v;disabled++;}
static void write_file(const char *n,const char *s){(void)n;(void)s;done++;}
static void Sleep(DWORD ms){(void)ms;slept++;}
static void restart(void){restarted++;}
'''
        main = r'''
int main(void) {
 post_result=0;g_client35_requested=1;commit_result=1;service_main(0,0);
 if(done||restarted||slept||polished||disabled||g_status.dwWin32ExitCode!=31||!g_post_failed)return 1;
 post_result=1;commit_result=0;service_main(0,0);
 if(done||restarted||slept||disabled||polished!=1)return 2;
 commit_result=1;service_main(0,0);
 if(done!=1||restarted!=1||slept!=1||disabled||polished!=2)return 3;
 g_client35_requested=0;service_main(0,0);
 if(done!=2||restarted!=2||slept!=2||disabled!=1||polished!=3)return 4;
 return 0;
}
'''
        c = self.tmp/'emitter.c'
        c.write_bytes((prefix+actual+main).encode('utf-8'))
        self.compile_run(c)
        text = SOURCE.read_text(encoding='utf-8')
        self.assertIn('ExitProcess(post() ? 0 : 3);', text)
        self.assertIn('ExitProcess(g_post_failed ? 3 : 0);', text)
        self.assertIn('if (!client35_request()) return 0;', text)
        self.assertIn('if (!client35_prepare(network_state)) return 0;', text)

    def test_actual_shell_request_scope_and_staging_failure(self):
        root = self.tmp/'target/USOS/NT3'
        root.mkdir(parents=True)
        (root/'NET35.ON').write_bytes(b'own network staged\r\n')
        req = root/'CLNT35.REQ'
        for enabled, product, answer, expected in (
                ('on', '0', 'PROFILE', True), ('on', '0', 'DEFAULT', True),
                ('on', '0', 'USER', False), ('on', '1', 'PROFILE', False),
                ('off', '0', 'PROFILE', False), ('on', '', 'PROFILE', False),
                ('on', '0', 'UNKNOWN', False)):
            if req.exists(): req.unlink()
            script = self.tmp/'request.sh'
            script.write_text(f'. "{(ROOT/"tools/nt35_network_setup.sh").as_posix()}"\n'
                f'_u35_enabled={enabled}\nusos_nt35_client_request "{self.tmp.as_posix()}/target" "{product}" "{answer}"\n',
                encoding='utf-8', newline='\n')
            result = subprocess.run([shell(), str(script)], env=self.env, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
            self.assertEqual(req.exists(), expected)
            if expected: self.assertEqual(req.read_bytes(), b'USOS NT35 client-no-sharing\r\n')
        (root/'NET35.ON').unlink()
        script.write_text(script.read_text(encoding='utf-8').replace('"UNKNOWN"', '"PROFILE"'), encoding='utf-8')
        result = subprocess.run([shell(), str(script)], env=self.env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_only_current_existing_services_and_no_new_import_surface(self):
        header = (SOURCE.parent/'client35_prepare.h').read_text(encoding='utf-8')
        self.assertNotRegex(header, r'RegCreate\w*\s*\(')
        self.assertNotIn('ControlSet001', header)
        self.assertIn('KEY_READ | KEY_WRITE : KEY_READ', header)
        self.assertIn('installed_runtime_pass=false', header)
        self.assertNotIn('Sleep(', header)
        for forbidden in ('APPDATA', 'LOCALAPPDATA', 'HKEY_CURRENT_USER', 'CreateService', 'StartService'):
            self.assertNotIn(forbidden, header)
        target = (ROOT/'tools/nt4_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertIn('[ "$minor" != 50 ] || usos_nt35_client_request', target)

    def test_actual_checked_record_requires_complete_write_flush_close(self):
        body = re.search(r'static int write_file_checked\(.*?\n\}', SOURCE.read_text(encoding='utf-8'), re.S).group()
        c = self.tmp/'records.c'
        c.write_text(r'''
#include <stdint.h>
#include <string.h>
typedef uint32_t DWORD;
typedef void *HANDLE;
#define DIR "C:\\USOS\\NT3\\"
#define MAX_PATH 260
#define INVALID_HANDLE_VALUE ((void *)-1)
#define GENERIC_WRITE 1
#define CREATE_ALWAYS 2
#define FILE_ATTRIBUTE_NORMAL 128
static int mode,closed,flushed;
static char actual_path[260];
static int len(const char *s){return (int)strlen(s);}
static void lstrcpyA(char *d,const char *s){strcpy(d,s);}
static void lstrcatA(char *d,const char *s){strcat(d,s);}
static HANDLE CreateFileA(const char *p,int a,int b,void *c,int d,int e,void *f){
 (void)a;(void)b;(void)c;(void)d;(void)e;(void)f;strcpy(actual_path,p);return mode==1?INVALID_HANDLE_VALUE:(void *)1;}
static int WriteFile(HANDLE h,const char *s,DWORD size,DWORD *n,void *o){(void)h;(void)s;(void)o;*n=mode==2?size-1:size;return mode!=3;}
static int FlushFileBuffers(HANDLE h){(void)h;flushed++;return mode!=4;}
static int CloseHandle(HANDLE h){(void)h;closed++;return mode!=5;}
''' + body + r'''
int main(void){
 for(mode=0;mode<6;mode++){
  int ok;closed=flushed=0;ok=write_file_checked("CLNT35.LOG","bounded own record");
  if(ok!=(mode==0))return 10+mode;
  if(strcmp(actual_path,DIR "CLNT35.LOG"))return 20+mode;
  if(closed!=(mode!=1))return 30+mode;
  if(flushed!=(mode==0||mode==4||mode==5))return 40+mode;
 }
 return 0;
}
''', encoding='utf-8')
        self.compile_run(c)


if __name__ == '__main__':
    unittest.main()
