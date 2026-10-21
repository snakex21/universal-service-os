/* SPDX-License-Identifier: GPL-3.0-or-later
 * Per-session launcher. Shell notifications replace process polling.
 */
#include "common.h"
#include "setup_background.h"
static HWND receiver;
static HHOOK thread_hook;
static HMODULE component;
static DWORD shell_pid;
static UINT taskbar_created;
/* Silent diagnostic evidence for hardware runs: a small bottom-right crop of
 * the primary monitor (where NT 6.0 draws the test-mode text) is written as a
 * BMP beside the session logs. No input, no network, at most 16 files total. */
static BOOL corner_budget(WCHAR *folder){
 WCHAR pattern[MAX_PATH];lstrcpyW(pattern,folder);lstrcatW(pattern,L"corner-*.bmp");
 WIN32_FIND_DATAW item;HANDLE find=FindFirstFileW(pattern,&item);DWORD count=0;
 if(find!=INVALID_HANDLE_VALUE){do count++;while(FindNextFileW(find,&item));FindClose(find);}
 return count<16;
}
static void capture_corner(const WCHAR *stage){
 WCHAR file[MAX_PATH],digits[12];if(!wm_directory(0,file))return;lstrcatW(file,L"logs\\");if(!corner_budget(file))return;
 DWORD session=0;ProcessIdToSessionId(GetCurrentProcessId(),&session);lstrcatW(file,L"corner-s");wm_number(digits,session);lstrcatW(file,digits);
 lstrcatW(file,L"-p");wm_number(digits,GetCurrentProcessId());lstrcatW(file,digits);lstrcatW(file,L"-");lstrcatW(file,stage);lstrcatW(file,L".bmp");
 POINT origin={0,0};MONITORINFO info={sizeof(info)};if(!GetMonitorInfoW(MonitorFromPoint(origin,MONITOR_DEFAULTTOPRIMARY),&info))return;
 int width=info.rcMonitor.right-info.rcMonitor.left,height=info.rcMonitor.bottom-info.rcMonitor.top;if(width>640)width=640;if(height>200)height=200;if(width<1||height<1)return;
 int left=info.rcMonitor.right-width,top=info.rcMonitor.bottom-height;
 BITMAPINFO bits={0};bits.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);bits.bmiHeader.biWidth=width;bits.bmiHeader.biHeight=height;bits.bmiHeader.biPlanes=1;bits.bmiHeader.biBitCount=24;bits.bmiHeader.biCompression=BI_RGB;
 DWORD stride=((DWORD)width*3+3)&~3u,size=stride*(DWORD)height;
 HDC screen=GetDC(0);if(!screen)return;HDC memory=CreateCompatibleDC(screen);void *pixels=0;HBITMAP bitmap=memory?CreateDIBSection(screen,&bits,DIB_RGB_COLORS,&pixels,0,0):0;
 if(bitmap){
  HGDIOBJ old=SelectObject(memory,bitmap);BOOL ok=BitBlt(memory,0,0,width,height,screen,left,top,SRCCOPY|CAPTUREBLT);SelectObject(memory,old);GdiFlush();
  if(ok){
   HANDLE out=CreateFileW(file,GENERIC_WRITE,0,0,CREATE_NEW,FILE_FLAG_OPEN_REPARSE_POINT,0);
   if(out!=INVALID_HANDLE_VALUE){
    BITMAPFILEHEADER header={0};header.bfType=0x4d42;header.bfOffBits=sizeof(header)+sizeof(BITMAPINFOHEADER);header.bfSize=header.bfOffBits+size;DWORD written;
    WriteFile(out,&header,sizeof(header),&written,0);WriteFile(out,&bits.bmiHeader,sizeof(BITMAPINFOHEADER),&written,0);WriteFile(out,pixels,size,&written,0);CloseHandle(out);
   }
  }
  DeleteObject(bitmap);
 }
 if(memory)DeleteDC(memory);ReleaseDC(0,screen);
}
static DWORD WINAPI late_corner(void *unused){(void)unused;Sleep(20000);capture_corner(L"late20s");return 0;}
static void attach_shell(void){
 HWND shell=GetShellWindow();if(!shell)return;DWORD pid=0,thread=GetWindowThreadProcessId(shell,&pid);if(!thread||!pid||pid==shell_pid)return;
 HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);if(!process)return;
 WCHAR path[MAX_PATH],expected[MAX_PATH];DWORD count=MAX_PATH;BOOL ok=QueryFullProcessImageNameW(process,0,path,&count);CloseHandle(process);
 count=GetWindowsDirectoryW(expected,MAX_PATH);if(!count||count>=MAX_PATH-20)return;lstrcatW(expected,L"\\explorer.exe");if(!ok||lstrcmpiW(path,expected))return;
 if(thread_hook){UnhookWindowsHookEx(thread_hook);thread_hook=0;}
 HOOKPROC hook=(HOOKPROC)GetProcAddress(component,"WmHook");if(!hook)return;
 thread_hook=SetWindowsHookExW(WH_CALLWNDPROC,hook,component,thread);if(!thread_hook){wm_log(0,"Cannot attach scoped shell hook; native rendering retained");return;}
 shell_pid=pid;wm_log_code(0,"Shell found; ms since boot=",GetTickCount());capture_corner(L"before");
 DWORD_PTR result=0;SendMessageTimeoutW(shell,WM_NULL,0,0,SMTO_ABORTIFHUNG,5000,&result);
 /* UPDATENOW/ERASENOW: the shell thread repaints synchronously, so the next
  * crop shows our renderer's output rather than the earlier native paint. */
 RedrawWindow(shell,0,0,RDW_INVALIDATE|RDW_ERASE|RDW_ALLCHILDREN|RDW_UPDATENOW|RDW_ERASENOW);wm_log(0,"Hook registered for this session's explorer desktop thread");
 capture_corner(L"after");HANDLE late=CreateThread(0,0,late_corner,0,0,0);if(late)CloseHandle(late);
}
static void CALLBACK shell_event(HWINEVENTHOOK hook,DWORD event,HWND window,LONG object,LONG child,DWORD thread,DWORD time){(void)hook;(void)event;(void)thread;(void)time;if(window&&object==OBJID_WINDOW&&child==CHILDID_SELF)PostMessageW(receiver,WM_APP,0,0);}
static LRESULT CALLBACK window_proc(HWND window,UINT message,WPARAM w,LPARAM l){
 if(message==WM_QUERYENDSESSION){if(shell_pid)capture_corner(L"endsession");return TRUE;}
 if(message==WM_ENDSESSION){if(w)PostQuitMessage(0);return 0;}
 if(message==WM_APP||message==taskbar_created){attach_shell();return 0;}
 if(message==WM_DESTROY){PostQuitMessage(0);return 0;}
 return DefWindowProcW(window,message,w,l);
}
void entry(void){
 if(!wm_supported()||!wm_default_desktop()||wm_visible(0)){wm_log(0,"Not started: OS/testsigning/default desktop/opt-out guard");ExitProcess(0);}
 if(setup_requested()){setup_present();ExitProcess(0);}
 HANDLE mutex=CreateMutexW(0,TRUE,L"Local\\USOSWM.Desktop.Launcher");if(!mutex||GetLastError()==ERROR_ALREADY_EXISTS)ExitProcess(0);
 WCHAR path[MAX_PATH];if(!wm_directory(0,path))ExitProcess(2);lstrcatW(path,L"usoswm-desktop.dll");component=LoadLibraryW(path);if(!component)ExitProcess(3);
 taskbar_created=RegisterWindowMessageW(L"TaskbarCreated");WNDCLASSW type={0};type.lpfnWndProc=window_proc;type.hInstance=GetModuleHandleW(0);type.lpszClassName=L"USOSWM.Session";
 if(!RegisterClassW(&type))ExitProcess(4);receiver=CreateWindowExW(WS_EX_TOOLWINDOW,type.lpszClassName,L"",0,0,0,0,0,0,0,type.hInstance,0);if(!receiver)ExitProcess(5);
 HWINEVENTHOOK events=SetWinEventHook(EVENT_OBJECT_CREATE,EVENT_OBJECT_SHOW,0,shell_event,0,0,WINEVENT_OUTOFCONTEXT|WINEVENT_SKIPOWNPROCESS);if(!events)ExitProcess(6);
 attach_shell();MSG message;while(GetMessageW(&message,0,0,0)>0){TranslateMessage(&message);DispatchMessageW(&message);}
 UnhookWinEvent(events);if(thread_hook)UnhookWindowsHookEx(thread_hook);CloseHandle(mutex);ExitProcess(0);
}
