"""Run the actual bounded raw ICMP fallback with synthetic socket replies."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[3]
HEADER=ROOT/'src/platform/bios/win9x/usoslog_rawicmp.h'
HARNESS=r'''
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsock.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
static const char *mode;
static DWORD gateway=0x0202000a, tick;
static BYTE sent[32];
static int sent_size, closed, received;
static void mset(void *p,int value,DWORD n) { memset(p,value,n); }
static void mcpy(void *p,const void *q,DWORD n) { memcpy(p,q,n); }
static void o(const char *format,...) { va_list args;va_start(args,format);vprintf(format,args);va_end(args);puts(""); }
static void ipstr(char *out,DWORD address) { (void)address;strcpy(out,"10.0.2.2"); }
static DWORD fake_tick(void) { tick+=5;return tick; }
static int fake_error(void) { return 10013; }
static SOCKET fake_socket(int family,int kind,int protocol) {
    if(family!=AF_INET || kind!=SOCK_RAW || protocol!=IPPROTO_ICMP)return INVALID_SOCKET;
    return !strcmp(mode,"socketfail") ? INVALID_SOCKET : (SOCKET)3;
}
static int fake_close(SOCKET s) { (void)s;closed++;return 0; }
static int fake_wait(SOCKET s,int writing,DWORD timeout) { (void)s;(void)writing;(void)timeout;return strcmp(mode,"timeout")!=0; }
static int fake_send(SOCKET s,const char *data,int size,int flags,const struct sockaddr *address,int address_size) {
    const struct sockaddr_in *peer=(const struct sockaddr_in *)address;
    (void)s;(void)flags;
    if(size!=32 || address_size!=sizeof(*peer) || peer->sin_addr.s_addr!=gateway)return SOCKET_ERROR;
    memcpy(sent,data,size);sent_size=size;
    return !strcmp(mode,"sendfail") ? SOCKET_ERROR:size;
}
static int fake_receive(SOCKET,char *,int,int,struct sockaddr *,int *);
#define socket fake_socket
#define closesocket fake_close
#define sendto fake_send
#define recvfrom fake_receive
#define GetTickCount fake_tick
#define WSAGetLastError fake_error
#define sock_wait fake_wait
#include "HEADER"
static int fake_receive(SOCKET s,char *buffer,int capacity,int flags,struct sockaddr *address,int *address_size) {
    BYTE *packet=(BYTE *)buffer,*echo=packet+20;
    struct sockaddr_in *peer=(struct sockaddr_in *)address;
    WORD checksum;
    (void)s;(void)flags;received++;
    if(capacity<52 || *address_size<(int)sizeof(*peer) || sent_size!=32)return SOCKET_ERROR;
    memset(buffer,0,52);packet[0]=0x45;packet[3]=52;packet[8]=64;packet[9]=1;
    memcpy(packet+12,&gateway,4);memcpy(echo,sent,32);echo[0]=0;echo[2]=echo[3]=0;
    peer->sin_family=AF_INET;peer->sin_addr.s_addr=gateway;*address_size=sizeof(*peer);
    if(!strcmp(mode,"badfrom"))peer->sin_addr.s_addr++;
    if(!strcmp(mode,"badsource"))packet[12]++;
    if(!strcmp(mode,"fragment"))packet[6]=0x20;
    if(!strcmp(mode,"ihl"))packet[0]=0x4f;
    if(!strcmp(mode,"total"))packet[3]=53;
    if(!strcmp(mode,"protocol"))packet[9]=17;
    if(!strcmp(mode,"type"))echo[0]=3;
    if(!strcmp(mode,"id"))echo[4]++;
    if(!strcmp(mode,"sequence"))echo[6]++;
    if(!strcmp(mode,"payload"))echo[9]++;
    checksum=echo_checksum(echo,32);echo[2]=(BYTE)(checksum>>8);echo[3]=(BYTE)checksum;
    if(!strcmp(mode,"checksum"))echo[2]++;
    return !strcmp(mode,"short") ? 19:52;
}
int main(int argc,char **argv) {
    static const BYTE vector[]={0,1,0xf2,3,0xf4,0xf5,0xf6,0xf7};
    if(argc!=2 || echo_checksum(vector,sizeof(vector))!=0x220d)return 2;
    mode=argv[1];raw_ping_gateway();
    printf("closed=%d received=%d\n",closed,received);
    return 0;
}
'''


class RawIcmpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cc=shutil.which('gcc') or (r'C:\msys64\mingw64\bin\gcc.exe' if Path(r'C:\msys64\mingw64\bin\gcc.exe').is_file() else None)
        if not cc:raise unittest.SkipTest('A Windows host C compiler is required')
        scratch=ROOT/'artifacts/nt3-logger/raw-tests';scratch.mkdir(parents=True,exist_ok=True)
        cls.temporary=tempfile.TemporaryDirectory(dir=scratch);cls.addClassCleanup(cls.temporary.cleanup)
        directory=Path(cls.temporary.name)
        source=directory/'raw.c';source.write_text(HARNESS.replace('HEADER',HEADER.as_posix()),encoding='utf-8')
        cls.exe=directory/'raw.exe'
        result=subprocess.run([cc,'-Wall','-Wextra','-Werror','-O2',str(source),'-o',str(cls.exe)],capture_output=True)
        if result.returncode:raise AssertionError(result.stderr.decode('utf-8',errors='replace'))

    def invoke(self,mode):return subprocess.run([str(self.exe),mode],check=True,capture_output=True,text=True,timeout=10).stdout

    def test_valid_matching_gateway_echo_passes_and_closes_the_socket(self):
        output=self.invoke('valid')
        self.assertIn('PASS raw Winsock echo_match=1',output)
        self.assertIn('closed=1 received=1',output)

    def test_unrelated_or_malformed_packets_never_pass_and_are_bounded(self):
        for mode in ('badfrom','badsource','fragment','ihl','total','protocol','type','id','sequence','payload','checksum','short'):
            with self.subTest(mode=mode):
                output=self.invoke(mode)
                self.assertIn('FAIL raw Winsock echo_match=0',output)
                self.assertNotIn('PASS',output)
                self.assertIn('closed=1 received=32',output)

    def test_timeout_send_failure_and_absent_raw_socket_are_explicit(self):
        for mode in ('timeout','sendfail'):
            with self.subTest(mode=mode):
                output=self.invoke(mode)
                self.assertIn('FAIL',output);self.assertIn('closed=1 received=0',output)
        output=self.invoke('socketfail')
        self.assertIn('UNAVAILABLE',output);self.assertIn('closed=0 received=0',output)


if __name__=='__main__':unittest.main()
