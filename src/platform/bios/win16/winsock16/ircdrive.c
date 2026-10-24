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
static HWND channel_edit,channel_join;
static int join_top;
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
BOOL FAR PASCAL __export channel_controls(HWND item,LPARAM unused)
{
    char title[100],plain[100],kind[64],record[240],*p,*q;RECT rect;(void)unused;
    GetWindowText(item,title,sizeof(title));GetClassName(item,kind,sizeof(kind));
    wsprintf(record,"channel child id=%u class=%s title=%s",(UINT)GetDlgCtrlID(item),kind,title);line(record);
    if(!lstrcmpi(kind,"Edit")&&!channel_edit)channel_edit=item;
    q=plain;for(p=title;*p;p++)if(*p!='&')*q++=*p;*q=0;
    if(!lstrcmpi(kind,"Button")&&!lstrcmpi(plain,"Join")){
        GetWindowRect(item,&rect);
        if(!channel_join||rect.top<join_top){channel_join=item;join_top=rect.top;}
    }
    return TRUE;
}
LRESULT FAR PASCAL __export events(HWND hwnd,UINT message,WPARAM wp,LPARAM lp)
{
    char record[160],entered[64];const char *key;HWND about,options,channels;FARPROC proc;
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
            phase=3;SetTimer(hwnd,4,20000,NULL);
        }else if(phase==3){
            channels=FindWindow(NULL,"mIRC Channels Folder");
            if(channels){
                proc=MakeProcInstance((FARPROC)channel_controls,(HANDLE)GetWindowWord(hwnd,GWW_HINSTANCE));
                EnumChildWindows(channels,(WNDENUMPROC)proc,0);FreeProcInstance(proc);
                if(channel_edit&&channel_join){
                    for(key="#usos-test";*key;key++)SendMessage(channel_edit,WM_CHAR,(WPARAM)(BYTE)*key,1L);
                    line("Normal Channels Folder action: type #usos-test");
                }else line("FAIL normal channel controls unavailable");
            }else line("FAIL expected Channels Folder action checkpoint");
            phase=4;SetTimer(hwnd,5,1000,NULL);
        }else if(phase==4){
            if(channel_edit&&channel_join){
                GetWindowText(channel_edit,entered,sizeof(entered));
                wsprintf(record,"Normal channel keyboard input confirmed: %s",entered);line(record);
                if(!lstrcmp(entered,"#usos-test")){
                    PostMessage(GetParent(channel_join),WM_COMMAND,(WPARAM)GetDlgCtrlID(channel_join),MAKELONG((UINT)channel_join,BN_CLICKED));
                    line("Normal Channels Folder action: press Join");
                }else line("FAIL channel input text did not match, Join not issued");
            }
            phase=5;SetTimer(hwnd,6,29000,NULL);
        }else if(phase==5){
            proc=MakeProcInstance((FARPROC)inventory,(HANDLE)GetWindowWord(hwnd,GWW_HINSTANCE));
            EnumWindows((WNDENUMPROC)proc,0);FreeProcInstance(proc);
            line("APPCTL inventory complete");phase=6;
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
