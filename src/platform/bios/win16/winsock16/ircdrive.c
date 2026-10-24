/* Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later */
/* Normal mIRC trial UI: one fixed close of About, one final inventory.
 * The original client and its script perform all IRC network operations. */
#include <windows.h>
#include <string.h>
#include <direct.h>
#define LOGFILE "C:\\NET\\WIN16\\APPCTL.LOG"
static HFILE log_file=HFILE_ERROR;
static HWND window;
static UINT phase,children;
static BOOL connect_clicked;
static void line(const char FAR *text)
{
    if(log_file==HFILE_ERROR)return;
    _lwrite(log_file,text,(UINT)_fstrlen(text));_lwrite(log_file,"\r\n",2);_lclose(log_file);
    log_file=_lopen(LOGFILE,OF_WRITE|OF_SHARE_DENY_NONE);
    if(log_file!=HFILE_ERROR)_llseek(log_file,0,2);
}
BOOL FAR PASCAL __export child(HWND item,LPARAM unused)
{
    char title[160],kind[64],record[300];(void)unused;
    if(++children>128)return FALSE;
    GetWindowText(item,title,sizeof(title));GetClassName(item,kind,sizeof(kind));
    if(title[0]){wsprintf(record,"child class=%s title=%s",kind,title);line(record);}
    return TRUE;
}
BOOL FAR PASCAL __export inventory(HWND item,LPARAM unused)
{
    char title[160],kind[64],record[300];FARPROC proc;(void)unused;
    GetWindowText(item,title,sizeof(title));GetClassName(item,kind,sizeof(kind));
    wsprintf(record,"window task=%u visible=%u class=%s title=%s",(UINT)GetWindowTask(item),IsWindowVisible(item),kind,title);line(record);
    if(!lstrcmpi(kind,"mIRC")){
        proc=MakeProcInstance((FARPROC)child,(HANDLE)GetWindowWord(window,GWW_HINSTANCE));
        EnumChildWindows(item,(WNDENUMPROC)proc,0);FreeProcInstance(proc);
    }
    return TRUE;
}
BOOL FAR PASCAL __export connect_button(HWND item,LPARAM unused)
{
    char title[100],plain[100],*p,*q;HWND parent;(void)unused;
    GetWindowText(item,title,sizeof(title));q=plain;
    for(p=title;*p;p++)if(*p!='&')*q++=*p;
    *q=0;
    if(lstrcmpi(plain,"Connect to IRC Server"))return TRUE;
    parent=GetParent(item);
    PostMessage(parent,WM_COMMAND,(WPARAM)GetDlgCtrlID(item),MAKELONG((UINT)item,BN_CLICKED));
    line("Normal configured local profile: Connect to IRC Server button");
    connect_clicked=TRUE;return FALSE;
}
LRESULT FAR PASCAL __export events(HWND hwnd,UINT message,WPARAM wp,LPARAM lp)
{
    char record[160];HWND about,options;FARPROC proc;
    if(message==WM_TIMER){
        KillTimer(hwnd,(UINT)wp);
        if(phase==0){
            chdir("C:\\NET\\WIN16\\MIRC");
            wsprintf(record,"original MIRC.EXE WinExec=%u",WinExec("C:\\NET\\WIN16\\MIRC\\MIRC.EXE",SW_SHOWMAXIMIZED));line(record);
            phase=1;SetTimer(hwnd,2,8000,NULL);
        }else if(phase==1){
            about=FindWindow(NULL,"About mIRC");
            if(about){line("Normal evaluation About dialog: standard close, no registration");PostMessage(about,WM_CLOSE,0,0);}
            phase=2;SetTimer(hwnd,3,2000,NULL);
        }else if(phase==2){
            options=FindWindow(NULL,"mIRC Options");
            if(options){
                proc=MakeProcInstance((FARPROC)connect_button,(HANDLE)GetWindowWord(hwnd,GWW_HINSTANCE));
                EnumChildWindows(options,(WNDENUMPROC)proc,0);FreeProcInstance(proc);
                if(!connect_clicked)line("FAIL configured Connect button unavailable");
            }else line("FAIL expected configured Options action checkpoint");
            phase=3;SetTimer(hwnd,4,50000,NULL);
        }else if(phase==3){
            proc=MakeProcInstance((FARPROC)inventory,(HANDLE)GetWindowWord(hwnd,GWW_HINSTANCE));
            EnumWindows((WNDENUMPROC)proc,0);FreeProcInstance(proc);
            line("APPCTL inventory complete");phase=4;
        }
        return 0;
    }
    return DefWindowProc(hwnd,message,wp,lp);
}
int PASCAL WinMain(HANDLE instance,HANDLE previous,LPSTR command,int show)
{
    WNDCLASS cls;FARPROC proc;MSG msg;char record[100];DWORD flags;
    (void)previous;(void)command;(void)show;log_file=_lcreat(LOGFILE,0);
    if(log_file==HFILE_ERROR)return 1;
    flags=GetWinFlags();wsprintf(record,"GetWinFlags=%lu task=%u mode=%s",flags,(UINT)GetCurrentTask(),flags&WF_ENHANCED?"ENHANCED":"OTHER");line(record);
    if(!(flags&WF_ENHANCED))return 1;
    memset(&cls,0,sizeof(cls));proc=MakeProcInstance((FARPROC)events,instance);cls.lpfnWndProc=(WNDPROC)proc;cls.hInstance=instance;cls.lpszClassName="USOS IRC UI";
    if(!RegisterClass(&cls))return 1;
    window=CreateWindow(cls.lpszClassName,"",0,0,0,0,0,NULL,NULL,instance,NULL);
    if(!window||!SetTimer(window,1,100,NULL))return 1;
    while(GetMessage(&msg,NULL,0,0)){TranslateMessage(&msg);DispatchMessage(&msg);}
    return 0;
}
