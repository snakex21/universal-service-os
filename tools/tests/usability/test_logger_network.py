"""Run the real logger helper with synthetic APIs; no host registry/network."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[3]
SRC=ROOT/'src/platform/bios/win9x'

SHIM=r'''
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsock.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
static const char *mode;
static DWORD gateway, dns_cfg[8];
static int ndns_cfg, creates, closes, sends, adapter_opens;
static void mset(void *p,int c,DWORD n) { memset(p,c,n); }
static void o(const char *f,...) { va_list a; va_start(a,f); vprintf(f,a); puts(""); va_end(a); }
static void ipstr(char *p,DWORD a) { sprintf(p,"%lu.%lu.%lu.%lu",a&255,(a>>8)&255,(a>>16)&255,(a>>24)&255); }
static void reg_dump(HKEY k,const char *r,const char *p,int n) { (void)k;(void)r;(void)n; printf("REG_READ %s\n",p); }
static void add_dns(DWORD a) { if(a && a!=0xffffffffUL && ndns_cfg<8) dns_cfg[ndns_cfg++]=a; }
static HMODULE WINAPI fake_load(LPCSTR name);
static FARPROC WINAPI fake_proc(HMODULE m,LPCSTR name);
static LONG WINAPI fake_open(HKEY k,LPCSTR p,DWORD o,REGSAM access,PHKEY out);
static LONG WINAPI fake_query(HKEY k,LPCSTR n,LPDWORD reserved,LPDWORD type,LPBYTE out,LPDWORD size);
static LONG WINAPI fake_close(HKEY k) { (void)k;return 0; }
#define LoadLibraryA fake_load
#define GetProcAddress fake_proc
#define RegOpenKeyExA fake_open
#define RegQueryValueExA fake_query
#define RegCloseKey fake_close
#define inet_addr ip_addr
'''

MOCKS=r'''
static HANDLE WINAPI fake_create(void) { creates++; return !strcmp(mode,"createfail") ? INVALID_HANDLE_VALUE:(HANDLE)3; }
static BOOL WINAPI fake_iclose(HANDLE h) { (void)h;closes++;return 1; }
static DWORD WINAPI fake_echo(HANDLE h,DWORD dest,void *data,WORD len,USOS_IP_OPTIONS *opt,void *buf,DWORD size,DWORD timeout) {
    USOS_ICMP_REPLY *r=buf;(void)h;(void)opt;sends++;
    if(timeout!=1500 || size<sizeof(*r)+len) return 0;
    if(!strcmp(mode,"timeout")) { SetLastError(11010);return 0; }
    r->Address=!strcmp(mode,"badaddr") ? dest+1:dest;
    r->Status=!strcmp(mode,"unreachable") ? 11003:0;
    r->RoundTripTime=2;r->DataSize=len;r->Data=r+1;
    memcpy(r->Data,data,len);
    if(!strcmp(mode,"badpayload")) ((char*)r->Data)[0]^=1;
    if(!strcmp(mode,"badpointer")) r->Data=0;
    if(!strcmp(mode,"badsize")) r->DataSize++;
    return 1;
}
static HMODULE WINAPI fake_load(LPCSTR n) {
    if(!strcmp(mode,"noapi")) return 0;
    return !strcmp(n,"IPHLPAPI.DLL") ? (HMODULE)1:(HMODULE)2;
}
static FARPROC WINAPI fake_proc(HMODULE m,LPCSTR n) {
    /* Partial exports from module 1 must not be mixed with module 2. */
    if(m==(HMODULE)1 && strcmp(n,"IcmpCreateFile")) return 0;
    if(!strcmp(n,"IcmpCreateFile")) return (FARPROC)fake_create;
    if(!strcmp(n,"IcmpCloseHandle")) return (FARPROC)fake_iclose;
    if(!strcmp(n,"IcmpSendEcho")) return (FARPROC)fake_echo;
    return 0;
}
static LONG WINAPI fake_open(HKEY k,LPCSTR p,DWORD o,REGSAM access,PHKEY out) {
    (void)k;(void)o;if(access!=KEY_READ) return ERROR_ACCESS_DENIED;
    if(strstr(p,"Tcpip\\Linkage")) { *out=(HKEY)1;return 0; }
    if(strstr(p,"NDISLoop1\\Parameters\\Tcpip")) { adapter_opens++;*out=(HKEY)2;return 0; }
    return ERROR_FILE_NOT_FOUND;
}
static LONG WINAPI fake_query(HKEY k,LPCSTR n,LPDWORD reserved,LPDWORD type,LPBYTE out,LPDWORD size) {
    const char *s=0;DWORD length=0;(void)k;(void)reserved;
    *type=REG_MULTI_SZ;
    if(!strcmp(n,"Bind")) {
        s=!strcmp(mode,"config-invalid") ? "\\Device\\..\\other\0":"\\Device\\NDISLoop1\0";
        length=(DWORD)strlen(s)+2;
        if(!strcmp(mode,"config-truncated")) { *size=5000;return ERROR_MORE_DATA; }
    } else if(!strcmp(n,"EnableDHCP")) {
        DWORD v=strcmp(mode,"config-static")!=0;*type=REG_DWORD;
        memcpy(out,&v,4);*size=4;return 0;
    } else if(!strcmp(n,"DhcpDefaultGateway")) s="0.0.0.0\0 10.0.2.2\0";
    else if(!strcmp(n,"DefaultGateway")) s="10.0.2.1\0";
    else if(!strcmp(n,"NameServer")) { s="0.0.0.0";*type=REG_SZ; }
    else if(!strcmp(n,"DhcpNameServer")) { s="10.0.2.3, 1.1.1.1";*type=REG_SZ; }
    else return ERROR_FILE_NOT_FOUND;
    if(!length) length=!strcmp(n,"DhcpDefaultGateway") ? sizeof("0.0.0.0\0 10.0.2.2\0"):(DWORD)strlen(s)+1;
    if(*size<length) { *size=length;return ERROR_MORE_DATA; }
    memcpy(out,s,length);*size=length;return 0;
}
int main(int argc,char **argv) {
    char addr[20];(void)argc;mode=argv[1];
    if(!strncmp(mode,"config-",7)) {
        if(!strcmp(mode,"config-existing")) gateway=ip_addr("192.0.2.1");
        nt_tcpip_config();ipstr(addr,gateway);
        printf("CONFIG gw=%s dns_count=%d adapter_opens=%d\n",addr,ndns_cfg,adapter_opens);
    } else {
        gateway=!strcmp(mode,"nogateway") ? 0:ip_addr("10.0.2.2");
        ping_gateway();
        printf("CALLS create=%d close=%d send=%d\n",creates,closes,sends);
    }
    return 0;
}
'''


class NetworkHelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cc=shutil.which('gcc') or r'C:\msys64\mingw64\bin\gcc.exe'
        if not Path(cc).is_file():raise unittest.SkipTest('host MinGW compiler unavailable')
        cls.tmp=tempfile.TemporaryDirectory(prefix='logger-net-',dir=ROOT/'artifacts')
        cls.work=Path(cls.tmp.name)
        source=(SRC/'usoslog.c').read_text(encoding='utf-8')
        ip=re.search(r'static DWORD ip_addr\([^\n]+\)\n\{.*?\n\}',source,re.S).group()
        c=cls.work/'network.c'
        c.write_text(SHIM+ip+'\n#include "usoslog_net.h"\n'+MOCKS,encoding='utf-8')
        cls.exe=cls.work/'network.exe'
        env=dict(os.environ,TMP=str(cls.work),TEMP=str(cls.work))
        subprocess.run([cc,'-std=c99','-Wall','-Wextra','-I',str(SRC),str(c),'-o',str(cls.exe)],
                       check=True,capture_output=True,env=env)

    @classmethod
    def tearDownClass(cls):cls.tmp.cleanup()

    def run_case(self,mode):
        return subprocess.run([str(self.exe),mode],check=True,capture_output=True,text=True).stdout

    def test_success_requires_matching_gateway_and_echo(self):
        out=self.run_case('good')
        self.assertIn('PASS status=0 replies=1',out)
        self.assertIn('create=1 close=1 send=1',out)

    def test_non_success_or_wrong_reply_never_passes(self):
        for mode in ('timeout','unreachable','badaddr','badpayload','badpointer','badsize'):
            with self.subTest(mode=mode):
                out=self.run_case(mode)
                self.assertIn('FAIL',out);self.assertNotIn('PASS',out)
                self.assertIn('close=1',out)

    def test_no_gateway_never_uses_a_guessed_address(self):
        out=self.run_case('nogateway')
        self.assertIn('SKIP',out);self.assertIn('create=0 close=0 send=0',out)

    def test_missing_api_and_handle_failure_are_explicit(self):
        out=self.run_case('noapi')
        self.assertIn('UNAVAILABLE',out);self.assertIn('send=0',out)
        out=self.run_case('createfail')
        self.assertIn('create failed',out);self.assertIn('close=0 send=0',out)

    def test_nt4_multi_sz_gateway_and_dhcp_dns(self):
        out=self.run_case('config-dhcp')
        self.assertIn('configuration/lease record, not live proof',out)
        self.assertIn('gw=10.0.2.2 dns_count=2 adapter_opens=1',out)

    def test_static_gateway_and_existing_api_choice(self):
        self.assertIn('gw=10.0.2.1',self.run_case('config-static'))
        self.assertIn('gw=192.0.2.1',self.run_case('config-existing'))

    def test_malformed_or_truncated_bindings_are_ignored(self):
        for mode in ('config-invalid','config-truncated'):
            with self.subTest(mode=mode):
                self.assertIn('gw=0.0.0.0 dns_count=0 adapter_opens=0',self.run_case(mode))


@unittest.skipUnless(os.environ.get('USOSLOG_TEST_EXE'),'set USOSLOG_TEST_EXE to the locally built own logger')
class PortableBinaryTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='portable logger ',dir=ROOT/'artifacts')
        self.work=Path(self.tmp.name)
        self.app=self.work/'moved application';self.app.mkdir()
        self.exe=self.app/'USOSLOG.EXE'
        shutil.copyfile(os.environ['USOSLOG_TEST_EXE'],self.exe)
    def tearDown(self):self.tmp.cleanup()
    def run_snapshot(self,*args):
        subprocess.run([str(self.exe),'/once','/nonet','/nodbg','/nohook','/nodisk',*args],
                       cwd=self.work,check=True,timeout=60)
    def test_default_log_follows_moved_executable(self):
        self.run_snapshot()
        text=(self.app/'LOGS/USOSLOG.TXT').read_text(encoding='latin1')
        self.assertIn('=== end of snapshot #1',text)
        self.assertFalse((self.work/'LOGS').exists())
    def test_explicit_out_creates_no_default_log_directory(self):
        out=self.work/'chosen output.txt'
        self.run_snapshot('/out',str(out))
        self.assertIn('=== end of snapshot #1',out.read_text(encoding='latin1'))
        self.assertFalse((self.app/'LOGS').exists())


if __name__=='__main__':unittest.main()
