/* Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later */
/* QEMU application fixture: log the actual mode before launching original
 * applications. One delayed window inventory is evidence, not a page verdict.
 * Configuration and log stay in this fixture's C:\NET\WIN16 directory. */
#include <windows.h>
#include <string.h>
#include <direct.h>

#define CONFIG "C:\\NET\\WIN16\\APPCTL.INI"
#define LOGFILE "C:\\NET\\WIN16\\APPCTL.LOG"
static HFILE log_file=HFILE_ERROR;
static HWND window;
static unsigned int launched;
static char button_wanted[80];
static HWND action_button;

static void line(const char FAR *value)
{
    HFILE file;
    if(log_file==HFILE_ERROR) return;
    _lwrite(log_file,value,(UINT)_fstrlen(value));
    _lwrite(log_file,"\r\n",2);
    _lclose(log_file);
    file=_lopen(LOGFILE,OF_WRITE|OF_SHARE_DENY_NONE);
    log_file=file;
    if(file!=HFILE_ERROR) _llseek(file,0,2);
}

BOOL FAR PASCAL __export inventory(HWND item,LPARAM unused)
{
    char title[160],kind[64],module[160],record[450];
    (void)unused;
    GetWindowText(item,title,sizeof(title));
    GetClassName(item,kind,sizeof(kind));
    GetModuleFileName((HANDLE)GetWindowWord(item,GWW_HINSTANCE),module,sizeof(module));
    wsprintf(record,"window task=%u visible=%u class=%s title=%s module=%s",
             (UINT)GetWindowTask(item),IsWindowVisible(item),kind,title,module);
    line(record);return TRUE;
}

BOOL FAR PASCAL __export find_button(HWND item,LPARAM unused)
{
    char caption[100],plain[100],kind[30];int i,j;
    (void)unused;
    GetClassName(item,kind,sizeof(kind));
    if(lstrcmpi(kind,"Button")) return TRUE;
    GetWindowText(item,caption,sizeof(caption));
    for(i=j=0;caption[i] && j<99;i++) if(caption[i]!='&') plain[j++]=caption[i];
    plain[j]=0;
    if(!lstrcmpi(plain,button_wanted) && IsWindowEnabled(item)) { action_button=item;return FALSE; }
    return TRUE;
}

LRESULT FAR PASCAL __export events(HWND hwnd,UINT message,WPARAM wp,LPARAM lp)
{
    char command[240],directory[240],name[16],record[300],dialog_title[80],*slash;
    UINT result;
    int i;
    FARPROC enumerator;
    HWND dialog;
    if(message==WM_TIMER) {
        KillTimer(hwnd,(UINT)wp);
        if(wp>=3 && wp<=5) {
            i=(int)wp-2;
            wsprintf(name,"dialog%d",i);
            GetPrivateProfileString("test",name,"",dialog_title,sizeof(dialog_title),CONFIG);
            wsprintf(name,"button%d",i);
            GetPrivateProfileString("test",name,"",button_wanted,sizeof(button_wanted),CONFIG);
            if(dialog_title[0] && button_wanted[0]) {
                dialog=FindWindow(NULL,dialog_title);action_button=NULL;
                if(dialog) {
                    enumerator=MakeProcInstance((FARPROC)find_button,(HANDLE)GetWindowWord(hwnd,GWW_HINSTANCE));
                    EnumChildWindows(dialog,(WNDENUMPROC)enumerator,0);FreeProcInstance(enumerator);
                }
                wsprintf(record,"one-shot action%d dialog=%s button=%s found=%u",i,dialog_title,button_wanted,action_button!=NULL);line(record);
                if(action_button) SendMessage(dialog,WM_COMMAND,GetDlgCtrlID(action_button),MAKELONG((WORD)action_button,BN_CLICKED));
            }
            return 0;
        }
        if(!launched) {
            launched=1;
            for(i=1;i<=2;i++) {
                wsprintf(name,"command%d",i);
                GetPrivateProfileString("test",name,"",command,sizeof(command),CONFIG);
                if(!command[0]) continue;
                wsprintf(record,"launch%d=%s",i,command);line(record);
                /* Each original application's INI/cache belongs beside it.
                 * All fixture commands use short paths without spaces. */
                strcpy(directory,command);
                slash=strchr(directory,' ');if(slash) *slash=0;
                slash=strrchr(directory,'\\');if(slash) *slash=0;
                if(chdir(directory)) { line("FAIL application directory");continue; }
                result=WinExec(command,SW_SHOWMAXIMIZED);
                wsprintf(record,"WinExec%d=%u",i,result);line(record);
                chdir("C:\\NET\\WIN16");
            }
            SetTimer(hwnd,2,60000,NULL);
            SetTimer(hwnd,3,5000,NULL);SetTimer(hwnd,4,20000,NULL);SetTimer(hwnd,5,35000,NULL);
        } else {
            enumerator=MakeProcInstance((FARPROC)inventory,
                                       (HANDLE)GetWindowWord(hwnd,GWW_HINSTANCE));
            line("ONE final window inventory (rendering requires screenshot and PCAP)");
            EnumWindows((WNDENUMPROC)enumerator,0);
            FreeProcInstance(enumerator);
            line("APPCTL inventory complete");
        }
        return 0;
    }
    return DefWindowProc(hwnd,message,wp,lp);
}

int PASCAL WinMain(HANDLE instance,HANDLE previous,LPSTR command,int show)
{
    WNDCLASS cls;FARPROC proc;MSG msg;char record[100];DWORD flags;
    (void)previous;(void)command;(void)show;
    log_file=_lcreat(LOGFILE,0);
    if(log_file==HFILE_ERROR) return 1;
    flags=GetWinFlags();
    wsprintf(record,"GetWinFlags=%lu task=%u mode=%s",flags,(UINT)GetCurrentTask(),
             flags&WF_ENHANCED?"ENHANCED":flags&WF_STANDARD?"STANDARD":"OTHER");
    line(record);
    if(!(flags&WF_ENHANCED)) { line("FAIL enhanced mode required");_lclose(log_file);return 1; }
    memset(&cls,0,sizeof(cls));
    proc=MakeProcInstance((FARPROC)events,instance);
    cls.lpfnWndProc=(WNDPROC)proc;cls.hInstance=instance;cls.lpszClassName="USOS App Fixture";
    if(!RegisterClass(&cls)) return 1;
    window=CreateWindow(cls.lpszClassName,"",0,0,0,0,0,NULL,NULL,instance,NULL);
    if(!window || !SetTimer(window,1,100,NULL)) return 1;
    while(GetMessage(&msg,NULL,0,0)) { TranslateMessage(&msg);DispatchMessage(&msg); }
    DestroyWindow(window);UnregisterClass(cls.lpszClassName,instance);FreeProcInstance(proc);
    if(log_file!=HFILE_ERROR) _lclose(log_file);
    return 0;
}
