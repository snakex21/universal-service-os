/* SPDX-License-Identifier: GPL-3.0-or-later
 * Temporary bottom window on the setup Default desktop. No hooks, timers,
 * remote process access, registry writes or changes to secure desktops.
 */
static HWND setup_background;
static HKEY setup_state;
static HANDLE setup_changed;
static const WCHAR setup_ready_name[]=L"Local\\USOSWM.Setup.Background.Ready";

static BOOL setup_requested(void){
 const WCHAR *command=GetCommandLineW();
 if(*command==L'"'){command++;while(*command&&*command!=L'"')command++;if(*command)command++;}
 else while(*command&&*command!=L' '&&*command!=L'\t')command++;
 while(*command==L' '||*command==L'\t')command++;
 return !lstrcmpW(command,L"--setup");
}
static BOOL setup_value(const WCHAR *name,DWORD *value){
 DWORD type=0,size=sizeof(*value);
 return !RegQueryValueExW(setup_state,name,0,&type,(BYTE*)value,&size)&&type==REG_DWORD&&size==sizeof(*value);
}
static BOOL setup_active(void){
 DWORD active=0,oobe=0,phase=0;
 return setup_value(L"SystemSetupInProgress",&active)&&setup_value(L"OOBEInProgress",&oobe)
     &&setup_value(L"SetupPhase",&phase)&&phase==4&&(active==1||oobe==1);
}
static BOOL setup_notices_clear(void){
 if(GetSystemMetrics(SM_CLEANBOOT)||wm_visible(0))return FALSE;
 HKEY key=0;DWORD value=0,type=0,size=sizeof(value);
 if(RegOpenKeyExW(HKEY_CURRENT_USER,L"Control Panel\\Desktop",0,KEY_QUERY_VALUE,&key))return FALSE;
 LONG error=RegQueryValueExW(key,L"PaintDesktopVersion",0,&type,(BYTE*)&value,&size);RegCloseKey(key);
 if(error!=ERROR_FILE_NOT_FOUND&&(error||type!=REG_DWORD||size!=sizeof(value)||value))return FALSE;
 WCHAR path[MAX_PATH];DWORD length=GetSystemDirectoryW(path,MAX_PATH);if(!length||length>=MAX_PATH-16)return FALSE;
 lstrcatW(path,L"\\slc.dll");HMODULE licensing=LoadLibraryW(path);if(!licensing)return FALSE;
 typedef HRESULT(WINAPI *LicenseQuery)(PCWSTR,DWORD *);
 LicenseQuery query=(LicenseQuery)GetProcAddress(licensing,"SLGetWindowsInformationDWORD");
 DWORD genuine=0;HRESULT result=query?query(L"Security-Licensing-SLC-GenuineLocalStatus",&genuine):E_NOINTERFACE;
 FreeLibrary(licensing);return SUCCEEDED(result)&&genuine!=0;
}
static BOOL setup_has_explorer(void){
 HWND shell=GetShellWindow();DWORD pid=0;if(!shell||!GetWindowThreadProcessId(shell,&pid)||!pid)return FALSE;
 HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);if(!process)return FALSE;
 WCHAR actual[MAX_PATH],expected[MAX_PATH];DWORD count=MAX_PATH;
 BOOL ok=QueryFullProcessImageNameW(process,0,actual,&count);CloseHandle(process);
 count=GetWindowsDirectoryW(expected,MAX_PATH);if(!count||count>=MAX_PATH-20)return FALSE;
 lstrcatW(expected,L"\\explorer.exe");return ok&&!lstrcmpiW(actual,expected);
}
static void setup_size(void){
 SetWindowPos(setup_background,HWND_BOTTOM,GetSystemMetrics(SM_XVIRTUALSCREEN),GetSystemMetrics(SM_YVIRTUALSCREEN),
     GetSystemMetrics(SM_CXVIRTUALSCREEN),GetSystemMetrics(SM_CYVIRTUALSCREEN),SWP_NOACTIVATE|SWP_SHOWWINDOW);
}
static LRESULT CALLBACK setup_window(HWND window,UINT message,WPARAM w,LPARAM l){
 if(message==WM_MOUSEACTIVATE)return MA_NOACTIVATE;
 if(message==WM_QUERYENDSESSION)return TRUE;
 if(message==WM_ENDSESSION){if(w)DestroyWindow(window);return 0;}
 if(message==WM_DISPLAYCHANGE){setup_size();return 0;}
 if(message==WM_SETTINGCHANGE||message==WM_SYSCOLORCHANGE){
  if(!setup_notices_clear())DestroyWindow(window);else InvalidateRect(window,0,TRUE);return 0;
 }
 if(message==WM_APP){if(setup_has_explorer())DestroyWindow(window);return 0;}
 if(message==WM_PAINT){
  if(wm_visible(0)){DestroyWindow(window);return 0;}
  PAINTSTRUCT paint;HDC dc=BeginPaint(window,&paint);FillRect(dc,&paint.rcPaint,GetSysColorBrush(COLOR_DESKTOP));EndPaint(window,&paint);return 0;
 }
 if(message==WM_DESTROY){PostQuitMessage(0);return 0;}
 return DefWindowProcW(window,message,w,l);
}
static void CALLBACK setup_shell_event(HWINEVENTHOOK hook,DWORD event,HWND window,LONG object,LONG child,DWORD thread,DWORD time){
 (void)hook;(void)event;(void)thread;(void)time;
 if(window&&object==OBJID_WINDOW&&child==CHILDID_SELF)PostMessageW(setup_background,WM_APP,0,0);
}
static void setup_present(void){
 HANDLE mutex=CreateMutexW(0,TRUE,L"Local\\USOSWM.Setup.Background");
 if(!mutex||GetLastError()==ERROR_ALREADY_EXISTS){if(mutex)CloseHandle(mutex);return;}
 if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SYSTEM\\Setup",0,KEY_QUERY_VALUE|KEY_NOTIFY,&setup_state))goto done;
 if(!setup_active()||!setup_notices_clear()||setup_has_explorer()){
  wm_log(0,"Setup background not started: setup/desktop/notices guard");goto closed;
 }
 setup_changed=CreateEventW(0,FALSE,FALSE,0);if(!setup_changed)goto closed;
 WNDCLASSW type={0};type.lpfnWndProc=setup_window;type.hInstance=GetModuleHandleW(0);type.lpszClassName=L"USOSWM.Setup.Background";
 if(!RegisterClassW(&type))goto event_closed;
 setup_background=CreateWindowExW(WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE,type.lpszClassName,L"",WS_POPUP,0,0,0,0,0,0,type.hInstance,0);
 if(!setup_background)goto event_closed;
 HWINEVENTHOOK shell=SetWinEventHook(EVENT_OBJECT_CREATE,EVENT_OBJECT_SHOW,0,setup_shell_event,0,0,WINEVENT_OUTOFCONTEXT|WINEVENT_SKIPOWNPROCESS);
 if(!shell){DestroyWindow(setup_background);goto event_closed;}
 setup_size();UpdateWindow(setup_background);
 wm_log(0,"Setup background shown below installer windows; no process hooks");
 HANDLE ready=OpenEventW(EVENT_MODIFY_STATE,FALSE,setup_ready_name);if(ready){SetEvent(ready);CloseHandle(ready);}
 BOOL running=TRUE,armed=FALSE;
 while(running){
  if(!armed){if(RegNotifyChangeKeyValue(setup_state,FALSE,REG_NOTIFY_CHANGE_LAST_SET,setup_changed,TRUE))break;armed=TRUE;}
  if(!setup_active()||setup_has_explorer()||wm_visible(0))break;
  DWORD result=MsgWaitForMultipleObjects(1,&setup_changed,FALSE,INFINITE,QS_ALLINPUT);
  if(result==WAIT_FAILED)break;
  if(result==WAIT_OBJECT_0)armed=FALSE;
  MSG message;while(PeekMessageW(&message,0,0,0,PM_REMOVE)){
   if(message.message==WM_QUIT){running=FALSE;break;}TranslateMessage(&message);DispatchMessageW(&message);
  }
 }
 UnhookWinEvent(shell);if(IsWindow(setup_background))DestroyWindow(setup_background);
 wm_log(0,"Setup background closed at setup end or Explorer handover");
event_closed:CloseHandle(setup_changed);
closed:RegCloseKey(setup_state);
done:CloseHandle(mutex);
}
