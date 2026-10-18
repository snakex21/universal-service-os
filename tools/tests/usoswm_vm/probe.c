/* SPDX-License-Identifier: GPL-3.0-or-later
 * Disposable VM evidence harness; no product or security patches.
 */
#define UNICODE
#define _UNICODE
#define _WIN32_WINNT 0x0600
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <uxtheme.h>
#include <stddef.h>
void *memcpy(void *d,const void *s,size_t n){BYTE *a=d;const BYTE *b=s;while(n--)*a++=*b++;return d;}
void *memset(void *d,int c,size_t n){BYTE *a=d;while(n--)*a++=(BYTE)c;return d;}
static HANDLE port,record=INVALID_HANDLE_VALUE;
static void send(const char *s){DWORD n;if(record!=INVALID_HANDLE_VALUE){WriteFile(record,s,lstrlenA(s),&n,0);FlushFileBuffers(record);}if(port!=INVALID_HANDLE_VALUE)WriteFile(port,s,lstrlenA(s),&n,0);}
static void hex(const char *name,DWORD value){char text[10];for(unsigned i=0;i<8;i++)text[i]="0123456789ABCDEF"[(value>>(28-4*i))&15];text[8]='\n';text[9]=0;send(name);send(text);}
static void event(const char *s){send(s);send("\n");char ack;DWORD n;ReadFile(port,&ack,1,&n,0);}
static DWORD last_pid;
static DWORD launch(WCHAR *s,BOOL wait){STARTUPINFOW si={sizeof(si)};PROCESS_INFORMATION pi={0};if(!CreateProcessW(0,s,0,0,FALSE,CREATE_NO_WINDOW,0,0,&si,&pi))return GetLastError();last_pid=pi.dwProcessId;DWORD result=0;if(wait){DWORD status=WaitForSingleObject(pi.hProcess,60000);if(status!=WAIT_OBJECT_0)result=status==WAIT_TIMEOUT?ERROR_TIMEOUT:GetLastError();else if(!GetExitCodeProcess(pi.hProcess,&result))result=GetLastError();}CloseHandle(pi.hProcess);CloseHandle(pi.hThread);return result;}
static BOOL CALLBACK close_owned(HWND window,LPARAM pid){DWORD actual=0;GetWindowThreadProcessId(window,&actual);if(actual==(DWORD)pid)PostMessageW(window,WM_CLOSE,0,0);return TRUE;}
static void redraw(void){HWND shell=GetShellWindow();if(shell)RedrawWindow(shell,0,0,RDW_ERASE|RDW_INVALIDATE|RDW_ALLCHILDREN);Sleep(3000);}
static BOOL post_run(void){const WCHAR *text=GetCommandLineW();for(;*text;text++)if(text[0]==L'-'&&text[1]==L'-'&&text[2]==L'p'&&text[3]==L'o'&&text[4]==L's'&&text[5]==L't')return TRUE;return FALSE;}
typedef struct{HWND window,apply;} ThemeDialog;
static BOOL CALLBACK theme_child(HWND window,LPARAM value){ThemeDialog *dialog=(ThemeDialog*)value;if(GetDlgCtrlID(window)==0x3021&&IsWindowVisible(window)&&IsWindowEnabled(window))dialog->apply=window;return TRUE;}
static BOOL CALLBACK theme_window(HWND window,LPARAM value){ThemeDialog candidate={window,0};WCHAR cls[32];GetClassNameW(window,cls,32);if(IsWindowVisible(window)&&!lstrcmpW(cls,L"#32770")){EnumChildWindows(window,theme_child,(LPARAM)&candidate);if(candidate.apply)*(ThemeDialog*)value=candidate;}return TRUE;}
static void change_theme(void){
 WCHAR before[MAX_PATH]={0},after[MAX_PATH]={0};HRESULT first=GetCurrentThemeName(before,MAX_PATH,0,0,0,0);BOOL was_active=IsThemeActive();
 const char classic[]="[Theme]\r\nDisplayName=USOS VM Classic\r\n[Control Panel\\Desktop]\r\nWallpaper=\r\nWallpaperStyle=0\r\nTileWallpaper=0\r\n[VisualStyles]\r\nPath=\r\n[MasterThemeSelector]\r\nMTSM=DABJDKT\r\n";
 const char basic[]="[Theme]\r\nDisplayName=USOS VM Basic\r\n[Control Panel\\Desktop]\r\nWallpaper=\r\nWallpaperStyle=0\r\nTileWallpaper=0\r\n[VisualStyles]\r\nPath=%SystemRoot%\\resources\\Themes\\Aero\\Aero.msstyles\r\nColorStyle=NormalColor\r\nSize=NormalSize\r\n[MasterThemeSelector]\r\nMTSM=DABJDKT\r\n";
 const char *text=was_active?classic:basic;HANDLE file=CreateFileW(L"C:\\USOS\\WMTEST\\change.theme",GENERIC_WRITE,0,0,CREATE_ALWAYS,0,0);if(file==INVALID_HANDLE_VALUE){send("WM_THEME_FILE_FAILED\n");return;}
 DWORD written;BOOL ok=WriteFile(file,text,lstrlenA(text),&written,0);CloseHandle(file);if(!ok)return;
 HINSTANCE opened=ShellExecuteW(0,L"open",L"C:\\USOS\\WMTEST\\change.theme",0,0,SW_SHOWNORMAL);if((UINT_PTR)opened<=32){send("WM_THEME_OPEN_FAILED\n");return;}
 Sleep(3000);ThemeDialog dialog={0};EnumWindows(theme_window,(LPARAM)&dialog);
 if(dialog.apply)SendMessageW(dialog.apply,BM_CLICK,0,0);
 Sleep(3000);if(dialog.window)PostMessageW(dialog.window,WM_CLOSE,0,0);
 redraw();HRESULT second=GetCurrentThemeName(after,MAX_PATH,0,0,0,0);
 hex("THEME_BEFORE_HR=",(DWORD)first);hex("THEME_AFTER_HR=",(DWORD)second);
 if(IsThemeActive()!=was_active||first!=second||lstrcmpiW(before,after))event("WM_FILTERED_THEME_CHANGED");
 else {send("WM_THEME_CHANGE_NOT_CONFIRMED\n");event("WM_FILTERED_THEME_UNCHANGED");}
}
void entry(void){
 record=CreateFileW(L"C:\\USOS\\WMTEST\\probe.log",FILE_APPEND_DATA,FILE_SHARE_READ,0,OPEN_ALWAYS,FILE_FLAG_WRITE_THROUGH,0);
 port=CreateFileW(L"\\\\.\\COM1",GENERIC_READ|GENERIC_WRITE,0,0,OPEN_EXISTING,0,0);if(port==INVALID_HANDLE_VALUE)ExitProcess(2);
 DCB dcb={sizeof(dcb)};GetCommState(port,&dcb);dcb.BaudRate=115200;dcb.ByteSize=8;dcb.StopBits=ONESTOPBIT;dcb.Parity=NOPARITY;SetCommState(port,&dcb);
 send("WM_PROBE_STARTED\n");
 typedef LONG(WINAPI *Query)(ULONG,void*,ULONG,ULONG*);Query query=(Query)GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"NtQuerySystemInformation");struct{ULONG length,options;} ci={sizeof(ci),0};LONG status=query?query(103,&ci,sizeof(ci),0):(LONG)0xc0000002;hex("CI_QUERY=",(DWORD)status);hex("CI_OPTIONS=",ci.options);hex("UPTIME_MS=",GetTickCount());
 Sleep(20000); /* One bounded settle interval after FirstLogonCommands. */
 WCHAR bcd[]=L"cmd.exe /d /c bcdedit /enum {current} > C:\\USOS\\WMTEST\\bcd.txt 2>&1";hex("BCDEDIT_EXIT=",launch(bcd,TRUE));
 BOOL post=post_run();
 if(post){redraw();event("WM_FILTERED_AFTER_REBOOT");change_theme();}
 else{
  event("WM_BASELINE_DESKTOP");
  WCHAR winver[]=L"winver.exe";launch(winver,FALSE);DWORD about_pid=last_pid;Sleep(2000);event("WM_BASELINE_WINVER");
  EnumWindows(close_owned,(LPARAM)about_pid);Sleep(1000);
 }
 WCHAR component[]=L"C:\\USOS\\usoswm\\usoswm.exe";
 if(GetFileAttributesW(component)!=INVALID_FILE_ATTRIBUTES){
  if(!post)launch(component,FALSE);redraw();event("WM_FILTERED_DESKTOP");
  DEVMODEW current={0},changed;current.dmSize=sizeof(current);
  if(EnumDisplaySettingsW(0,ENUM_CURRENT_SETTINGS,&current)){changed=current;changed.dmPelsWidth=current.dmPelsWidth==1024?800:1024;changed.dmPelsHeight=changed.dmPelsWidth==1024?768:600;changed.dmFields=DM_PELSWIDTH|DM_PELSHEIGHT;
   if(ChangeDisplaySettingsW(&changed,0)==DISP_CHANGE_SUCCESSFUL){redraw();event("WM_FILTERED_RESOLUTION");ChangeDisplaySettingsW(&current,0);redraw();}
   else send("WM_RESOLUTION_UNAVAILABLE\n");
  }
  DWORD explorer_pid=0;GetWindowThreadProcessId(GetShellWindow(),&explorer_pid);
  if(explorer_pid){HANDLE explorer=OpenProcess(PROCESS_TERMINATE|SYNCHRONIZE,FALSE,explorer_pid);if(explorer){TerminateProcess(explorer,0);WaitForSingleObject(explorer,10000);CloseHandle(explorer);}}
  WCHAR start_explorer[]=L"explorer.exe";launch(start_explorer,FALSE);Sleep(10000);redraw();event("WM_FILTERED_EXPLORER_RESTART");
  HANDLE flag=CreateFileW(L"C:\\USOS\\usoswm\\testmode-watermark-on.txt",GENERIC_WRITE,0,0,CREATE_ALWAYS,0,0);if(flag!=INVALID_HANDLE_VALUE)CloseHandle(flag);
  redraw();event("WM_OPT_OUT_DESKTOP");
  DeleteFileW(L"C:\\USOS\\usoswm\\testmode-watermark-on.txt");redraw();event("WM_FILTERED_AGAIN");
  WCHAR registration[]=L"C:\\USOS\\usoswm\\usoswm-register.exe";
  hex("REGISTER_EXIT=",launch(registration,TRUE));
  WCHAR registration_again[]=L"C:\\USOS\\usoswm\\usoswm-register.exe";
  hex("REGISTER_AGAIN_EXIT=",launch(registration_again,TRUE));
 }
 LockWorkStation();Sleep(4000);event("WM_BASELINE_LOCK");
 send("WM_BASELINE_COMPLETE\n");
 HANDLE token;TOKEN_PRIVILEGES priv={1};if(OpenProcessToken(GetCurrentProcess(),TOKEN_ADJUST_PRIVILEGES|TOKEN_QUERY,&token)){LookupPrivilegeValueW(0,SE_SHUTDOWN_NAME,&priv.Privileges[0].Luid);priv.Privileges[0].Attributes=SE_PRIVILEGE_ENABLED;AdjustTokenPrivileges(token,FALSE,&priv,0,0,0);CloseHandle(token);}
 BOOL accepted=ExitWindowsEx(EWX_POWEROFF|EWX_FORCEIFHUNG,SHTDN_REASON_MAJOR_APPLICATION|SHTDN_REASON_FLAG_PLANNED);DWORD error=accepted?0:GetLastError();hex("POWER_ACCEPTED=",accepted);hex("POWER_ERROR=",error);ExitProcess(accepted?0:error);
}
