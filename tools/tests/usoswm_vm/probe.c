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
#include <aclapi.h>
#include <wtsapi32.h>
#include <stddef.h>
void *memcpy(void *d,const void *s,size_t n){BYTE *a=d;const BYTE *b=s;while(n--)*a++=*b++;return d;}
void *memset(void *d,int c,size_t n){BYTE *a=d;while(n--)*a++=(BYTE)c;return d;}
static HANDLE port,record=INVALID_HANDLE_VALUE;
static void send(const char *s){DWORD n;if(record!=INVALID_HANDLE_VALUE){WriteFile(record,s,lstrlenA(s),&n,0);FlushFileBuffers(record);}if(port!=INVALID_HANDLE_VALUE)WriteFile(port,s,lstrlenA(s),&n,0);}
static void hex(const char *name,DWORD value){char text[10];for(unsigned i=0;i<8;i++)text[i]="0123456789ABCDEF"[(value>>(28-4*i))&15];text[8]='\n';text[9]=0;send(name);send(text);}
static void event(const char *s){send(s);send("\n");char ack;DWORD n;ReadFile(port,&ack,1,&n,0);}
static DWORD last_pid;
static DWORD launch(WCHAR *s,BOOL wait){STARTUPINFOW si={sizeof(si)};PROCESS_INFORMATION pi={0};if(!CreateProcessW(0,s,0,0,FALSE,CREATE_NO_WINDOW,0,0,&si,&pi))return GetLastError();last_pid=pi.dwProcessId;DWORD result=0;if(wait){DWORD status=WaitForSingleObject(pi.hProcess,60000);if(status!=WAIT_OBJECT_0)result=status==WAIT_TIMEOUT?ERROR_TIMEOUT:GetLastError();else if(!GetExitCodeProcess(pi.hProcess,&result))result=GetLastError();}else WaitForInputIdle(pi.hProcess,15000);CloseHandle(pi.hProcess);CloseHandle(pi.hThread);return result;}
static BOOL CALLBACK close_owned(HWND window,LPARAM pid){DWORD actual=0;GetWindowThreadProcessId(window,&actual);if(actual==(DWORD)pid)PostMessageW(window,WM_CLOSE,0,0);return TRUE;}
static BOOL CALLBACK clear_desktop(HWND window,LPARAM unused){
 (void)unused;if(!IsWindowVisible(window))return TRUE;WCHAR cls[64],title[160];GetClassNameW(window,cls,64);GetWindowTextW(window,title,160);
 if(!lstrcmpW(cls,L"Progman")||!lstrcmpW(cls,L"WorkerW")||!lstrcmpW(cls,L"Shell_TrayWnd")||!lstrcmpW(cls,L"Shell_SecondaryTrayWnd"))return TRUE;
 if(!lstrcmpW(title,L"Śledzenie zdarzeń zamknięcia systemu")||!lstrcmpW(title,L"Shutdown Event Tracker"))PostMessageW(window,WM_COMMAND,IDCANCEL,0);
 else ShowWindowAsync(window,SW_MINIMIZE);
 return TRUE;
}
static void redraw(void){EnumWindows(clear_desktop,0);HWND shell=GetShellWindow();if(shell)RedrawWindow(shell,0,0,RDW_ERASE|RDW_INVALIDATE|RDW_ALLCHILDREN);Sleep(3000);}
static BOOL shell_ready;
static void CALLBACK shell_created(HWINEVENTHOOK hook,DWORD what,HWND window,LONG object,LONG child,DWORD thread,DWORD time){(void)hook;(void)what;(void)window;(void)object;(void)child;(void)thread;(void)time;HWND shell=GetShellWindow();if(shell&&IsWindowVisible(shell))shell_ready=TRUE;}
static BOOL wait_shell(void){
 HWINEVENTHOOK hook=SetWinEventHook(EVENT_OBJECT_CREATE,EVENT_OBJECT_SHOW,0,shell_created,0,0,WINEVENT_OUTOFCONTEXT|WINEVENT_SKIPOWNPROCESS);if(!hook)return FALSE;
 shell_created(0,0,0,0,0,0,0);DWORD started=GetTickCount();
 while(!shell_ready){DWORD elapsed=GetTickCount()-started;if(elapsed>=600000)break;DWORD result=MsgWaitForMultipleObjects(0,0,FALSE,600000-elapsed,QS_ALLINPUT);if(result==WAIT_TIMEOUT||result==WAIT_FAILED)break;MSG message;while(PeekMessageW(&message,0,0,0,PM_REMOVE)){TranslateMessage(&message);DispatchMessageW(&message);}}
 UnhookWinEvent(hook);return shell_ready;
}
static BOOL post_run(void){const WCHAR *text=GetCommandLineW();for(;*text;text++)if(text[0]==L'-'&&text[1]==L'-'&&text[2]==L'p'&&text[3]==L'o'&&text[4]==L's'&&text[5]==L't')return TRUE;return FALSE;}
static BOOL option(const WCHAR *name){const WCHAR *text=GetCommandLineW();DWORD n=lstrlenW(name);for(;*text;text++){DWORD i=0;while(i<n&&text[i]&&text[i]==name[i])i++;if(i==n&&(!text[i]||text[i]==L' '))return TRUE;}return FALSE;}
static BOOL remote_capture(const WCHAR *name){
 int width=GetSystemMetrics(SM_CXSCREEN),height=GetSystemMetrics(SM_CYSCREEN);
 if(!GetSystemMetrics(SM_REMOTESESSION)||width<1||height<1||width>10000||height>10000)return FALSE;
 HDC screen=GetDC(0),memory=CreateCompatibleDC(screen);BITMAPINFO info={0};void *pixels=0;BOOL ok=FALSE;
 info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);info.bmiHeader.biWidth=width;info.bmiHeader.biHeight=-height;
 info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;info.bmiHeader.biCompression=BI_RGB;
 HBITMAP bitmap=CreateDIBSection(screen,&info,DIB_RGB_COLORS,&pixels,0,0);
 if(bitmap&&memory){
  HGDIOBJ old=SelectObject(memory,bitmap);
  if(BitBlt(memory,0,0,width,height,screen,0,0,SRCCOPY|CAPTUREBLT)){
   WCHAR path[MAX_PATH];lstrcpyW(path,L"C:\\USOS\\usoswm\\logs\\");lstrcatW(path,name);
   HANDLE file=CreateFileW(path,GENERIC_WRITE,0,0,CREATE_NEW,FILE_FLAG_WRITE_THROUGH,0);
   if(file!=INVALID_HANDLE_VALUE){
    DWORD written,size=width*height*4;BITMAPFILEHEADER header={0};header.bfType=0x4d42;
    header.bfOffBits=sizeof(header)+sizeof(info.bmiHeader);header.bfSize=header.bfOffBits+size;
    ok=WriteFile(file,&header,sizeof(header),&written,0)&&written==sizeof(header)
        &&WriteFile(file,&info.bmiHeader,sizeof(info.bmiHeader),&written,0)&&written==sizeof(info.bmiHeader)
        &&WriteFile(file,pixels,size,&written,0)&&written==size&&FlushFileBuffers(file);CloseHandle(file);
   }
  }SelectObject(memory,old);
 }
 if(bitmap)DeleteObject(bitmap);if(memory)DeleteDC(memory);ReleaseDC(0,screen);return ok;
}
static const WCHAR rdp_pipe_name[]=L"\\\\.\\pipe\\USOSWM.Lab.RDP.Probe";
static HANDLE session_notice;static BOOL session_notice_ready;
static LRESULT CALLBACK rdp_session_notice(HWND window,UINT message,WPARAM state,LPARAM session){
 DWORD own=0;ProcessIdToSessionId(GetCurrentProcessId(),&own);
 if(message==WM_WTSSESSION_CHANGE&&state==WTS_REMOTE_CONNECT&&(DWORD)session==own){
  WCHAR actor[]=L"C:\\USOS\\WMTEST\\wm-full.exe --rdp-session";launch(actor,FALSE);
 }
 return DefWindowProcW(window,message,state,session);
}
static DWORD WINAPI rdp_notice_thread(void *unused){
 (void)unused;WNDCLASSW cls={0};cls.hInstance=GetModuleHandleW(0);cls.lpfnWndProc=rdp_session_notice;cls.lpszClassName=L"USOSWM.Lab.RDP.Notice";
 if(RegisterClassW(&cls)){
  HWND window=CreateWindowExW(0,cls.lpszClassName,L"",0,0,0,0,0,HWND_MESSAGE,0,cls.hInstance,0);
  if(window)session_notice_ready=WTSRegisterSessionNotification(window,NOTIFY_FOR_THIS_SESSION);
 }
 SetEvent(session_notice);if(!session_notice_ready)return 1;
 MSG message;while(GetMessageW(&message,0,0,0)>0){TranslateMessage(&message);DispatchMessageW(&message);}return 0;
}
static HANDLE rdp_broker_pipe(void){
 HANDLE token=0;if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token))return INVALID_HANDLE_VALUE;
 BYTE user[sizeof(TOKEN_USER)+SECURITY_MAX_SID_SIZE];DWORD bytes=0;
 BOOL ok=GetTokenInformation(token,TokenUser,user,sizeof(user),&bytes);CloseHandle(token);if(!ok)return INVALID_HANDLE_VALUE;
 EXPLICIT_ACCESSW access={0};access.grfAccessPermissions=GENERIC_READ|GENERIC_WRITE;access.grfAccessMode=SET_ACCESS;
 access.Trustee.TrusteeForm=TRUSTEE_IS_SID;access.Trustee.TrusteeType=TRUSTEE_IS_USER;access.Trustee.ptstrName=(LPWSTR)((TOKEN_USER*)user)->User.Sid;
 PACL acl=0;if(SetEntriesInAclW(1,&access,0,&acl))return INVALID_HANDLE_VALUE;
 SECURITY_DESCRIPTOR descriptor;InitializeSecurityDescriptor(&descriptor,SECURITY_DESCRIPTOR_REVISION);SetSecurityDescriptorDacl(&descriptor,TRUE,acl,FALSE);
 SECURITY_ATTRIBUTES attributes={sizeof(attributes),&descriptor,FALSE};
 HANDLE pipe=CreateNamedPipeW(rdp_pipe_name,PIPE_ACCESS_DUPLEX|FILE_FLAG_FIRST_PIPE_INSTANCE,PIPE_TYPE_BYTE|PIPE_READMODE_BYTE|PIPE_WAIT,1,4096,4096,0,&attributes);
 LocalFree(acl);return pipe;
}
static void broker_rdp(HANDLE pipe){
 if(!ConnectNamedPipe(pipe,0)&&GetLastError()!=ERROR_PIPE_CONNECTED)ExitProcess(6);
 char text[160];DWORD used=0,got=0;
 for(;;){
  if(!ReadFile(pipe,text+used,1,&got,0)||!got)ExitProcess(6);
  if(text[used]=='\n'){
   text[++used]=0;send(text);
   if(!lstrcmpA(text,"WM_RDP_DESKTOP\n")||!lstrcmpA(text,"WM_RDP_WINVER\n")){
    char ack;if(!ReadFile(port,&ack,1,&got,0)||got!=1||ack!='A'||!WriteFile(pipe,&ack,1,&got,0))ExitProcess(6);
   }
   if(!lstrcmpA(text,"WM_RDP_COMPLETE\n")){
    char ack;if(!ReadFile(port,&ack,1,&got,0)||got!=1||ack!='A')ExitProcess(6);break;
   }
   used=0;
  }else if(++used>=sizeof(text)-2)ExitProcess(6);
 }
 DisconnectNamedPipe(pipe);CloseHandle(pipe);CloseHandle(port);
 HANDLE token=0;if(OpenProcessToken(GetCurrentProcess(),TOKEN_ADJUST_PRIVILEGES|TOKEN_QUERY,&token)){
  TOKEN_PRIVILEGES privileges={1};if(LookupPrivilegeValueW(0,SE_SHUTDOWN_NAME,&privileges.Privileges[0].Luid)){privileges.Privileges[0].Attributes=SE_PRIVILEGE_ENABLED;AdjustTokenPrivileges(token,FALSE,&privileges,0,0,0);}CloseHandle(token);
 }
 ExitProcess(InitiateSystemShutdownExW(0,L"USOS RDP lab complete",0,TRUE,FALSE,SHTDN_REASON_MAJOR_APPLICATION|SHTDN_REASON_FLAG_PLANNED)?0:7);
}
static void prepare_rdp(void){
 /* Only the disposable guest gains its normal RDP firewall exception.
  * QEMU restrict=on and a loopback-only forwarding socket isolate it. */
 const char script[]="Set svc=GetObject(\"winmgmts:{authenticationLevel=pktPrivacy}!\\\\.\\root\\CIMV2\\TerminalServices\")\r\nFor Each cfg In svc.ExecQuery(\"SELECT * FROM Win32_TerminalServiceSetting\")\r\nresult=cfg.SetAllowTSConnections(1,1)\r\nIf result<>0 Then WScript.Quit result\r\nNext\r\nWScript.Quit 0\r\n";
 HANDLE file=CreateFileW(L"C:\\USOS\\WMTEST\\enable-rdp.vbs",GENERIC_WRITE,0,0,CREATE_ALWAYS,0,0);if(file==INVALID_HANDLE_VALUE)ExitProcess(5);
 DWORD written;BOOL ok=WriteFile(file,script,sizeof(script)-1,&written,0);CloseHandle(file);if(!ok)ExitProcess(5);
 WCHAR enable[]=L"cmd.exe /d /c cscript.exe //nologo C:\\USOS\\WMTEST\\enable-rdp.vbs > C:\\USOS\\WMTEST\\rdp-enable.txt 2>&1";
 DWORD status=launch(enable,TRUE);hex("RDP_PREP_EXIT=",status);if(status){send("WM_RDP_PREP_FAILED\n");ExitProcess(status);}
 /* The normal UAC-filtered remote user cannot open the physical COM device.
  * A same-user-only, ephemeral evidence pipe relays bytes to this already
  * elevated lab broker. No UAC/port ACL/registry policy is changed. */
 HANDLE pipe=rdp_broker_pipe();if(pipe==INVALID_HANDLE_VALUE){hex("RDP_PIPE_ERROR=",GetLastError());send("WM_RDP_PREP_FAILED\n");ExitProcess(6);}
 session_notice=CreateEventW(0,TRUE,FALSE,0);HANDLE worker=session_notice?CreateThread(0,0,rdp_notice_thread,0,0,0):0;
 if(!worker||WaitForSingleObject(session_notice,10000)!=WAIT_OBJECT_0||!session_notice_ready){send("WM_RDP_PREP_FAILED\n");ExitProcess(6);}
 CloseHandle(worker);CloseHandle(session_notice);
 send("WM_RDP_READY\n");broker_rdp(pipe);
}
typedef struct{HWND window,apply;} ThemeDialog;
static BOOL CALLBACK theme_child(HWND window,LPARAM value){ThemeDialog *dialog=(ThemeDialog*)value;if(GetDlgCtrlID(window)==0x3021&&IsWindowVisible(window)&&IsWindowEnabled(window))dialog->apply=window;return TRUE;}
static BOOL CALLBACK theme_window(HWND window,LPARAM value){ThemeDialog candidate={window,0};WCHAR cls[32];GetClassNameW(window,cls,32);if(IsWindowVisible(window)&&!lstrcmpW(cls,L"#32770")){EnumChildWindows(window,theme_child,(LPARAM)&candidate);if(candidate.apply)*(ThemeDialog*)value=candidate;}return TRUE;}
static void change_theme(void){
 WCHAR before[MAX_PATH]={0},after[MAX_PATH]={0},source[MAX_PATH];
 HRESULT first=GetCurrentThemeName(before,MAX_PATH,0,0,0,0);BOOL was_active=IsThemeActive();DWORD colour=GetSysColor(COLOR_DESKTOP);
 UINT n=GetWindowsDirectoryW(source,MAX_PATH);if(!n||n>=MAX_PATH-48)return;
 lstrcatW(source,L"\\Resources\\Themes\\Windows Classic.theme");
 const WCHAR *target=L"C:\\USOS\\WMTEST\\change.theme";
 /* Use the local OS's complete stock schema. No Microsoft theme content is
  * embedded in our source or exported; only this disposable VM copy changes. */
 if(!CopyFileW(source,target,FALSE)||!WritePrivateProfileStringW(L"Theme",L"DisplayName",L"USOS VM Classic colours",target)||!WritePrivateProfileStringW(L"Control Panel\\Colors",L"Background",colour==RGB(28,66,92)?L"44 78 108":L"28 66 92",target)){send("WM_THEME_FILE_FAILED\n");return;}
 HINSTANCE opened=ShellExecuteW(0,L"open",target,0,0,SW_SHOWNORMAL);if((UINT_PTR)opened<=32){send("WM_THEME_OPEN_FAILED\n");return;}
 Sleep(3000);event("WM_FILTERED_THEME_DIALOG");ThemeDialog dialog={0};EnumWindows(theme_window,(LPARAM)&dialog);
 if(dialog.apply)SendMessageW(dialog.apply,BM_CLICK,0,0);
 Sleep(3000);if(dialog.window)PostMessageW(dialog.window,WM_CLOSE,0,0);
 redraw();HRESULT second=GetCurrentThemeName(after,MAX_PATH,0,0,0,0);
 hex("THEME_BEFORE_HR=",(DWORD)first);hex("THEME_AFTER_HR=",(DWORD)second);hex("THEME_COLOUR_BEFORE=",colour);hex("THEME_COLOUR_AFTER=",GetSysColor(COLOR_DESKTOP));
 if(IsThemeActive()!=was_active||GetSysColor(COLOR_DESKTOP)!=colour||(SUCCEEDED(first)&&SUCCEEDED(second)&&lstrcmpiW(before,after)))event("WM_FILTERED_THEME_CHANGED");
 else {send("WM_THEME_CHANGE_NOT_CONFIRMED\n");event("WM_FILTERED_THEME_UNCHANGED");}
}
static void elevate_test(void){
 HANDLE token=0;TOKEN_ELEVATION elevation={0};DWORD bytes=0;
 if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token))ExitProcess(5);
 BOOL queried=GetTokenInformation(token,TokenElevation,&elevation,sizeof(elevation),&bytes);CloseHandle(token);
 if(!queried)ExitProcess(5);if(elevation.TokenIsElevated)return;
 HANDLE notice=CreateFileW(L"\\\\.\\COM1",GENERIC_WRITE,0,0,OPEN_EXISTING,0,0);
 if(notice!=INVALID_HANDLE_VALUE){const char text[]="WM_UAC_REQUESTED\n";DWORD written;WriteFile(notice,text,sizeof(text)-1,&written,0);CloseHandle(notice);}
 WCHAR file[MAX_PATH];if(!GetModuleFileNameW(0,file,MAX_PATH))ExitProcess(5);
 SHELLEXECUTEINFOW request={sizeof(request)};request.fMask=SEE_MASK_NOCLOSEPROCESS|SEE_MASK_NOASYNC;request.lpVerb=L"runas";request.lpFile=file;request.lpParameters=option(L"--rdp-prepare")?L"--rdp-prepare":post_run()?L"--post":L"";request.nShow=SW_SHOWNORMAL;
 BOOL ok=ShellExecuteExW(&request);DWORD result=ok?0:GetLastError();if(request.hProcess)CloseHandle(request.hProcess);
 if(!ok){HANDLE failure=CreateFileW(L"\\\\.\\COM1",GENERIC_WRITE,0,0,OPEN_EXISTING,0,0);if(failure!=INVALID_HANDLE_VALUE){char text[]="WM_UAC_ERROR=00000000\nWM_UAC_FAILED\n";for(unsigned i=0;i<8;i++)text[13+i]="0123456789ABCDEF"[(result>>(28-4*i))&15];DWORD written;WriteFile(failure,text,sizeof(text)-1,&written,0);CloseHandle(failure);}}
 ExitProcess(result);
}
void entry(void){
 BOOL remote_probe=option(L"--rdp-session");if(!remote_probe)elevate_test(); /* Normal UAC consent. RDP measurement needs no elevation. */
 if(remote_probe){HANDLE unique=CreateMutexW(0,TRUE,L"Local\\USOSWM.Lab.RDP.Actor");if(!unique||GetLastError()==ERROR_ALREADY_EXISTS)ExitProcess(0);}
 record=CreateFileW(L"C:\\USOS\\WMTEST\\probe.log",FILE_APPEND_DATA,FILE_SHARE_READ,0,OPEN_ALWAYS,FILE_FLAG_WRITE_THROUGH,0);
 port=CreateFileW(remote_probe?rdp_pipe_name:L"\\\\.\\COM1",GENERIC_READ|GENERIC_WRITE,0,0,OPEN_EXISTING,0,0);if(port==INVALID_HANDLE_VALUE){DWORD error=GetLastError();hex("COM_OPEN_ERROR=",error);ExitProcess(2);}
 if(!remote_probe){DCB dcb={sizeof(dcb)};GetCommState(port,&dcb);dcb.BaudRate=115200;dcb.ByteSize=8;dcb.StopBits=ONESTOPBIT;dcb.Parity=NOPARITY;SetCommState(port,&dcb);}
 send("WM_PROBE_STARTED\n");
 if(option(L"--rdp-prepare"))prepare_rdp();
 typedef LONG(WINAPI *Query)(ULONG,void*,ULONG,ULONG*);Query query=(Query)GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"NtQuerySystemInformation");struct{ULONG length,options;} ci={sizeof(ci),0};LONG status=query?query(103,&ci,sizeof(ci),0):(LONG)0xc0000002;hex("CI_QUERY=",(DWORD)status);hex("CI_OPTIONS=",ci.options);hex("UPTIME_MS=",GetTickCount());
 if(!wait_shell()){event("WM_BASELINE_SHELL_TIMEOUT");ExitProcess(3);}
 Sleep(3000); /* Rendering settle, after the actual shell-created event. */
 if(remote_probe){
  DWORD session=0;ProcessIdToSessionId(GetCurrentProcessId(),&session);hex("RDP_SESSION_ID=",session);hex("RDP_REMOTE_METRIC=",GetSystemMetrics(SM_REMOTESESSION));redraw();
  BOOL first=remote_capture(L"wm-rdp-desktop.bmp");hex("RDP_CAPTURE_DESKTOP=",first?0:1);if(!first)ExitProcess(8);event("WM_RDP_DESKTOP");
  WCHAR about[]=L"winver.exe";launch(about,FALSE);Sleep(2000);
  BOOL second=remote_capture(L"wm-rdp-winver.bmp");hex("RDP_CAPTURE_WINVER=",second?0:1);if(!second)ExitProcess(8);event("WM_RDP_WINVER");
  send("WM_RDP_COMPLETE\n");CloseHandle(port);ExitProcess(0);
 }
 WCHAR bcd[]=L"cmd.exe /d /c bcdedit /enum {current} > C:\\USOS\\WMTEST\\bcd.txt 2>&1";hex("BCDEDIT_EXIT=",launch(bcd,TRUE));
 BOOL post=post_run();
 if(post){
  WCHAR outside[]=L"C:\\USOS\\usoswm\\usoswm.exe --setup";
  hex("SETUP_MODE_OUTSIDE_SETUP_EXIT=",launch(outside,TRUE));
  hex("SETUP_BACKGROUND_OUTSIDE_SETUP=",FindWindowW(L"USOSWM.Setup.Background",0)?1:0);
  redraw();event("WM_FILTERED_AFTER_REBOOT");change_theme();
 }
 else{
  redraw();event("WM_BASELINE_DESKTOP");
  WCHAR winver[]=L"winver.exe";launch(winver,FALSE);DWORD about_pid=last_pid;Sleep(2000);event("WM_BASELINE_WINVER");
  EnumWindows(close_owned,(LPARAM)about_pid);Sleep(1000);
 }
 WCHAR component[]=L"C:\\USOS\\usoswm\\usoswm.exe";
 if(GetFileAttributesW(component)!=INVALID_FILE_ATTRIBUTES){
  if(!post&&!DeleteFileW(L"C:\\USOS\\usoswm\\testmode-watermark-on.txt")&&GetLastError()!=ERROR_FILE_NOT_FOUND){hex("BASELINE_MARKER_REMOVE_FAILED=",GetLastError());ExitProcess(4);}
  if(!post)launch(component,FALSE);redraw();event("WM_FILTERED_DESKTOP");
  DEVMODEW current={0},changed;current.dmSize=sizeof(current);
  if(EnumDisplaySettingsW(0,ENUM_CURRENT_SETTINGS,&current)){changed=current;changed.dmPelsWidth=current.dmPelsWidth==1024?800:1024;changed.dmPelsHeight=changed.dmPelsWidth==1024?768:600;changed.dmFields=DM_PELSWIDTH|DM_PELSHEIGHT;
   if(ChangeDisplaySettingsW(&changed,0)==DISP_CHANGE_SUCCESSFUL){redraw();event("WM_FILTERED_RESOLUTION");ChangeDisplaySettingsW(&current,0);redraw();}
   else send("WM_RESOLUTION_UNAVAILABLE\n");
  }
  DWORD explorer_pid=0;GetWindowThreadProcessId(GetShellWindow(),&explorer_pid);
  if(explorer_pid){HANDLE explorer=OpenProcess(PROCESS_TERMINATE|SYNCHRONIZE,FALSE,explorer_pid);if(explorer){TerminateProcess(explorer,0);WaitForSingleObject(explorer,10000);CloseHandle(explorer);}}
  WCHAR start_explorer[]=L"explorer.exe";launch(start_explorer,FALSE);Sleep(10000);redraw();event("WM_FILTERED_EXPLORER_RESTART");
  if(!post){
  HANDLE flag=CreateFileW(L"C:\\USOS\\usoswm\\testmode-watermark-on.txt",GENERIC_WRITE,0,0,CREATE_ALWAYS,0,0);if(flag!=INVALID_HANDLE_VALUE)CloseHandle(flag);
  redraw();event("WM_OPT_OUT_DESKTOP");
  DeleteFileW(L"C:\\USOS\\usoswm\\testmode-watermark-on.txt");redraw();event("WM_FILTERED_AGAIN");
  WCHAR registration[]=L"C:\\USOS\\usoswm\\usoswm-register.exe";
  hex("REGISTER_EXIT=",launch(registration,TRUE));
  WCHAR registration_again[]=L"C:\\USOS\\usoswm\\usoswm-register.exe";
  hex("REGISTER_AGAIN_EXIT=",launch(registration_again,TRUE));
  }
 }
 WCHAR system[]=L"control.exe /name Microsoft.System";launch(system,FALSE);Sleep(3000);event(post?"WM_FILTERED_SYSTEM":"WM_BASELINE_SYSTEM");
 redraw();event(post?"WM_FILTERED_CAD":"WM_BASELINE_CAD");
 LockWorkStation();Sleep(4000);event("WM_BASELINE_LOCK");
 WCHAR disconnect[MAX_PATH];UINT system_length=GetSystemDirectoryW(disconnect,MAX_PATH);if(system_length&&system_length<MAX_PATH-16){lstrcatW(disconnect,L"\\tsdiscon.exe");if(GetFileAttributesW(disconnect)!=INVALID_FILE_ATTRIBUTES){DWORD disconnected=launch(disconnect,TRUE);hex("SWITCH_USER_EXIT=",disconnected);if(!disconnected){Sleep(3000);event("WM_BASELINE_SWITCH_USER");}}}
 send("WM_BASELINE_COMPLETE\n");
 HANDLE token;TOKEN_PRIVILEGES priv={1};if(OpenProcessToken(GetCurrentProcess(),TOKEN_ADJUST_PRIVILEGES|TOKEN_QUERY,&token)){LookupPrivilegeValueW(0,SE_SHUTDOWN_NAME,&priv.Privileges[0].Luid);priv.Privileges[0].Attributes=SE_PRIVILEGE_ENABLED;AdjustTokenPrivileges(token,FALSE,&priv,0,0,0);CloseHandle(token);}
 BOOL accepted=InitiateSystemShutdownExW(0,0,0,TRUE,FALSE,SHTDN_REASON_MAJOR_APPLICATION|SHTDN_REASON_FLAG_PLANNED);DWORD error=accepted?0:GetLastError();hex("POWER_ACCEPTED=",accepted);hex("POWER_ERROR=",error);ExitProcess(accepted?0:error);
}
