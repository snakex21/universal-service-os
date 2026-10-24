/* Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later */
/* Normal mIRC5.91 Win16 wizard automation, only on a disposable QEMU COW.
 * Fixed UI actions, no progress polling. No registration data or app patch. */
#include <windows.h>
#include <string.h>
#include <direct.h>

#define CONFIG "C:\\NET\\WIN16\\APPCTL.INI"
#define LOGFILE "C:\\NET\\WIN16\\APPCTL.LOG"
static HFILE log_file=HFILE_ERROR;
static HWND window;
static UINT phase;

static void line(const char FAR *text)
{
    if(log_file==HFILE_ERROR)return;
    _lwrite(log_file,text,(UINT)_fstrlen(text));_lwrite(log_file,"\r\n",2);_lclose(log_file);
    log_file=_lopen(LOGFILE,OF_WRITE|OF_SHARE_DENY_NONE);
    if(log_file!=HFILE_ERROR)_llseek(log_file,0,2);
}

BOOL FAR PASCAL __export inventory(HWND item,LPARAM unused)
{
    char title[160],kind[64],record[300];
    (void)unused;GetWindowText(item,title,sizeof(title));GetClassName(item,kind,sizeof(kind));
    wsprintf(record,"window task=%u visible=%u class=%s title=%s",(UINT)GetWindowTask(item),IsWindowVisible(item),kind,title);
    line(record);return TRUE;
}

static int click(const char *expected)
{
    HWND dialog,button;char caption[80],record[160];
    dialog=FindWindow(NULL,"mIRC v5.91 16bit Installation");
    if(!dialog){line("FAIL expected mIRC Installer dialog");return 0;}
    button=GetDlgItem(dialog,1);GetWindowText(button,caption,sizeof(caption));
    wsprintf(record,"action phase=%u button=%s expected=%s",phase,caption,expected);line(record);
    if(lstrcmpi(caption,expected)){line("FAIL wizard action precondition");return 0;}
    if(phase==3){
        SendDlgItemMessage(dialog,158,BM_SETCHECK,0,0); /* no Program Manager shortcut */
        SendDlgItemMessage(dialog,156,BM_SETCHECK,0,0);
        SendDlgItemMessage(dialog,157,BM_SETCHECK,0,0);
    }
    if(phase==4){
        SendDlgItemMessage(dialog,183,BM_SETCHECK,0,0); /* no help/auto-launch */
        SendDlgItemMessage(dialog,184,BM_SETCHECK,0,0);
    }
    PostMessage(dialog,WM_COMMAND,1,MAKELONG((UINT)button,BN_CLICKED));
    return 1;
}

LRESULT FAR PASCAL __export events(HWND hwnd,UINT message,WPARAM wp,LPARAM lp)
{
    char command[240],record[300];UINT result;FARPROC enumerator;
    if(message==WM_TIMER){
        KillTimer(hwnd,(UINT)wp);
        if(phase==0){
            GetPrivateProfileString("test","command1","",command,sizeof(command),CONFIG);
            if(lstrcmpi(command,"C:\\NET\\WIN16\\MIRCSFX.EXE")){line("FAIL fixed original installer command required");return 0;}
            chdir("C:\\NET\\WIN16");result=WinExec(command,SW_SHOWNORMAL);
            wsprintf(record,"normal installer WinExec=%u",result);line(record);
            phase=1;SetTimer(hwnd,2,3000,NULL);
        }else if(phase==1){if(click("&Next >")){phase=2;SetTimer(hwnd,3,3000,NULL);}}
        else if(phase==2){if(click("&Yes")){phase=3;SetTimer(hwnd,4,3000,NULL);}}
        else if(phase==3){if(click("&Install")){phase=4;SetTimer(hwnd,5,20000,NULL);}}
        else if(phase==4){if(click("&Finish")){line("SETUP normal wizard completed; evaluation, no registration data");phase=5;SetTimer(hwnd,6,5000,NULL);}}
        else if(phase==5){
            enumerator=MakeProcInstance((FARPROC)inventory,(HANDLE)GetWindowWord(hwnd,GWW_HINSTANCE));
            EnumWindows((WNDENUMPROC)enumerator,0);FreeProcInstance(enumerator);
            line("APPCTL inventory complete");phase=6;
        }
        return 0;
    }
    return DefWindowProc(hwnd,message,wp,lp);
}

int PASCAL WinMain(HANDLE instance,HANDLE previous,LPSTR command,int show)
{
    WNDCLASS cls;FARPROC proc;MSG msg;char record[120];DWORD flags;
    (void)previous;(void)command;(void)show;log_file=_lcreat(LOGFILE,0);
    if(log_file==HFILE_ERROR)return 1;
    flags=GetWinFlags();wsprintf(record,"GetWinFlags=%lu task=%u mode=%s",flags,(UINT)GetCurrentTask(),flags&WF_ENHANCED?"ENHANCED":"OTHER");line(record);
    if(!(flags&WF_ENHANCED)){line("FAIL enhanced mode required");return 1;}
    memset(&cls,0,sizeof(cls));proc=MakeProcInstance((FARPROC)events,instance);
    cls.lpfnWndProc=(WNDPROC)proc;cls.hInstance=instance;cls.lpszClassName="USOS IRC Setup";
    if(!RegisterClass(&cls))return 1;
    window=CreateWindow(cls.lpszClassName,"",0,0,0,0,0,NULL,NULL,instance,NULL);
    if(!window||!SetTimer(window,1,100,NULL))return 1;
    while(GetMessage(&msg,NULL,0,0)){TranslateMessage(&msg);DispatchMessage(&msg);}
    DestroyWindow(window);UnregisterClass(cls.lpszClassName,instance);FreeProcInstance(proc);return 0;
}
