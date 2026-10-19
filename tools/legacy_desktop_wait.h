/* Bounded desktop readiness notifications, never periodic polling.
 * USOS, GPL-3.0-or-later. USER32/MSAA entry points are optional on old systems.
 * The caller owns its readiness predicate and retains Run after a timeout.
 */
#ifndef USOS_LEGACY_DESKTOP_WAIT_H
#define USOS_LEGACY_DESKTOP_WAIT_H
typedef int (*UsosDesktopReady)(void);
typedef void (CALLBACK *UsosDesktopEventProc)(HANDLE,DWORD,HWND,LONG,LONG,DWORD,DWORD);
static HANDLE usos_desktop_event;
static int (WINAPI *usos_desktop_class)(HWND,LPSTR,int);
static void CALLBACK usos_desktop_changed(HANDLE hook,DWORD event,HWND window,LONG object,LONG child,DWORD thread,DWORD time) {
    char name[64];(void)hook;(void)event;(void)object;(void)child;(void)thread;(void)time;
    if(window&&usos_desktop_class&&usos_desktop_class(window,name,sizeof name)&&
       lstrcmpiA(name,"Shell_TrayWnd")==0)SetEvent(usos_desktop_event);
}
static int usos_wait_desktop(UsosDesktopReady ready,DWORD timeout) {
    HMODULE user,advapi;HANDLE hook=0,changed=0,registry_event=0,process=0,events[2];HKEY key=0;
    DWORD started,elapsed,result,count,pid=0;int ok=0,check=1;MSG message;HWND shell=0;
    HANDLE (WINAPI *set_hook)(DWORD,DWORD,HMODULE,UsosDesktopEventProc,DWORD,DWORD,DWORD);
    BOOL (WINAPI *unhook)(HANDLE);
    HWND (WINAPI *find)(LPCSTR,LPCSTR);
    DWORD (WINAPI *window_pid)(HWND,LPDWORD);
    DWORD (WINAPI *idle)(HANDLE,DWORD);
    DWORD (WINAPI *wait_messages)(DWORD,const HANDLE *,BOOL,DWORD,DWORD);
    BOOL (WINAPI *peek)(LPMSG,HWND,UINT,UINT,UINT);
    BOOL (WINAPI *translate)(const MSG *);
    LRESULT (WINAPI *dispatch)(const MSG *);
    LONG (WINAPI *notify)(HKEY,BOOL,DWORD,HANDLE,BOOL);
    if(ready())return 1;
    started=GetTickCount();user=LoadLibraryA("user32.dll");advapi=LoadLibraryA("advapi32.dll");
    if(!user){if(advapi)FreeLibrary(advapi);return 0;}
#define USOS_DESKTOP_PROC(var,name) var=(void*)GetProcAddress(user,name)
    USOS_DESKTOP_PROC(set_hook,"SetWinEventHook");USOS_DESKTOP_PROC(unhook,"UnhookWinEvent");
    USOS_DESKTOP_PROC(find,"FindWindowA");USOS_DESKTOP_PROC(window_pid,"GetWindowThreadProcessId");
    USOS_DESKTOP_PROC(idle,"WaitForInputIdle");USOS_DESKTOP_PROC(wait_messages,"MsgWaitForMultipleObjects");
    USOS_DESKTOP_PROC(peek,"PeekMessageA");USOS_DESKTOP_PROC(translate,"TranslateMessage");
    USOS_DESKTOP_PROC(dispatch,"DispatchMessageA");USOS_DESKTOP_PROC(usos_desktop_class,"GetClassNameA");
#undef USOS_DESKTOP_PROC
    notify=advapi?(void*)GetProcAddress(advapi,"RegNotifyChangeKeyValue"):0;
    changed=CreateEventA(0,FALSE,FALSE,0);usos_desktop_event=changed;
    if(changed&&set_hook&&unhook&&usos_desktop_class)
        hook=set_hook(0x8000,0x8002,0,usos_desktop_changed,0,0,2); /* out of context, skip self */
    if(notify&&RegOpenKeyExA(HKEY_LOCAL_MACHINE,"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce",0,KEY_NOTIFY|KEY_QUERY_VALUE,&key)==ERROR_SUCCESS) {
        registry_event=CreateEventA(0,FALSE,FALSE,0);
        if(!registry_event||notify(key,TRUE,REG_NOTIFY_CHANGE_NAME|REG_NOTIFY_CHANGE_LAST_SET,registry_event,TRUE)!=ERROR_SUCCESS) {
            if(registry_event)CloseHandle(registry_event);registry_event=0;RegCloseKey(key);key=0;
        }
    }
    /* Legacy fallback: wait on Explorer's input-idle transition, not a timer
     * that repeatedly checks for its taskbar. Progman precedes the taskbar. */
    if(!ready()&&find&&window_pid&&idle&&(shell=find("Progman",0))!=0) {
        window_pid(shell,&pid);if(pid)process=OpenProcess(SYNCHRONIZE|PROCESS_QUERY_INFORMATION,FALSE,pid);
        if(process){elapsed=GetTickCount()-started;if(elapsed<timeout)idle(process,timeout-elapsed);CloseHandle(process);}
    }
    for(;;) {
        if(check&&ready()){ok=1;break;}check=0;
        elapsed=GetTickCount()-started;if(elapsed>=timeout)break;
        count=0;if(hook)events[count++]=changed;if(registry_event)events[count++]=registry_event;
        if(!count||!wait_messages||!peek||!translate||!dispatch)break;
        result=wait_messages(count,events,FALSE,timeout-elapsed,QS_ALLINPUT);
        if(result==WAIT_TIMEOUT||result==WAIT_FAILED)break;
        if(result==WAIT_OBJECT_0+count) {
            while(peek(&message,0,0,0,PM_REMOVE)){translate(&message);dispatch(&message);}
        } else if(registry_event&&result==WAIT_OBJECT_0+count-1) {
            if(notify(key,TRUE,REG_NOTIFY_CHANGE_NAME|REG_NOTIFY_CHANGE_LAST_SET,registry_event,TRUE)!=ERROR_SUCCESS) {
                CloseHandle(registry_event);registry_event=0;RegCloseKey(key);key=0;
            }
            check=1;
        } else if(result<count)check=1;
        /* Recheck only after a window/registry notification. The fixed
         * deadline is not renewed by activity and never triggers a retry. */
    }
    if(hook)unhook(hook);usos_desktop_event=0;
    if(changed)CloseHandle(changed);if(registry_event)CloseHandle(registry_event);if(key)RegCloseKey(key);
    if(advapi)FreeLibrary(advapi);FreeLibrary(user);return ok;
}
#endif
