/* Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later */
/* The actual Win16 ABI source executes against a fake Windows queue and
 * the real packet/TCP engine. Only Windows API calls are replaced.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later. */
#include "shim/windows.h"
#include "shim/winsock.h"
#include <stdlib.h>
/* Reuse the deterministic packet peer, not its engine clock/main. */
#define usos_abi_now unused_peer_now
#define usos_abi_idle unused_peer_idle
#define usos_abi_cancelled unused_peer_cancelled
#define main unused_peer_main
#include "socket_stage2_harness.c"
#undef main
#undef usos_abi_idle
#undef usos_abi_cancelled
#undef usos_abi_now
#include "../../../../src/platform/bios/win16/winsock16/winsock16.c"

#define WM_NET (WM_USER+20)
#define WM_NAME (WM_USER+21)
static MSG messages[512];
static unsigned int message_head,message_tail,net_events[64],name_completions;
static LPARAM last_name_result;
static WPARAM last_name_handle;
static unsigned int names_by_task[9];
static int alive[64],timers[64];
static HTASK tasks[64],current_task=1;
static WNDPROC procedures[64],registered;
static unsigned int windows=1;

DWORD GetTickCount(void) { return now++; }
HTASK GetCurrentTask(void) { return current_task; }
HGLOBAL GlobalAlloc(UINT flags,DWORD bytes) { (void)flags;return calloc(1,bytes); }
void *GlobalLock(HGLOBAL h) { return h; }
BOOL GlobalUnlock(HGLOBAL h) { (void)h;return TRUE; }
HGLOBAL GlobalFree(HGLOBAL h) { free(h);return NULL; }
BOOL IsWindow(HWND h) { return h>0 && h<64 && alive[h]; }
BOOL PostMessage(HWND h,UINT m,WPARAM w,LPARAM l)
{
    MSG *out;
    if(!IsWindow(h) || message_head-message_tail==512) return FALSE;
    out=&messages[message_head++%512];out->hwnd=h;out->message=m;out->wParam=w;out->lParam=l;return TRUE;
}
BOOL PeekMessage(MSG *out,HWND h,UINT low,UINT high,UINT remove)
{
    unsigned int i,j;
    (void)low;(void)high;
    for(i=message_tail;i<message_head;i++) {
        MSG *candidate=&messages[i%512];
        if(tasks[candidate->hwnd]!=current_task || (h && candidate->hwnd!=h)) continue;
        *out=*candidate;
        if(remove&PM_REMOVE) { for(j=i;j+1<message_head;j++) messages[j%512]=messages[(j+1)%512];message_head--; }
        return TRUE;
    }
    return FALSE;
}
BOOL TranslateMessage(const MSG *message) { (void)message;return TRUE; }
LONG DispatchMessage(const MSG *message)
{
    HTASK previous=current_task;LONG result=0;
    if(IsWindow(message->hwnd) && procedures[message->hwnd]) {
        current_task=tasks[message->hwnd];
        result=procedures[message->hwnd](message->hwnd,message->message,message->wParam,message->lParam);
        current_task=previous;
    }
    return result;
}
LONG DefWindowProc(HWND h,UINT m,WPARAM w,LPARAM l) { (void)h;(void)m;(void)w;(void)l;return 0; }
FARPROC MakeProcInstance(FARPROC p,HINSTANCE i) { (void)i;return p; }
void FreeProcInstance(FARPROC p) { (void)p; }
WORD RegisterClass(const WNDCLASS *c) { registered=c->lpfnWndProc;return 1; }
BOOL UnregisterClass(LPCSTR c,HINSTANCE i) { (void)c;(void)i;registered=0;return TRUE; }
HWND CreateWindow(LPCSTR c,LPCSTR t,DWORD s,int x,int y,int w,int h,HWND p,HANDLE m,HINSTANCE i,void *v)
{ (void)c;(void)t;(void)s;(void)x;(void)y;(void)w;(void)h;(void)p;(void)m;(void)i;(void)v;
 if(windows>=63) return 0;windows++;alive[windows]=1;tasks[windows]=current_task;procedures[windows]=registered;return windows; }
BOOL DestroyWindow(HWND h) { if(!IsWindow(h)) return FALSE;alive[h]=0;return TRUE; }
UINT SetTimer(HWND h,UINT id,UINT period,FARPROC p)
{ (void)period;(void)p;timers[h]=1;return id; }
BOOL KillTimer(HWND h,UINT id) { (void)id;timers[h]=0;return TRUE; }
int usos_pkt_config_from_file(void) { return 1; }

static LONG app_window(HWND h,UINT m,WPARAM w,LPARAM l)
{
    (void)h;
    if(m==WM_NET) { CHECK(WSAGETSELECTERROR(l)==0 || WSAGETSELECTEVENT(l)==FD_CLOSE);net_events[WSAGETSELECTEVENT(l)]++; }
    if(m==WM_NAME) { name_completions++;names_by_task[current_task]++;last_name_handle=w;last_name_result=l; }
    return 0;
}
static void dispatch_all(void)
{ MSG message;int cap=0;while(PeekMessage(&message,0,0,0,PM_REMOVE)) { DispatchMessage(&message);CHECK(++cap<512); } }
static void pulse(int count)
{
    MSG message;unsigned int i;HTASK saved=current_task;
    while(count--) { now+=20;for(i=1;i<=windows;i++) if(timers[i]) { message.hwnd=i;message.message=WM_TIMER;message.wParam=1;message.lParam=0;DispatchMessage(&message); }for(i=1;i<=2;i++) { current_task=i;dispatch_all(); }current_task=saved; }
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
    CHECK(WSAAsyncSelect(s,1,WM_NET,FD_READ|FD_WRITE|FD_CONNECT|FD_CLOSE|FD_ACCEPT|FD_OOB)==0);
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

static void case_linger(void)
{
    SOCKET s=wrapper_socket();struct linger setting,readback;int length=sizeof(readback);char byte;
    setting.l_onoff=1;setting.l_linger=1;
    CHECK(setsockopt(s,SOL_SOCKET,SO_LINGER,(const char *)&setting,sizeof(setting))==SOCKET_ERROR);
    CHECK(WSAGetLastError()==WSAEOPNOTSUPP);
    setting.l_linger=0;
    CHECK(setsockopt(s,SOL_SOCKET,SO_LINGER,(const char *)&setting,sizeof(setting))==0);
    CHECK(getsockopt(s,SOL_SOCKET,SO_LINGER,(char *)&readback,&length)==0);
    CHECK(readback.l_onoff==1 && readback.l_linger==0);
    CHECK(closesocket(s)==0);
    CHECK(recv(s,&byte,1,0)==SOCKET_ERROR && WSAGetLastError()==WSAENOTSOCK);
    printf("linger_zero_abort=1 positive_linger_explicit=1 freed_handle=1\n");
}

static SOCKET blocking_socket;
static int hook_calls, nested_done;
static HWND second_window;
static BOOL reentry_hook(void)
{
    WSADATA data;u_long mode=1;char byte=0,name[16];fd_set set;struct timeval zero;struct in_addr addr;
    CHECK(WSAIsBlocking()==TRUE);hook_calls++;
    CHECK(socket(AF_INET,SOCK_DGRAM,17)==INVALID_SOCKET && WSAGetLastError()==WSAEINPROGRESS);
    CHECK(ioctlsocket(blocking_socket,FIONBIO,&mode)==SOCKET_ERROR && WSAGetLastError()==WSAEINPROGRESS);
    CHECK(send(blocking_socket,&byte,0,0)==SOCKET_ERROR && WSAGetLastError()==WSAEINPROGRESS);
    CHECK(recv(blocking_socket,&byte,0,0)==SOCKET_ERROR && WSAGetLastError()==WSAEINPROGRESS);
    CHECK(closesocket(blocking_socket)==SOCKET_ERROR && WSAGetLastError()==WSAEINPROGRESS);
    CHECK(WSAStartup(MAKEWORD(1,1),&data)==WSAEINPROGRESS);
    CHECK(WSACleanup()==SOCKET_ERROR && WSAGetLastError()==WSAEINPROGRESS);
    CHECK(gethostname(name,sizeof(name))==SOCKET_ERROR && WSAGetLastError()==WSAEINPROGRESS);
    CHECK(gethostbyname("localhost")==NULL && WSAGetLastError()==WSAEINPROGRESS);
    addr.s_addr=0;CHECK(inet_ntoa(addr)==NULL && WSAGetLastError()==WSAEINPROGRESS);
    CHECK(htonl(1)==(u_long)SOCKET_ERROR && WSAGetLastError()==WSAEINPROGRESS);
    FD_ZERO(&set);FD_SET(blocking_socket,&set);zero.tv_sec=zero.tv_usec=0;
    CHECK(select(0,&set,NULL,NULL,&zero)==SOCKET_ERROR && WSAGetLastError()==WSAEINPROGRESS);
    CHECK(WSASetBlockingHook((FARPROC)reentry_hook)==NULL && WSAGetLastError()==WSAEINPROGRESS);
    CHECK(WSAUnhookBlockingHook()==SOCKET_ERROR && WSAGetLastError()==WSAEINPROGRESS);
    WSASetLastError(1234);CHECK(WSAGetLastError()==1234);
    CHECK(WSACancelBlockingCall()==0);
    return FALSE;
}
static BOOL cancel_hook(void)
{ CHECK(WSAIsBlocking());hook_calls++;CHECK(WSACancelBlockingCall()==0);return FALSE; }
static void case_blocking_reentry(void)
{
    FARPROC original;char byte;u_long mode;struct sockaddr_in addr;
    blocking_socket=socket(AF_INET,SOCK_DGRAM,17);CHECK(blocking_socket!=INVALID_SOCKET);
    original=WSASetBlockingHook((FARPROC)reentry_hook);CHECK(original!=NULL && original!=(FARPROC)reentry_hook);
    CHECK(WSASetBlockingHook((FARPROC)cancel_hook)==(FARPROC)reentry_hook);
    CHECK(WSASetBlockingHook((FARPROC)reentry_hook)==(FARPROC)cancel_hook);
    CHECK(!WSAIsBlocking());CHECK(WSACancelBlockingCall()==SOCKET_ERROR && WSAGetLastError()==WSAEINVAL);
    /* A FALSE hook never dispatches this arbitrary application message. */
    CHECK(PostMessage(1,WM_NAME,77,0));
    CHECK(recv(blocking_socket,&byte,1,0)==SOCKET_ERROR && WSAGetLastError()==WSAEINTR);
    CHECK(hook_calls==1 && !WSAIsBlocking() && name_completions==0);
    CHECK(usos_sock_kind(blocking_socket)==USOS_SOCK_DGRAM);
    mode=1;CHECK(ioctlsocket(blocking_socket,FIONBIO,&mode)==0);
    CHECK(recv(blocking_socket,&byte,1,0)==SOCKET_ERROR && WSAGetLastError()==WSAEWOULDBLOCK);
    CHECK(hook_calls==1 && !WSAIsBlocking());
    CHECK(WSAUnhookBlockingHook()==0);CHECK(usos_app()->hook==NULL);
    CHECK(closesocket(blocking_socket)==0);dispatch_all();CHECK(name_completions==1);
    /* An immediately completing blocking UDP connect never enters the hook. */
    blocking_socket=socket(AF_INET,SOCK_DGRAM,17);CHECK(blocking_socket!=INVALID_SOCKET);
    CHECK(WSASetBlockingHook((FARPROC)cancel_hook)==original);
    memset(&addr,0,sizeof(addr));addr.sin_family=AF_INET;addr.sin_addr.s_addr=net_htonl(SERVER);addr.sin_port=net_htons(53);
    CHECK(connect(blocking_socket,(struct sockaddr *)&addr,sizeof(addr))==0);
    CHECK(hook_calls==1 && !WSAIsBlocking());CHECK(closesocket(blocking_socket)==0);
    CHECK(WSAUnhookBlockingHook()==0);
    printf("per_task_reentry=1 cancellation=WSAEINTR hook_restored=1 nonblock_no_hook=1\n");
}
static void case_tasks_and_ownership(void)
{
    WSADATA data;SOCKET first,second;char a[MAXGETHOSTSTRUCT],b[MAXGETHOSTSTRUCT];HANDLE ja,jb;HWND w1,w2;
    struct hostent *ha,*hb;struct protoent *pa,*pb;struct servent *sa,*sb;char *na,*nb;struct in_addr in;u_long mode=1;
    first=socket(AF_INET,SOCK_DGRAM,17);CHECK(first!=INVALID_SOCKET);WSASetLastError(1111);
    ha=gethostbyname("localhost");CHECK(ha!=NULL);pa=getprotobynumber(6);sa=getservbyname("http","tcp");
    in.s_addr=net_htonl(0x7f000001UL);na=inet_ntoa(in);CHECK(!strcmp(na,"127.0.0.1"));WSASetLastError(1111);
    ja=WSAAsyncGetHostByName(1,WM_NAME,"localhost",a,sizeof(a));CHECK(ja!=0);w1=usos_poll_window;WSASetLastError(1111);
    current_task=2;CHECK(WSAGetLastError()==0);CHECK(WSAStartup(MAKEWORD(1,1),&data)==0);
    second_window=CreateWindow("","",0,0,0,0,0,0,0,1,NULL);procedures[second_window]=app_window;
    CHECK(closesocket(first)==SOCKET_ERROR && WSAGetLastError()==WSAENOTSOCK);
    CHECK(ioctlsocket(first,FIONBIO,&mode)==SOCKET_ERROR && WSAGetLastError()==WSAENOTSOCK);
    CHECK(recv(first,b,0,0)==SOCKET_ERROR && WSAGetLastError()==WSAENOTSOCK);
    CHECK(WSAAsyncSelect(first,second_window,WM_NET,FD_READ)==SOCKET_ERROR && WSAGetLastError()==WSAENOTSOCK);
    second=socket(AF_INET,SOCK_DGRAM,17);CHECK(second!=INVALID_SOCKET && second!=first);
    hb=gethostbyname("usos");pb=getprotobynumber(17);sb=getservbyname("domain","udp");
    in.s_addr=net_htonl(0x0a00020fUL);nb=inet_ntoa(in);
    CHECK(ha!=hb && pa!=pb && sa!=sb && na!=nb);
    CHECK(!strcmp(ha->h_name,"localhost") && pa->p_proto==6 && sa->s_port==net_htons(80) && !strcmp(na,"127.0.0.1"));
    jb=WSAAsyncGetHostByName(second_window,WM_NAME,"usos",b,sizeof(b));CHECK(jb!=0 && jb!=ja);w2=usos_poll_window;
    CHECK(w1!=w2 && IsWindow(w1) && IsWindow(w2) && tasks[w1]==1 && tasks[w2]==2);
    CHECK(WSACancelAsyncRequest(ja)==SOCKET_ERROR && WSAGetLastError()==WSAEINVAL);WSASetLastError(2222);
    current_task=1;CHECK(WSAGetLastError()==1111);
    CHECK(WSACancelAsyncRequest(jb)==SOCKET_ERROR && WSAGetLastError()==WSAEINVAL);
    CHECK(WSACleanup()==0);CHECK(!IsWindow(w1) && IsWindow(w2) && timers[w2]);
    current_task=2;CHECK(WSAGetLastError()==2222);CHECK(usos_global_startups==1 && usos_sock_kind(second)==USOS_SOCK_DGRAM);
    pulse(2);CHECK(names_by_task[1]==0 && names_by_task[2]==1);
    CHECK(ioctlsocket(second,FIONBIO,&mode)==0);CHECK(recv(second,b,1,0)==SOCKET_ERROR && WSAGetLastError()==WSAEWOULDBLOCK);
    CHECK(closesocket(second)==0);CHECK(WSACleanup()==0);CHECK(!IsWindow(w2));
    current_task=1;CHECK(WSAStartup(MAKEWORD(1,1),&data)==0);
    printf("two_task_errors=1 socket_ownership=1 independent_results=1 separate_windows_jobs=1 survivor_transport=1\n");
}
static BOOL nested_hook(void)
{
    WSADATA data;SOCKET other;char byte;
    CHECK(WSAIsBlocking());CHECK(!nested_done);nested_done=1;
    current_task=2;CHECK(!WSAIsBlocking());CHECK(WSAStartup(MAKEWORD(1,1),&data)==0);
    other=socket(AF_INET,SOCK_DGRAM,17);CHECK(other!=INVALID_SOCKET);
    CHECK(WSASetBlockingHook((FARPROC)cancel_hook)!=NULL);
    CHECK(recv(other,&byte,1,0)==SOCKET_ERROR && WSAGetLastError()==WSAEINTR);
    CHECK(!WSAIsBlocking());CHECK(closesocket(other)==0);CHECK(WSACleanup()==0);
    current_task=1;CHECK(WSAIsBlocking() && !usos_app()->cancelled);
    CHECK(WSACancelBlockingCall()==0);return FALSE;
}
static void case_nested_tasks(void)
{
    char byte;blocking_socket=socket(AF_INET,SOCK_DGRAM,17);CHECK(blocking_socket!=INVALID_SOCKET);
    CHECK(WSASetBlockingHook((FARPROC)nested_hook)!=NULL);
    CHECK(recv(blocking_socket,&byte,1,0)==SOCKET_ERROR && WSAGetLastError()==WSAEINTR);
    CHECK(nested_done && !WSAIsBlocking());CHECK(closesocket(blocking_socket)==0);CHECK(WSAUnhookBlockingHook()==0);
    printf("nested_tasks=1 separate_cancel_flags=1 transport_survives_nested_cleanup=1\n");
}
static void case_select_dns_cancel(void)
{
    fd_set set;char ip[4];usos_u32 address=net_htonl(0xcb007102UL);
    blocking_socket=socket(AF_INET,SOCK_DGRAM,17);CHECK(blocking_socket!=INVALID_SOCKET);
    CHECK(WSASetBlockingHook((FARPROC)cancel_hook)!=NULL);
    FD_ZERO(&set);FD_SET(blocking_socket,&set);
    CHECK(select(0,&set,NULL,NULL,NULL)==SOCKET_ERROR && WSAGetLastError()==WSAEINTR);
    CHECK(!WSAIsBlocking() && set.fd_count==1);CHECK(closesocket(blocking_socket)==0);
    CHECK(gethostbyname("unanswered.example")==NULL && WSAGetLastError()==WSAEINTR);CHECK(!WSAIsBlocking());
    memcpy(ip,&address,4);CHECK(gethostbyaddr(ip,4,AF_INET)==NULL && WSAGetLastError()==WSAEINTR);CHECK(!WSAIsBlocking());
    CHECK(hook_calls==3);CHECK(WSAUnhookBlockingHook()==0);
    printf("select_cancel=1 forward_dns_cancel=1 reverse_dns_cancel=1 state_restored=1\n");
}
static void case_context_limits_and_refs(void)
{
    WSADATA data;HTASK task;SOCKET held;char byte;u_long mode=1;
    held=socket(AF_INET,SOCK_DGRAM,17);CHECK(held!=INVALID_SOCKET);
    CHECK(WSAStartup(MAKEWORD(1,1),&data)==0 && usos_global_startups==2);
    CHECK(WSACleanup()==0 && usos_startup_count==1 && usos_sock_kind(held)==USOS_SOCK_DGRAM);
    for(task=2;task<=USOS_APP_CONTEXTS;task++) { current_task=task;CHECK(WSAStartup(MAKEWORD(1,1),&data)==0);WSASetLastError((int)(2000+task)); }
    current_task=USOS_APP_CONTEXTS+1;
    CHECK(WSAStartup(MAKEWORD(1,1),&data)==WSAENOBUFS && usos_global_startups==USOS_APP_CONTEXTS);
    for(task=2;task<=USOS_APP_CONTEXTS;task++) { current_task=task;CHECK(WSAGetLastError()==(int)(2000+task));CHECK(WSACleanup()==0); }
    current_task=USOS_APP_CONTEXTS+1;CHECK(WSAStartup(MAKEWORD(1,1),&data)==0);CHECK(WSACleanup()==0);
    current_task=1;CHECK(usos_global_startups==1 && usos_sock_kind(held)==USOS_SOCK_DGRAM);
    CHECK(ioctlsocket(held,FIONBIO,&mode)==0);CHECK(recv(held,&byte,1,0)==SOCKET_ERROR && WSAGetLastError()==WSAEWOULDBLOCK);
    CHECK(closesocket(held)==0);
    printf("eight_context_limit=1 freed_context_reuse=1 startup_reference_counts=1 remaining_app_survives=1\n");
}
int main(int argc,char **argv)
{
    WSADATA data;
    if(argc!=2) return 2;alive[1]=1;tasks[1]=1;procedures[1]=app_window;
    CHECK(LibMain(1,0,0,NULL)==1);CHECK(WSAStartup(MAKEWORD(1,1),&data)==0);
    if(!strcmp(argv[1],"select")) case_empty_select();else if(!strcmp(argv[1],"rearm")) case_async_rearm();
    else if(!strcmp(argv[1],"name")) case_name_cancel_and_pack();else if(!strcmp(argv[1],"error")) case_so_error();
    else if(!strcmp(argv[1],"blocking")) case_blocking_reentry();else if(!strcmp(argv[1],"tasks")) case_tasks_and_ownership();
    else if(!strcmp(argv[1],"nested")) case_nested_tasks();else if(!strcmp(argv[1],"cancel")) case_select_dns_cancel();
    else if(!strcmp(argv[1],"contexts")) case_context_limits_and_refs();else if(!strcmp(argv[1],"linger")) case_linger();else return 2;
    CHECK(WSACleanup()==0);printf("failures=%d\n",failures);return failures?1:0;
}
