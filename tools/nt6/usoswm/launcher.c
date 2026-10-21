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
/* Silent diagnostic evidence for hardware runs (no input, no network):
 * a 24-bit BMP of the whole virtual screen (all monitors) beside the session
 * logs, at most 8 files in total, plus a text record of the display mode and
 * every visible top-level window overlapping the top band of the screen. */
typedef struct {char text[1024];DWORD length;} WmLine;
static void line_text(WmLine *line,const char *text){while(*text&&line->length<sizeof(line->text)-1)line->text[line->length++]=*text++;line->text[line->length]=0;}
static void line_wide(WmLine *line,const WCHAR *text){
 char utf8[384];int n=WideCharToMultiByte(CP_UTF8,0,text,-1,utf8,sizeof(utf8),0,0);if(n<=0)utf8[0]=0;else utf8[sizeof(utf8)-1]=0;
 line_text(line,"\"");line_text(line,utf8);line_text(line,"\"");
}
static void line_int(WmLine *line,LONG value){
 WCHAR digits[12];char text[14];DWORD i=0;if(value<0){text[i++]='-';value=-value;}wm_number(digits,(DWORD)value);
 for(DWORD j=0;digits[j]&&i<sizeof(text)-1;j++)text[i++]=(char)digits[j];text[i]=0;line_text(line,text);
}
static void line_hex(WmLine *line,DWORD value){char text[9];for(DWORD i=0;i<8;i++)text[i]="0123456789ABCDEF"[(value>>(28-4*i))&15];text[8]=0;line_text(line,text);}
static void line_rect(WmLine *line,const RECT *r){line_int(line,r->left);line_text(line,",");line_int(line,r->top);line_text(line,",");line_int(line,r->right);line_text(line,",");line_int(line,r->bottom);
 line_text(line," (");line_int(line,r->right-r->left);line_text(line,"x");line_int(line,r->bottom-r->top);line_text(line,")");}
static BOOL capture_budget(WCHAR *folder){
 WCHAR pattern[MAX_PATH];lstrcpyW(pattern,folder);lstrcatW(pattern,L"screen-*.bmp");
 WIN32_FIND_DATAW item;HANDLE find=FindFirstFileW(pattern,&item);DWORD count=0;
 if(find!=INVALID_HANDLE_VALUE){do count++;while(FindNextFileW(find,&item));FindClose(find);}
 return count<8;
}
static BOOL CALLBACK log_monitor(HMONITOR monitor,HDC dc,RECT *rect,LPARAM stage){
 (void)dc;(void)rect;MONITORINFOEXW info;info.cbSize=sizeof(info);if(!GetMonitorInfoW(monitor,(MONITORINFO*)&info))return TRUE;
 DEVMODEW mode;memset(&mode,0,sizeof(mode));mode.dmSize=sizeof(mode);BOOL known=EnumDisplaySettingsW(info.szDevice,ENUM_CURRENT_SETTINGS,&mode);
 WmLine line={{0},0};line_text(&line,(const char*)stage);line_text(&line," monitor ");line_wide(&line,info.szDevice);line_text(&line," rect=");line_rect(&line,&info.rcMonitor);
 line_text(&line," work=");line_rect(&line,&info.rcWork);if(info.dwFlags&MONITORINFOF_PRIMARY)line_text(&line," primary");
 if(known){line_text(&line," mode=");line_int(&line,mode.dmPelsWidth);line_text(&line,"x");line_int(&line,mode.dmPelsHeight);line_text(&line,"x");line_int(&line,mode.dmBitsPerPel);line_text(&line,"@");line_int(&line,mode.dmDisplayFrequency);
  line_text(&line," pos=");line_int(&line,mode.dmPosition.x);line_text(&line,",");line_int(&line,mode.dmPosition.y);}
 wm_log(0,line.text);return TRUE;
}
typedef struct {const char *stage;RECT band;DWORD count;} WmBand;
static BOOL CALLBACK log_window(HWND window,LPARAM param){
 WmBand *band=(WmBand*)param;RECT r,overlap;if(!IsWindowVisible(window)||!GetWindowRect(window,&r)||!IntersectRect(&overlap,&r,&band->band))return TRUE;
 if(++band->count>40)return FALSE;
 WCHAR name[96]={0},title[96]={0},image[MAX_PATH]={0};GetClassNameW(window,name,96);GetWindowTextW(window,title,96);
 DWORD pid=0;GetWindowThreadProcessId(window,&pid);HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);
 if(process){DWORD size=MAX_PATH;if(!QueryFullProcessImageNameW(process,0,image,&size))image[0]=0;CloseHandle(process);}
 LONG style=GetWindowLongW(window,GWL_STYLE),extended=GetWindowLongW(window,GWL_EXSTYLE);
 WmLine line={{0},0};line_text(&line,band->stage);line_text(&line," window class=");line_wide(&line,name);line_text(&line," title=");line_wide(&line,title);
 line_text(&line," rect=");line_rect(&line,&r);line_text(&line," pid=");line_int(&line,(LONG)pid);line_text(&line," exe=");line_wide(&line,image);line_text(&line," style=");
 line_hex(&line,(DWORD)style);line_text(&line," exstyle=");line_hex(&line,(DWORD)extended);wm_log(0,line.text);return TRUE;
}
static void log_screen(const char *stage){
 RECT virtual_screen={GetSystemMetrics(SM_XVIRTUALSCREEN),GetSystemMetrics(SM_YVIRTUALSCREEN),0,0};
 virtual_screen.right=virtual_screen.left+GetSystemMetrics(SM_CXVIRTUALSCREEN);virtual_screen.bottom=virtual_screen.top+GetSystemMetrics(SM_CYVIRTUALSCREEN);
 WmLine line={{0},0};line_text(&line,stage);line_text(&line," virtual screen=");line_rect(&line,&virtual_screen);line_text(&line," monitors=");line_int(&line,GetSystemMetrics(SM_CMONITORS));
 HDC screen=GetDC(0);if(screen){line_text(&line," dc=");line_int(&line,GetDeviceCaps(screen,HORZRES));line_text(&line,"x");line_int(&line,GetDeviceCaps(screen,VERTRES));line_text(&line,"x");line_int(&line,GetDeviceCaps(screen,BITSPIXEL));ReleaseDC(0,screen);}
 line_text(&line," ms since boot=");line_int(&line,(LONG)GetTickCount());wm_log(0,line.text);
 EnumDisplayMonitors(0,0,log_monitor,(LPARAM)stage);
 /* Top band: the reported text is at the top of the X470 screen. The
  * band covers the top eighth (at least 96 px) of the virtual screen. */
 LONG height=(virtual_screen.bottom-virtual_screen.top)/8;if(height<96)height=96;
 WmBand band={stage,{virtual_screen.left,virtual_screen.top,virtual_screen.right,virtual_screen.top+height},0};
 EnumWindows(log_window,(LPARAM)&band);
 if(band.count>40)wm_log(0,"  (window list truncated at 40)");
}
static void capture_screen(const WCHAR *stage,const char *label){
 log_screen(label);
 WCHAR file[MAX_PATH],digits[12];if(!wm_directory(0,file))return;lstrcatW(file,L"logs\\");if(!capture_budget(file))return;
 DWORD session=0;ProcessIdToSessionId(GetCurrentProcessId(),&session);lstrcatW(file,L"screen-s");wm_number(digits,session);lstrcatW(file,digits);
 lstrcatW(file,L"-p");wm_number(digits,GetCurrentProcessId());lstrcatW(file,digits);lstrcatW(file,L"-");lstrcatW(file,stage);lstrcatW(file,L".bmp");
 int left=GetSystemMetrics(SM_XVIRTUALSCREEN),top=GetSystemMetrics(SM_YVIRTUALSCREEN),width=GetSystemMetrics(SM_CXVIRTUALSCREEN),height=GetSystemMetrics(SM_CYVIRTUALSCREEN);
 if(width<1||height<1||width>16384||height>16384)return;
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
  }else wm_log_code(0,"Screen capture BitBlt failed=",GetLastError());
  DeleteObject(bitmap);
 }
 if(memory)DeleteDC(memory);ReleaseDC(0,screen);
}
static DWORD WINAPI late_capture(void *unused){(void)unused;Sleep(20000);capture_screen(L"late20s","[late20s]");return 0;}
static void attach_shell(void){
 HWND shell=GetShellWindow();if(!shell)return;DWORD pid=0,thread=GetWindowThreadProcessId(shell,&pid);if(!thread||!pid||pid==shell_pid)return;
 HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);if(!process)return;
 WCHAR path[MAX_PATH],expected[MAX_PATH];DWORD count=MAX_PATH;BOOL ok=QueryFullProcessImageNameW(process,0,path,&count);CloseHandle(process);
 count=GetWindowsDirectoryW(expected,MAX_PATH);if(!count||count>=MAX_PATH-20)return;lstrcatW(expected,L"\\explorer.exe");if(!ok||lstrcmpiW(path,expected))return;
 if(thread_hook){UnhookWindowsHookEx(thread_hook);thread_hook=0;}
 HOOKPROC hook=(HOOKPROC)GetProcAddress(component,"WmHook");if(!hook)return;
 thread_hook=SetWindowsHookExW(WH_CALLWNDPROC,hook,component,thread);if(!thread_hook){wm_log(0,"Cannot attach scoped shell hook; native rendering retained");return;}
 shell_pid=pid;wm_log_code(0,"Shell found; ms since boot=",GetTickCount());capture_screen(L"before","[before]");
 DWORD_PTR result=0;SendMessageTimeoutW(shell,WM_NULL,0,0,SMTO_ABORTIFHUNG,5000,&result);
 /* UPDATENOW/ERASENOW: the shell thread repaints synchronously, so the next
  * crop shows our renderer's output rather than the earlier native paint. */
 RedrawWindow(shell,0,0,RDW_INVALIDATE|RDW_ERASE|RDW_ALLCHILDREN|RDW_UPDATENOW|RDW_ERASENOW);wm_log(0,"Hook registered for this session's explorer desktop thread");
 capture_screen(L"after","[after]");HANDLE late=CreateThread(0,0,late_capture,0,0,0);if(late)CloseHandle(late);
}
static void CALLBACK shell_event(HWINEVENTHOOK hook,DWORD event,HWND window,LONG object,LONG child,DWORD thread,DWORD time){(void)hook;(void)event;(void)thread;(void)time;if(window&&object==OBJID_WINDOW&&child==CHILDID_SELF)PostMessageW(receiver,WM_APP,0,0);}
static LRESULT CALLBACK window_proc(HWND window,UINT message,WPARAM w,LPARAM l){
 if(message==WM_QUERYENDSESSION){if(shell_pid)capture_screen(L"endsession","[endsession]");return TRUE;}
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
