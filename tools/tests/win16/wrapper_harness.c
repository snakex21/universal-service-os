/* Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later */
/* The actual Win16 ABI source executes against a fake Windows queue and
 * the real packet/TCP engine. Only Windows API calls are replaced.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later. */
#include "shim/windows.h"
#include "shim/winsock.h"
/* Reuse the deterministic packet peer, not its engine clock/main. */
#define usos_abi_now unused_peer_now
#define usos_abi_idle unused_peer_idle
#define main unused_peer_main
#include "socket_stage2_harness.c"
#undef main
#undef usos_abi_idle
#undef usos_abi_now
#include "../../../../src/platform/bios/win16/winsock16/winsock16.c"

#define WM_NET (WM_USER+20)
#define WM_NAME (WM_USER+21)
static MSG messages[512];
static unsigned int message_head,message_tail,net_events[64],name_completions;
static LPARAM last_name_result;
static WPARAM last_name_handle;
static int alive[64],timer_active;
static HWND timer_window;
static WNDPROC procedures[64],registered;
static unsigned int windows=1;

DWORD GetTickCount(void) { return now++; }
BOOL IsWindow(HWND h) { return h>0 && h<64 && alive[h]; }
BOOL PostMessage(HWND h,UINT m,WPARAM w,LPARAM l)
{
    MSG *out;
    if(!IsWindow(h) || message_head-message_tail==512) return FALSE;
    out=&messages[message_head++%512];out->hwnd=h;out->message=m;out->wParam=w;out->lParam=l;return TRUE;
}
BOOL PeekMessage(MSG *out,HWND h,UINT low,UINT high,UINT remove)
{
    (void)h;(void)low;(void)high;
    if(message_head==message_tail) return FALSE;
    *out=messages[message_tail%512];if(remove&PM_REMOVE) message_tail++;return TRUE;
}
BOOL TranslateMessage(const MSG *message) { (void)message;return TRUE; }
LONG DispatchMessage(const MSG *message)
{
    if(IsWindow(message->hwnd) && procedures[message->hwnd])
        return procedures[message->hwnd](message->hwnd,message->message,message->wParam,message->lParam);
    return 0;
}
LONG DefWindowProc(HWND h,UINT m,WPARAM w,LPARAM l) { (void)h;(void)m;(void)w;(void)l;return 0; }
FARPROC MakeProcInstance(FARPROC p,HINSTANCE i) { (void)i;return p; }
void FreeProcInstance(FARPROC p) { (void)p; }
WORD RegisterClass(const WNDCLASS *c) { registered=c->lpfnWndProc;return 1; }
BOOL UnregisterClass(LPCSTR c,HINSTANCE i) { (void)c;(void)i;registered=0;return TRUE; }
HWND CreateWindow(LPCSTR c,LPCSTR t,DWORD s,int x,int y,int w,int h,HWND p,HANDLE m,HINSTANCE i,void *v)
{ (void)c;(void)t;(void)s;(void)x;(void)y;(void)w;(void)h;(void)p;(void)m;(void)i;(void)v;
 if(windows>=63) return 0;windows++;alive[windows]=1;procedures[windows]=registered;return windows; }
BOOL DestroyWindow(HWND h) { if(!IsWindow(h)) return FALSE;alive[h]=0;return TRUE; }
UINT SetTimer(HWND h,UINT id,UINT period,FARPROC p)
{ (void)period;(void)p;timer_window=h;timer_active=1;return id; }
BOOL KillTimer(HWND h,UINT id) { (void)h;(void)id;timer_active=0;return TRUE; }
int usos_pkt_config_from_file(void) { return 1; }

static LONG app_window(HWND h,UINT m,WPARAM w,LPARAM l)
{
    (void)h;
    if(m==WM_NET) { CHECK(WSAGETSELECTERROR(l)==0 || WSAGETSELECTEVENT(l)==FD_CLOSE);net_events[WSAGETSELECTEVENT(l)]++; }
    if(m==WM_NAME) { name_completions++;last_name_handle=w;last_name_result=l; }
    return 0;
}
static void dispatch_all(void)
{ MSG message;int cap=0;while(PeekMessage(&message,0,0,0,PM_REMOVE)) { DispatchMessage(&message);CHECK(++cap<512); } }
static void pulse(int count)
{
    MSG message;
    while(count--) { now+=20;if(timer_active) { message.hwnd=timer_window;message.message=WM_TIMER;message.wParam=1;message.lParam=0;DispatchMessage(&message); }dispatch_all(); }
}
static SOCKET wrapper_socket(void)
{
    SOCKET s=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);
    struct sockaddr_in address;
    CHECK(s!=INVALID_SOCKET);CHECK(WSAAsyncSelect(s,1,WM_NET,FD_READ|FD_WRITE|FD_CONNECT|FD_CLOSE)==0);
    memset(&address,0,sizeof(address));address.sin_family=AF_INET;address.sin_port=htons(80);address.sin_addr.s_addr=htonl(SERVER);
    CHECK(connect(s,(struct sockaddr *)&address,sizeof(address))==SOCKET_ERROR && WSAGetLastError()==WSAEWOULDBLOCK);
    pulse(5);CHECK(net_events[FD_CONNECT]==1);CHECK(net_events[FD_WRITE]==1);return s;
}
static void case_empty_select(void)
{
    fd_set empty;struct timeval zero;
    FD_ZERO(&empty);zero.tv_sec=zero.tv_usec=0;
    CHECK(select(0,NULL,NULL,NULL,NULL)==SOCKET_ERROR && WSAGetLastError()==WSAEINVAL);
    CHECK(select(0,&empty,NULL,NULL,&zero)==SOCKET_ERROR && WSAGetLastError()==WSAEINVAL);
    printf("empty_select=WSAEINVAL\n");
}
static void case_async_rearm(void)
{
    SOCKET s=wrapper_socket();char buffer[4096];u_long mode=0,count=0;int rc,before;
    CHECK(ioctlsocket(s,FIONBIO,&mode)==SOCKET_ERROR && WSAGetLastError()==WSAEINVAL);
    CHECK(recv(s,buffer,sizeof(buffer),0)==SOCKET_ERROR && WSAGetLastError()==WSAEWOULDBLOCK);
    push_data(0,0,100,USOS_TCP_PSH);pulse(2);CHECK(net_events[FD_READ]==1);
    pulse(3);CHECK(net_events[FD_READ]==1);
    CHECK(ioctlsocket(s,FIONREAD,&count)==0 && count==100);
    CHECK(recv(s,buffer,50,0)==50);pulse(1);CHECK(net_events[FD_READ]==2);
    CHECK(recv(s,buffer,sizeof(buffer),0)==50);pulse(1);CHECK(net_events[FD_READ]==2);
    auto_ack=0;memset(buffer,'Q',sizeof(buffer));before=net_events[FD_WRITE];
    CHECK(send(s,buffer,sizeof(buffer),0)==4096);
    rc=send(s,buffer,1,0);CHECK(rc==SOCKET_ERROR && WSAGetLastError()==WSAEWOULDBLOCK);
    push_tcp(80,ports[0],server_base[0]+100,client_next[0],USOS_TCP_ACK,4096,0,0);pulse(2);
    CHECK(net_events[FD_WRITE]==before+1);
    CHECK(closesocket(s)==0);printf("async_nonblock=1 read_rearm=1 write_rearm=1\n");
}
static int inside(const void *pointer,const char *buffer,unsigned int room)
{ return (const char *)pointer>=buffer && (const char *)pointer<buffer+room; }
static void case_name_cancel_and_pack(void)
{
    char cancelled[MAXGETHOSTSTRUCT],packed[MAXGETHOSTSTRUCT];
    HANDLE cancel,done;struct hostent *host;usos_u32 address;
    memset(cancelled,0x6d,sizeof(cancelled));memset(packed,0x37,sizeof(packed));
    cancel=WSAAsyncGetHostByName(1,WM_NAME,"localhost",cancelled,sizeof(cancelled));CHECK(cancel!=0);
    CHECK(WSACancelAsyncRequest(cancel)==0);pulse(3);CHECK(name_completions==0);CHECK((unsigned char)cancelled[0]==0x6d);
    done=WSAAsyncGetHostByName(1,WM_NAME,"127.0.0.1",packed,sizeof(packed));CHECK(done!=0);pulse(2);
    CHECK(name_completions==1 && last_name_handle==done && WSAGETASYNCERROR(last_name_result)==0);
    host=(struct hostent *)packed;CHECK(inside(host->h_name,packed,sizeof(packed)));CHECK(!strcmp(host->h_name,"127.0.0.1"));
    CHECK(inside(host->h_aliases,packed,sizeof(packed)) && !host->h_aliases[0]);
    CHECK(inside(host->h_addr_list,packed,sizeof(packed)) && inside(host->h_addr_list[0],packed,sizeof(packed)) && !host->h_addr_list[1]);
    memcpy(&address,host->h_addr_list[0],4);CHECK(ntohl(address)==0x7f000001UL);CHECK(host->h_addrtype==AF_INET && host->h_length==4);
    CHECK(WSAGETASYNCBUFLEN(last_name_result)>sizeof(*host) && WSAGETASYNCBUFLEN(last_name_result)<sizeof(packed));
    host=gethostbyname("usos");CHECK(host!=NULL);if(host) { memcpy(&address,host->h_addr_list[0],4);CHECK(ntohl(address)==CLIENT); }
    printf("cancel_no_completion=1 hostent_native_pointers=1 local_hostname=1\n");
}
static void case_so_error(void)
{
    SOCKET s=wrapper_socket();int error=0,length=1;
    push_tcp(80,ports[0],server_base[0],client_next[0],USOS_TCP_RST|USOS_TCP_ACK,4096,0,0);pulse(1);
    CHECK(getsockopt(s,SOL_SOCKET,SO_ERROR,(char *)&error,&length)==SOCKET_ERROR && WSAGetLastError()==WSAEFAULT);
    length=sizeof(error);CHECK(getsockopt(s,SOL_SOCKET,SO_ERROR,(char *)&error,&length)==0 && error==WSAECONNRESET);
    length=sizeof(error);CHECK(getsockopt(s,SOL_SOCKET,SO_ERROR,(char *)&error,&length)==0 && error==0);
    CHECK(closesocket(s)==0);printf("invalid_optlen_preserves_so_error=1\n");
}
int main(int argc,char **argv)
{
    WSADATA data;
    if(argc!=2) return 2;alive[1]=1;procedures[1]=app_window;
    CHECK(LibMain(1,0,0,NULL)==1);CHECK(WSAStartup(MAKEWORD(1,1),&data)==0);
    if(!strcmp(argv[1],"select")) case_empty_select();else if(!strcmp(argv[1],"rearm")) case_async_rearm();
    else if(!strcmp(argv[1],"name")) case_name_cancel_and_pack();else if(!strcmp(argv[1],"error")) case_so_error();else return 2;
    CHECK(WSACleanup()==0);printf("failures=%d\n",failures);return failures?1:0;
}
