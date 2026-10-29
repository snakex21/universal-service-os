"""Native NT 3.51 LAN: no DHCP lease wait in GUI Setup, NETCHECK.TXT record.

Host only. usosnt3 /setup disables the DHCP client through the SCM while GUI
Setup runs (the only adapter then is the MS Loopback adapter), post() turns
it back on after the verified usosnet351 takeover and registers the
one-shot usosnetc check (USOSNT3.EXE /netcheck -> C:\\USOS\\NT3\\NETCHECK.TXT).
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'tools/nt3/usosnt3/src/usosnt3.c'
GCC = Path('C:/msys64/mingw64/bin/gcc.exe')


def function(text, name):
    match = re.search(r'\n(?:static )?[A-Za-z_][A-Za-z0-9_ *]*\b' + name + r'\([^;{]*\)\n\{.*?\n\}', text, re.S)
    if not match:
        raise AssertionError(name + ' not found')
    return match.group()


class DhcpHold(unittest.TestCase):
    def setUp(self):
        self.text = SOURCE.read_text(encoding='latin-1')

    def test_setup_starts_hold_only_on_native_net351(self):
        setup = function(self.text, 'setup')
        self.assertIn('dhcp_setup_hold_start();', setup)
        self.assertLess(setup.index('if (native_install()) {'), setup.index('dhcp_setup_hold_start();'))
        # before the 20 s BOOT.INI wait: GUI Setup's network page may come early
        self.assertLess(setup.index('dhcp_setup_hold_start();'), setup.index('Sleep(20000);'))
        selected = function(self.text, 'net351_native_selected')
        for need in ('native_install()', 'DIR "NET351.ON"', 'net351_version()'):
            self.assertIn(need, selected)
        start = function(self.text, 'dhcp_setup_hold_start')
        self.assertLess(start.index('if (!net351_native_selected()) return;'), start.index('create('))
        self.assertIn('"CreateThread"', start)

    def test_hold_disables_the_scm_record_with_the_351_signature(self):
        hold = function(self.text, 'dhcp_setup_hold')
        self.assertIn('svc_open(scm, "DHCP", SERVICE_CHANGE_CONFIG)', hold)
        self.assertIn('svc_change(svc, SERVICE_NO_CHANGE, SERVICE_DISABLED, SERVICE_NO_CHANGE,\n'
                      '                                NULL, NULL, NULL, NULL, NULL, NULL, NULL)', hold)
        self.assertIn('"DHCP.OFF"', hold)
        self.assertIn('Sleep(500);', hold)
        # 11-argument (NT 3.5+) ChangeServiceConfigA prototype; only 3.51 calls it
        proto = re.search(r'typedef BOOL \(WINAPI \*SVC_CHANGE\)\(([^)]*)\);', self.text).group(1)
        self.assertEqual(len(proto.split(',')), 11)
        # all SCM / thread functions through GetProcAddress (NT 3.1 import set unchanged)
        for name in ('OpenSCManagerA', 'OpenServiceA', 'ChangeServiceConfigA', 'CloseServiceHandle'):
            self.assertIn('GetProcAddress(adv, "%s")' % name, hold)

    def test_post_restores_dhcp_and_registers_netcheck(self):
        post = function(self.text, 'post')
        self.assertIn('if (network351_state == 2) net351_native_post();', post)
        self.assertLess(post.index('client_prepare(selected_state)'), post.index('net351_native_post();'))
        self.assertLess(post.index('net351_native_post();'), post.index('vesa();'))
        native = function(self.text, 'net351_native_post')
        self.assertLess(native.index('if (!native_install()) return;'), native.index('set_dword("DHCP"'))
        self.assertIn('set_dword("DHCP", NULL, "Start", SERVICE_AUTO_START);', native)
        self.assertIn('set_sz("usosnetc", "ImagePath", REG_EXPAND_SZ, DIR "USOSNT3.EXE /netcheck");', native)
        self.assertIn('set_dword("usosnetc", NULL, "Start", SERVICE_AUTO_START);', native)
        entry = function(self.text, 'entry')
        self.assertIn('{ "usosnetc", netcheck_main }', entry)
        self.assertLess(entry.index('"netcheck"'), entry.index('setup();'))
        main = function(self.text, 'netcheck_main')
        self.assertLess(main.index('netcheck();'), main.index('SERVICE_DISABLED'))

    def test_netcheck_record_fields(self):
        check = function(self.text, 'netcheck')
        for name in ('DhcpIPAddress', 'DhcpSubnetMask', 'DhcpDefaultGateway', 'DhcpServer', 'Lease',
                     'LeaseObtainedTime', 'LeaseTerminatesTime', 'DhcpNameServer'):
            self.assertIn('"%s"' % name, check)
        self.assertIn('"NETCHECK.TXT"', check)
        self.assertIn('waited >= 120', check)
        self.assertIn('nc_tcp("tcp_1.1.1.1_80=", 0x01010101, 80);', check)
        self.assertIn('LoadLibraryA("icmp.dll")', function(self.text, 'nc_ping'))
        self.assertIn('LoadLibraryA("wsock32.dll")', function(self.text, 'nc_tcp'))

    @unittest.skipUnless(GCC.is_file(), 'mingw gcc')
    def test_ipv4_parser_and_multi_sz_dump_execute(self):
        body = function(self.text, 'nc_ipv4') + function(self.text, 'dump_value')
        prefix = r'''
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t DWORD; typedef unsigned char BYTE; typedef void *HKEY;
#define HKEY_LOCAL_MACHINE ((HKEY)1)
#define KEY_READ 1
#define ERROR_SUCCESS 0
#define REG_SZ 1
#define REG_EXPAND_SZ 2
#define REG_DWORD 4
#define REG_MULTI_SZ 7
static char g_text[4096];
static int len(const char *s){return (int)strlen(s);}
#define lstrcpyA strcpy
#define lstrcatA strcat
static char *hex(char *p, DWORD v){return p+sprintf(p,"%08x",(unsigned)v);}
static int RegOpenKeyExA(HKEY r,const char *k,DWORD z,DWORD a,HKEY *o){(void)r;(void)k;(void)z;(void)a;*o=(HKEY)2;return 0;}
static int RegCloseKey(HKEY h){(void)h;return 0;}
static int RegQueryValueExA(HKEY h,const char *n,void *z,DWORD *t,BYTE *o,DWORD *s){
 (void)h;(void)z;(void)n;*t=REG_MULTI_SZ;memcpy(o,"192.168.0.1\0""10.0.0.1\0",21);*s=21;return 0;}
'''
        main = r'''
int main(void){
 if(nc_ipv4("192.168.0.1")!=0x0100a8c0u) return 1;
 if(nc_ipv4("1.1.1.1")!=0x01010101u) return 2;
 if(nc_ipv4("256.1.1.1")||nc_ipv4("1.2.3")||nc_ipv4("1.2.3.4x")||nc_ipv4("")) return 3;
 if(nc_ipv4("10.0.0.1,10.0.0.2")!=0x0100000au) return 4;
 dump_value(g_text,"k","DhcpDefaultGateway");
 if(strcmp(g_text,"DhcpDefaultGateway=192.168.0.1,10.0.0.1\r\n")) {puts(g_text);return 5;}
 puts("NETCHECK HELPERS PASS");return 0;}
'''
        parent = ROOT / 'artifacts/nt351-dhcp-hold'
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as temp:
            source = Path(temp) / 'helpers.c'
            source.write_text(prefix + body + main, encoding='utf-8', newline='\n')
            exe = Path(temp) / 'helpers.exe'
            env = dict(os.environ, TEMP=temp, TMP=temp)
            built = subprocess.run([str(GCC), '-std=c99', '-Wall', '-Werror', str(source), '-o', str(exe)],
                                   env=env, capture_output=True)
            self.assertEqual(built.returncode, 0, (built.stdout + built.stderr).decode(errors='replace'))
            run = subprocess.run([str(exe)], env=env, capture_output=True)
            self.assertEqual(run.returncode, 0, (run.stdout + run.stderr).decode(errors='replace'))


if __name__ == '__main__':
    unittest.main()
