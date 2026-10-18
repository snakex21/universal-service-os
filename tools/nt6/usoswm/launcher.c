/* SPDX-License-Identifier: GPL-3.0-or-later
 * Per-session launcher. Shell notifications replace process polling.
 */
#include "common.h"
static HWND receiver;
static HHOOK thread_hook;
static HMODULE component;
static DWORD shell_pid;
static UINT taskbar_created;
static void attach_shell(void){
 HWND shell=GetShellWindow();if(!shell)return;DWORD pid=0,thread=GetWindowThreadProcessId(shell,&pid);if(!thread||!pid||pid==shell_pid)return;
 HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);if(!process)return;
 WCHAR path[MAX_PATH],expected[MAX_PATH];DWORD count=MAX_PATH;BOOL ok=QueryFullProcessImageNameW(process,0,path,&count);CloseHandle(process);
 count=GetWindowsDirectoryW(expected,MAX_PATH);if(!count||count>=MAX_PATH-20)return;lstrcatW(expected,L"\\explorer.exe");if(!ok||lstrcmpiW(path,expected))return;
 if(thread_hook){UnhookWindowsHookEx(thread_hook);thread_hook=0;}
 HOOKPROC hook=(HOOKPROC)GetProcAddress(component,"WmHook");if(!hook)return;
 thread_hook=SetWindowsHookExW(WH_CALLWNDPROC,hook,component,thread);if(!thread_hook){wm_log(0,"Cannot attach scoped shell hook; native rendering retained");return;}
 shell_pid=pid;DWORD_PTR result=0;SendMessageTimeoutW(shell,WM_NULL,0,0,SMTO_ABORTIFHUNG,5000,&result);RedrawWindow(shell,0,0,RDW_INVALIDATE|RDW_ERASE|RDW_ALLCHILDREN);wm_log(0,"Hook registered for this session's explorer desktop thread");
}
static void CALLBACK shell_event(HWINEVENTHOOK hook,DWORD event,HWND window,LONG object,LONG child,DWORD thread,DWORD time){(void)hook;(void)event;(void)thread;(void)time;if(window&&object==OBJID_WINDOW&&child==CHILDID_SELF)PostMessageW(receiver,WM_APP,0,0);}
static LRESULT CALLBACK window_proc(HWND window,UINT message,WPARAM w,LPARAM l){
 if(message==WM_QUERYENDSESSION)return TRUE;
 if(message==WM_ENDSESSION){if(w)PostQuitMessage(0);return 0;}
 if(message==WM_APP||message==taskbar_created){attach_shell();return 0;}
 if(message==WM_DESTROY){PostQuitMessage(0);return 0;}
 return DefWindowProcW(window,message,w,l);
}
void entry(void){
 if(!wm_supported()||!wm_default_desktop()||wm_visible(0)){wm_log(0,"Not started: OS/testsigning/default desktop/opt-out guard");ExitProcess(0);}
 HANDLE mutex=CreateMutexW(0,TRUE,L"Local\\USOSWM.Desktop.Launcher");if(!mutex||GetLastError()==ERROR_ALREADY_EXISTS)ExitProcess(0);
 WCHAR path[MAX_PATH];if(!wm_directory(0,path))ExitProcess(2);lstrcatW(path,L"usoswm-desktop.dll");component=LoadLibraryW(path);if(!component)ExitProcess(3);
 taskbar_created=RegisterWindowMessageW(L"TaskbarCreated");WNDCLASSW type={0};type.lpfnWndProc=window_proc;type.hInstance=GetModuleHandleW(0);type.lpszClassName=L"USOSWM.Session";
 if(!RegisterClassW(&type))ExitProcess(4);receiver=CreateWindowExW(WS_EX_TOOLWINDOW,type.lpszClassName,L"",0,0,0,0,0,0,0,type.hInstance,0);if(!receiver)ExitProcess(5);
 HWINEVENTHOOK events=SetWinEventHook(EVENT_OBJECT_CREATE,EVENT_OBJECT_SHOW,0,shell_event,0,0,WINEVENT_OUTOFCONTEXT|WINEVENT_SKIPOWNPROCESS);if(!events)ExitProcess(6);
 attach_shell();MSG message;while(GetMessageW(&message,0,0,0)>0){TranslateMessage(&message);DispatchMessageW(&message);}
 UnhookWinEvent(events);if(thread_hook)UnhookWindowsHookEx(thread_hook);CloseHandle(mutex);ExitProcess(0);
}
