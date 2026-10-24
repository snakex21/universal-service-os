/* Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Two real Win16 tasks exercise the DLL's public API and message queues.
 * Run C:\NET\WIN16\APITEST.EXE (taskA launches taskB automatically).
 */
#include <windows.h>
#include <winsock.h>
#include <string.h>

#define MSG_READY (WM_USER+81)
#define MSG_AFTER_CLEANUP (WM_USER+82)
#define MSG_DNS (WM_USER+83)
static HINSTANCE instance;
static HWND window;
static SOCKET own_socket = INVALID_SOCKET;
static int failures, role_b, cancelled, hook_seen, dns_seen;
static DWORD began;
static FARPROC previous_hook, custom_hook;
static struct hostent FAR *host_result;
static char dns_buffer[MAXGETHOSTSTRUCT];
static char *title_a = "USOS Winsock3 TaskA";
static char *title_b = "USOS Winsock3 TaskB";

static void line(const char *text)
{
    HFILE file;
    unsigned int n = 0;
    file = _lopen(role_b ? "C:\\NET\\WIN16\\APIB.LOG" : "C:\\NET\\WIN16\\APIA.LOG", OF_WRITE);
    if (file == HFILE_ERROR) return;
    _llseek(file, 0, 2);
    while (text[n]) n++;
    _lwrite(file, text, n); _lwrite(file, "\r\n", 2); _lclose(file);
}
#define VERIFY(value,label) do { if (!(value)) { failures++; line("FAIL " label); } else line("PASS " label); } while (0)

static BOOL FAR PASCAL test_hook(void)
{
    u_long nonblock = 1;
    WSADATA data;
    BOOL (FAR PASCAL *pump)(void);
    if (!hook_seen) {
        hook_seen = 1;
        VERIFY(WSAIsBlocking(), "inside blocking hook");
        VERIFY(ioctlsocket(own_socket,FIONBIO,&nonblock)==SOCKET_ERROR && WSAGetLastError()==WSAEINPROGRESS,"nonblock reentry blocked");
        VERIFY(socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP)==INVALID_SOCKET && WSAGetLastError()==WSAEINPROGRESS,"socket reentry blocked");
        VERIFY(WSAStartup(0x0101,&data)==WSAEINPROGRESS,"startup reentry blocked");
        WSASetLastError(1741);VERIFY(WSAGetLastError()==1741,"error API allowed inside hook");
    }
    if ((DWORD)(GetTickCount()-began) > 20000UL) {
        line("FAIL taskB deadline"); failures++;
        WSACancelBlockingCall(); return FALSE;
    }
    pump = (BOOL (FAR PASCAL *)(void))previous_hook;
    return pump();
}

static void finish_b(void)
{
    char byte;
    u_long nonblock = 1;
    VERIFY(!WSAIsBlocking(),"taskB independent blocking state");
    VERIFY(dns_seen,"taskB own DNS completion");
    VERIFY(host_result != NULL && host_result->h_name[0]=='u',"taskB retained result");
    VERIFY(ioctlsocket(own_socket,FIONBIO,&nonblock)==0,"taskB socket survives A cleanup");
    VERIFY(recv(own_socket,&byte,1,0)==SOCKET_ERROR && WSAGetLastError()==WSAEWOULDBLOCK,"taskB transport survives A cleanup");
    VERIFY(closesocket(own_socket)==0,"taskB close"); own_socket=INVALID_SOCKET;
    VERIFY(WSACleanup()==0,"taskB cleanup");
    line(failures ? "FINAL FAIL" : "FINAL PASS");
    DestroyWindow(window); PostQuitMessage(0);
}
static LONG FAR PASCAL wndproc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp)
{
    char byte;
    (void)wp;
    if (message==MSG_READY && !role_b) {
        VERIFY(WSAIsBlocking(),"taskA message during blocking call");
        VERIFY(recv(own_socket,&byte,0,0)==SOCKET_ERROR && WSAGetLastError()==WSAEINPROGRESS,"message reentry blocked");
        VERIFY(WSACleanup()==SOCKET_ERROR && WSAGetLastError()==WSAEINPROGRESS,"cleanup reentry blocked");
        VERIFY(WSACancelBlockingCall()==0,"taskA cancel");cancelled=1;return 0;
    }
    if (message==MSG_DNS && role_b) {
        VERIFY(WSAGETASYNCERROR(lp)==0,"taskB DNS native completion");dns_seen=1;
        PostMessage(FindWindow("USOS WS3 APPA",title_a),MSG_READY,0,0);return 0;
    }
    if (message==MSG_AFTER_CLEANUP && role_b) { finish_b();return 0; }
    if (message==WM_TIMER && role_b && (DWORD)(GetTickCount()-began)>30000UL) {
        line("FAIL taskA deadline");failures++;finish_b();return 0;
    }
    return DefWindowProc(hwnd,message,wp,lp);
}
int PASCAL WinMain(HINSTANCE current,HINSTANCE previous,LPSTR command,int show)
{
    HFILE file;
    WNDCLASS cls;
    MSG message;
    WSADATA data;
    FARPROC proc;
    char byte;
    (void)previous;(void)show;
    role_b = command != NULL && (command[0]=='B' || command[0]=='b');instance=current;
    file=_lcreat(role_b ? "C:\\NET\\WIN16\\APIB.LOG" : "C:\\NET\\WIN16\\APIA.LOG",0);
    if(file!=HFILE_ERROR) _lclose(file);
    line(role_b ? "START TaskB" : "START TaskA");
    VERIFY(WSAStartup(0x0101,&data)==0,"startup");
    if(failures) { line("FINAL FAIL");return 1; }
    own_socket=socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP);VERIFY(own_socket!=INVALID_SOCKET,"own UDP socket");
    host_result=gethostbyname(role_b ? "usos" : "localhost");VERIFY(host_result!=NULL,"own host result");
    proc=MakeProcInstance((FARPROC)wndproc,instance);
    _fmemset(&cls,0,sizeof(cls));cls.hInstance=instance;cls.lpfnWndProc=(WNDPROC)proc;
    cls.lpszClassName=role_b ? "USOS WS3 APPB" : "USOS WS3 APPA";
    VERIFY(RegisterClass(&cls)!=0,"register task class");
    window=CreateWindow(cls.lpszClassName,role_b ? title_b : title_a,WS_OVERLAPPED,0,0,80,30,NULL,NULL,instance,NULL);
    VERIFY(window!=NULL,"create task window");began=GetTickCount();
    if(role_b) {
        VERIFY(!WSAIsBlocking(),"taskB starts while A can block");
        VERIFY(WSAAsyncGetHostByName(window,MSG_DNS,"localhost",dns_buffer,sizeof(dns_buffer))!=NULL,"taskB queues own DNS");
        SetTimer(window,1,200,NULL);
        while(GetMessage(&message,NULL,0,0)) { TranslateMessage(&message);DispatchMessage(&message); }
        FreeProcInstance(proc);return failures ? 1 : 0;
    }
    custom_hook=MakeProcInstance((FARPROC)test_hook,instance);
    previous_hook=WSASetBlockingHook(custom_hook);VERIFY(previous_hook!=NULL,"previous default hook");
    VERIFY(WinExec("C:\\NET\\WIN16\\APITEST.EXE B",SW_HIDE)>31,"launch actual second task");
    VERIFY(recv(own_socket,&byte,1,0)==SOCKET_ERROR && WSAGetLastError()==WSAEINTR,"outer recv interrupted");
    VERIFY(cancelled && hook_seen && !WSAIsBlocking(),"blocking state restored");
    VERIFY(host_result!=NULL && host_result->h_name[0]=='l',"taskA result survives taskB lookup");
    VERIFY(WSAUnhookBlockingHook()==0,"restore default hook");FreeProcInstance(custom_hook);
    VERIFY(WSACancelBlockingCall()==SOCKET_ERROR && WSAGetLastError()==WSAEINVAL,"cancel idle invalid");
    VERIFY(WSACleanup()==0,"taskA cleanup with taskB alive");
    PostMessage(FindWindow("USOS WS3 APPB",title_b),MSG_AFTER_CLEANUP,0,0);
    line(failures ? "FINAL FAIL" : "FINAL PASS");
    DestroyWindow(window);FreeProcInstance(proc);return failures ? 1 : 0;
}
