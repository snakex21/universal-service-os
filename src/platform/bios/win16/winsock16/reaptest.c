/* Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later */
/* Regression client: 16 real tasks exit without WSACleanup. The surviving
 * parent retains the DLL, then obtains HTTP 200. Run as APITEST.EXE in the
 * isolated QEMU fixture. No installer/profile change. */
#include <windows.h>
#include <winsock.h>
#include <string.h>

static HWND window;
static int failures, iteration;
static void line(const char *text)
{
    HFILE file=_lopen("C:\\NET\\WIN16\\REAPTEST.LOG",OF_WRITE);
    if(file==HFILE_ERROR) file=_lcreat("C:\\NET\\WIN16\\REAPTEST.LOG",0);
    if(file!=HFILE_ERROR) { _llseek(file,0,2);_lwrite(file,text,strlen(text));_lwrite(file,"\r\n",2);_lclose(file); }
}
#define CHECK(x,label) do { if(!(x)) { failures++;line("FAIL " label); } else line("PASS " label); } while(0)

static void finish(void)
{
    struct hostent FAR *host;
    struct sockaddr_in address;
    SOCKET sock;
    char prefix[13];int got=0,n;
    static char request[]="GET / HTTP/1.0\r\nHost: www.68k.news\r\nConnection: close\r\n\r\n";
    host=gethostbyname("www.68k.news");CHECK(host!=NULL,"parent DNS after abandoned children");
    if(host && host->h_addr_list && host->h_addr_list[0]) {
        _fmemset(&address,0,sizeof(address));address.sin_family=AF_INET;address.sin_port=htons(80);
        _fmemcpy(&address.sin_addr.s_addr,host->h_addr_list[0],4);
        sock=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);CHECK(sock!=INVALID_SOCKET,"parent TCP slot");
        if(sock!=INVALID_SOCKET) {
            n=connect(sock,(struct sockaddr FAR *)&address,sizeof(address));CHECK(n==0,"parent connect");
            if(n==0) {
                CHECK(send(sock,request,sizeof(request)-1,0)==sizeof(request)-1,"parent send");
                while(got<12) { n=recv(sock,prefix+got,12-got,0);if(n<=0) break;got+=n; }
                prefix[got]=0;
                CHECK(got==12 && (!strcmp(prefix,"HTTP/1.0 200") || !strcmp(prefix,"HTTP/1.1 200")),"parent HTTP 200");
            }
            closesocket(sock);
        }
    }
    CHECK(WSACleanup()==0,"parent cleanup");
    line(failures?"PARENT FINAL FAIL":"PARENT FINAL PASS");
    DestroyWindow(window);PostQuitMessage(0);
}

LONG FAR PASCAL __export events(HWND hwnd,UINT msg,WPARAM wp,LPARAM lp)
{
    (void)wp;
    if(msg==WM_TIMER) {
        KillTimer(hwnd,1);
        CHECK(WSAGetLastError()==0,"parent entry after child exit");
        /* Each fixed one-shot starts a different task. There are no live
         * status/screenshot queries or task-completion polling loops. */
        if(iteration++<16) {
            CHECK(WinExec("C:\\NET\\WIN16\\APITEST.EXE C",SW_HIDE)>31,"launch next abandoning child");
            SetTimer(hwnd,1,1000,NULL);
        } else finish();
        return 0;
    }
    return DefWindowProc(hwnd,msg,wp,lp);
}

int PASCAL WinMain(HINSTANCE instance,HINSTANCE previous,LPSTR cmd,int show)
{
    WSADATA data;WNDCLASS cls;MSG msg;FARPROC proc;SOCKET sock;char record[90];
    (void)previous;(void)show;
    if(cmd && cmd[0]=='C') {
        if(WSAStartup(0x0101,&data)) { line("CHILD FAIL startup");return 1; }
        sock=socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP);
        if(sock==INVALID_SOCKET || WSAAsyncSelect(sock,FindWindow("USOS ReapTest",""),WM_USER+8,FD_READ)) {
            line("CHILD FAIL socket/window");return 1;
        }
        line("CHILD PASS abandoning startup/socket/timer");return 0;
    }
    wsprintf(record,"PARENT GetWinFlags=%lu",GetWinFlags());line(record);
    CHECK(WSAStartup(0x0101,&data)==0,"parent startup");
    _fmemset(&cls,0,sizeof(cls));proc=MakeProcInstance((FARPROC)events,instance);
    cls.hInstance=instance;cls.lpfnWndProc=(WNDPROC)proc;cls.lpszClassName="USOS ReapTest";
    if(!RegisterClass(&cls)) return 1;
    window=CreateWindow(cls.lpszClassName,"",0,0,0,0,0,NULL,NULL,instance,NULL);
    if(!window || !SetTimer(window,1,100,NULL)) return 1;
    while(GetMessage(&msg,NULL,0,0)) { TranslateMessage(&msg);DispatchMessage(&msg); }
    UnregisterClass(cls.lpszClassName,instance);FreeProcInstance(proc);return failures?1:0;
}
