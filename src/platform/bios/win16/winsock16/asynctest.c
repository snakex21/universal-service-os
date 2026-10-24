/* Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later */
/* Actual Win16 async ABI test; all artifacts stay beside this executable.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later. */
#include <windows.h>
#include <winsock.h>
#include <string.h>

typedef int (FAR PASCAL *START)(WORD,LPWSADATA);
typedef int (FAR PASCAL *CLEAN)(void);
typedef SOCKET (FAR PASCAL *SOCK)(int,int,int);
typedef int (FAR PASCAL *CLOSE)(SOCKET);
typedef int (FAR PASCAL *CONNECT)(SOCKET,const struct sockaddr FAR *,int);
typedef int (FAR PASCAL *RECV)(SOCKET,char FAR *,int,int);
typedef int (FAR PASCAL *SEND)(SOCKET,const char FAR *,int,int);
typedef int (FAR PASCAL *ERRORFN)(void);
typedef int (FAR PASCAL *ASYNC)(SOCKET,HWND,unsigned int,long);
typedef HANDLE (FAR PASCAL *NAME)(HWND,unsigned int,const char FAR *,char FAR *,int);
typedef HANDLE (FAR PASCAL *ADDR)(HWND,unsigned int,const char FAR *,int,int,char FAR *,int);
typedef int (FAR PASCAL *CANCEL)(HANDLE);
typedef int (FAR PASCAL *IOCTL)(SOCKET,long,u_long FAR *);
typedef int (FAR PASCAL *SELECTFN)(int,fd_set FAR *,fd_set FAR *,fd_set FAR *,const struct timeval FAR *);
typedef int (FAR PASCAL *GETOPT)(SOCKET,int,int,char FAR *,int FAR *);
typedef int (FAR PASCAL *SETOPT)(SOCKET,int,int,const char FAR *,int);
typedef struct servent FAR *(FAR PASCAL *SERVICE)(const char FAR *,const char FAR *);
typedef struct protoent FAR *(FAR PASCAL *PROTOCOL)(const char FAR *);
typedef int (FAR PASCAL *HOSTNAME)(char FAR *,int);

static HINSTANCE dll;
static HFILE log_file, response;
static HWND window;
static SOCK open_socket;
static CLOSE close_socket;
static CONNECT start_connect;
static RECV receive;
static SEND transmit;
static ERRORFN last_error;
static ASYNC async_select;
static IOCTL ioctl_socket;
static SELECTFN select_socket;
static GETOPT get_option;
static int failed, connected, got_read, got_write, got_close, reverse_done;
static SOCKET client = INVALID_SOCKET;
static HANDLE name_request, cancelled_request, reverse_request;
static char name_result[MAXGETHOSTSTRUCT], reverse_result[MAXGETHOSTSTRUCT];
static char cancelled_result[MAXGETHOSTSTRUCT], bytes[1024], first[64];
static long received;
static int sent, first_length;
static const char request[] = "GET / HTTP/1.0\r\nHost: 68k.news\r\nConnection: close\r\n\r\n";

static void text(const char *value) { _lwrite(log_file,value,(UINT)strlen(value)); }
static void number(unsigned long value)
{
    char buffer[12]; int count=0;
    do { buffer[count++]=(char)('0'+value%10); value/=10; } while(value);
    while(count) _lwrite(log_file,&buffer[--count],1);
}
static void fail(const char *where)
{
    if (failed) return;
    failed=1; text("FAIL ");text(where);text(" error=");number((unsigned long)last_error());text("\r\n");
    PostQuitMessage(1);
}
static void write_request(void)
{
    int rc;
    if (!connected) return;
    while(sent < sizeof(request)-1) {
        rc=transmit(client,request+sent,(int)sizeof(request)-1-sent,0);
        if (rc==SOCKET_ERROR && last_error()==WSAEWOULDBLOCK) return;
        if (rc<=0) { fail("send");return; }
        sent+=rc;
    }
}
static void read_response(void)
{
    int rc, i;
    u_long available;
    if (ioctl_socket(client,FIONREAD,&available)) { fail("FIONREAD");return; }
    for(;;) {
        rc=receive(client,bytes,sizeof(bytes),0);
        if(rc==SOCKET_ERROR && last_error()==WSAEWOULDBLOCK) break;
        if(rc<0) { fail("recv");return; }
        if(rc==0) break;
        if(_lwrite(response,bytes,(UINT)rc)!=(UINT)rc) { fail("response file");return; }
        for(i=0;i<rc && first_length<sizeof(first)-1;i++) first[first_length++]=bytes[i];
        received+=rc;
    }
}
LONG FAR PASCAL __export events(HWND hwnd,UINT message,WPARAM wp,LPARAM lp)
{
    struct hostent FAR *host;
    struct sockaddr_in address;
    fd_set ready;
    struct timeval nowait;
    int option, length;
    (void)hwnd;
    if(message==WM_TIMER) { fail("timeout");return 0; }
    if(message==WM_USER+1) {
        if((HANDLE)wp==cancelled_request) { fail("cancelled request posted");return 0; }
        if((HANDLE)wp!=name_request || WSAGETASYNCERROR(lp)) { fail("DNS async");return 0; }
        host=(struct hostent FAR *)name_result;
        if(host->h_addrtype!=AF_INET || host->h_length!=4 || host->h_addr_list==NULL || host->h_addr_list[0]==NULL) {
            fail("DNS far pointers");return 0;
        }
        text("DNS far pointers PASS name=");text(host->h_name);text("\r\n");
        client=open_socket(AF_INET,SOCK_STREAM,0);
        if(client==INVALID_SOCKET || async_select(client,window,WM_USER+2,FD_READ|FD_WRITE|FD_CONNECT|FD_CLOSE)) { fail("async select");return 0; }
        memset(&address,0,sizeof(address));address.sin_family=AF_INET;address.sin_port=0x5000;
        _fmemcpy(&address.sin_addr.s_addr,host->h_addr_list[0],4);
        if(start_connect(client,(struct sockaddr FAR *)&address,sizeof(address))!=SOCKET_ERROR || last_error()!=WSAEWOULDBLOCK) { fail("nonblocking connect");return 0; }
        return 0;
    }
    if(message==WM_USER+3) {
        if((HANDLE)wp!=reverse_request || WSAGETASYNCERROR(lp)) { fail("reverse async");return 0; }
        host=(struct hostent FAR *)reverse_result;
        if(strcmp(host->h_name,"localhost")) { fail("reverse name");return 0; }
        reverse_done=1; text("Async PTR localhost PASS\r\n");return 0;
    }
    if(message==WM_USER+2) {
        if(WSAGETSELECTERROR(lp)) { fail("async error");return 0; }
        switch(WSAGETSELECTEVENT(lp)) {
        case FD_CONNECT:
            if(connected) { fail("duplicate connect");return 0; }
            connected=1; text("FD_CONNECT PASS\r\n");
            memset(&ready,0,sizeof(ready));ready.fd_count=1;ready.fd_array[0]=client;
            nowait.tv_sec=0;nowait.tv_usec=0;
            if(select_socket(0,NULL,&ready,NULL,&nowait)!=1 || ready.fd_count!=1) { fail("select writable");return 0; }
            length=sizeof(option);
            if(get_option(client,SOL_SOCKET,SO_TYPE,(char FAR *)&option,&length) || option!=SOCK_STREAM) { fail("SO_TYPE");return 0; }
            write_request();break;
        case FD_WRITE: got_write=1;write_request();break;
        case FD_READ: got_read=1;read_response();break;
        case FD_CLOSE:
            got_close=1;read_response();first[first_length]=0;
            if(!failed && connected && got_write && got_read && reverse_done && received>100 &&
               (!strncmp(first,"HTTP/1.0 200",12) || !strncmp(first,"HTTP/1.1 200",12))) {
                text("PASS async HTTP 200 bytes=");number(received);text(" FD_CONNECT/WRITE/READ/CLOSE; select/ioctl/options\r\n");
                PostQuitMessage(0);
            } else fail("HTTP verdict");
            break;
        }
        return 0;
    }
    return DefWindowProc(hwnd,message,wp,lp);
}

int PASCAL WinMain(HANDLE instance,HANDLE previous,LPSTR command,int show)
{
    START startup; CLEAN cleanup; NAME async_name; ADDR async_addr; CANCEL cancel;
    SERVICE service; PROTOCOL protocol; HOSTNAME hostname; SETOPT set_option;
    WNDCLASS cls; FARPROC proc; MSG msg; WSADATA data;
    SOCKET sockets[16]; int i, value; char name[32]; unsigned long loopback=0x0100007fUL;
    struct servent FAR *serv;
    struct protoent FAR *proto;
    (void)previous;(void)show;
    log_file=_lcreat("C:\\NET\\WIN16\\ASYNC.LOG",0);
    response=_lcreat("C:\\NET\\WIN16\\ASYNC.RSP",0);
    if(log_file==HFILE_ERROR || response==HFILE_ERROR) return 1;
    text("GetWinFlags=");number(GetWinFlags());text(" mode=");
    text((GetWinFlags()&WF_STANDARD) && !(GetWinFlags()&WF_ENHANCED)?"STANDARD\r\n":"OTHER\r\n");
    dll=LoadLibrary("WINSOCK.DLL");if((UINT)dll<32) { text("FAIL LoadLibrary\r\n");return 1; }
#define LOAD(variable,type,ordinal) variable=(type)GetProcAddress(dll,MAKEINTRESOURCE(ordinal))
    LOAD(startup,START,115);LOAD(cleanup,CLEAN,116);LOAD(open_socket,SOCK,23);LOAD(close_socket,CLOSE,3);
    LOAD(start_connect,CONNECT,4);LOAD(receive,RECV,16);LOAD(transmit,SEND,19);LOAD(last_error,ERRORFN,111);
    LOAD(async_select,ASYNC,101);LOAD(async_name,NAME,103);LOAD(async_addr,ADDR,102);LOAD(cancel,CANCEL,108);
    LOAD(ioctl_socket,IOCTL,12);LOAD(select_socket,SELECTFN,18);LOAD(get_option,GETOPT,7);LOAD(set_option,SETOPT,21);
    LOAD(service,SERVICE,55);LOAD(protocol,PROTOCOL,53);LOAD(hostname,HOSTNAME,57);
    if(!startup || !cleanup || !open_socket || !close_socket || !start_connect || !receive || !transmit ||
       !last_error || !async_select || !async_name || !async_addr || !cancel || !ioctl_socket || !select_socket ||
       !get_option || !set_option || !service || !protocol || !hostname) { text("FAIL exports\r\n");return 1; }
    if(startup(0x0101,&data)) { fail("startup");goto finish; }
    for(i=0;i<16;i++) { sockets[i]=open_socket(AF_INET,SOCK_STREAM,0);if(sockets[i]==INVALID_SOCKET) { fail("16 sockets");goto finish; } }
    for(i=0;i<16;i++) close_socket(sockets[i]);
    text("16 sockets PASS\r\n");
    serv=service("http","tcp");proto=protocol("TCP");
    if(!serv || serv->s_port!=0x5000 || !proto || proto->p_proto!=6 || hostname(name,sizeof(name)) || strcmp(name,"usos")) {
        fail("databases");goto finish;
    }
    proc=MakeProcInstance((FARPROC)events,instance);
    memset(&cls,0,sizeof(cls));cls.lpfnWndProc=(WNDPROC)proc;cls.hInstance=instance;cls.lpszClassName="USOS async ABI test";
    if(!RegisterClass(&cls)) { fail("RegisterClass");goto finish; }
    window=CreateWindow(cls.lpszClassName,"",0,0,0,0,0,NULL,NULL,instance,NULL);
    if(!window || !SetTimer(window,1,55000,NULL)) { fail("window/timer");goto finish; }
    cancelled_request=async_name(window,WM_USER+1,"localhost",cancelled_result,sizeof(cancelled_result));
    if(!cancelled_request || cancel(cancelled_request)) { fail("cancel");goto finish; }
    reverse_request=async_addr(window,WM_USER+3,(char FAR *)&loopback,4,AF_INET,reverse_result,sizeof(reverse_result));
    name_request=async_name(window,WM_USER+1,"68k.news",name_result,sizeof(name_result));
    if(!reverse_request || !name_request) { fail("queue DNS");goto finish; }
    while(GetMessage(&msg,NULL,0,0)) { TranslateMessage(&msg);DispatchMessage(&msg); }
    KillTimer(window,1);DestroyWindow(window);UnregisterClass(cls.lpszClassName,instance);FreeProcInstance(proc);
finish:
    if(client!=INVALID_SOCKET) close_socket(client);
    cleanup();FreeLibrary(dll);_lclose(response);_lclose(log_file);
    if(strstr(command,"/EXIT")) ExitWindows(0,0);
    return failed;
}
