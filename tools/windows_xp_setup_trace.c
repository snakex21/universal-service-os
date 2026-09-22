/* One-shot supervisor for the existing XP GUI Setup. No driver/PAE changes.
 * Debug events and process completion are blocking waits, never polling.
 * All diagnostics live beside this executable in USOS\XP. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static HANDLE logfile=INVALID_HANDLE_VALUE;
static CRITICAL_SECTION lock;
static char folder[MAX_PATH],windows[MAX_PATH],setup[MAX_PATH];
static HWND window;
static DWORD setup_result=ERROR_GEN_FAILURE;
void *memset(void *p,int x,size_t n){volatile BYTE *b=p;while(n--)*b++=(BYTE)x;return p;}
static void record(const char *label,DWORD value){
 char line[400];DWORD n;SYSTEMTIME t;GetLocalTime(&t);
 wsprintfA(line,"%04u-%02u-%02u %02u:%02u:%02u %s=0x%08lx\r\n",t.wYear,t.wMonth,t.wDay,t.wHour,t.wMinute,t.wSecond,label,value);
 EnterCriticalSection(&lock);
 if(logfile!=INVALID_HANDLE_VALUE){WriteFile(logfile,line,lstrlenA(line),&n,0);FlushFileBuffers(logfile);}
 LeaveCriticalSection(&lock);
}
static void snapshot(const char *phase){
 const char *names[]={"setupapi.log","setupact.log","setuperr.log"};
 for(int i=0;i<3;i++){
  char src[MAX_PATH],dst[MAX_PATH];wsprintfA(src,"%s\\%s",windows,names[i]);wsprintfA(dst,"%s%s-%s",folder,phase,names[i]);
  if(CopyFileA(src,dst,FALSE)){
   HANDLE f=CreateFileA(dst,GENERIC_WRITE,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);
   if(f!=INVALID_HANDLE_VALUE){FlushFileBuffers(f);CloseHandle(f);}
  }
 }
}
static LRESULT CALLBACK wndproc(HWND w,UINT m,WPARAM a,LPARAM b){
 if(m==WM_QUERYENDSESSION){record("WM_QUERYENDSESSION flags",(DWORD)b);snapshot("shutdown");return TRUE;}
 if(m==WM_ENDSESSION){record("WM_ENDSESSION",(DWORD)a);return 0;}
 if(m==WM_APP){PostQuitMessage(0);return 0;}
 return DefWindowProcA(w,m,a,b);
}
static DWORD WINAPI supervise(void *unused){
 (void)unused;STARTUPINFOA si={0};PROCESS_INFORMATION pi={0};si.cb=sizeof(si);
 char cmd[MAX_PATH+32];wsprintfA(cmd,"\"%s\" -newsetup",setup);
 BOOL ok=CreateProcessA(setup,cmd,0,0,FALSE,DEBUG_ONLY_THIS_PROCESS,0,0,&si,&pi);
 if(!ok){setup_result=GetLastError();record("CreateProcess failed",setup_result);PostMessageA(window,WM_APP,0,0);return 0;}
 record("setup process id",pi.dwProcessId);CloseHandle(pi.hThread);
 for(;;){
  DEBUG_EVENT e={0};if(!WaitForDebugEvent(&e,INFINITE)){record("WaitForDebugEvent failed",GetLastError());DebugActiveProcessStop(pi.dwProcessId);WaitForSingleObject(pi.hProcess,INFINITE);GetExitCodeProcess(pi.hProcess,&setup_result);break;}
  DWORD disposition=DBG_CONTINUE;BOOL done=FALSE;
  if(e.dwDebugEventCode==CREATE_PROCESS_DEBUG_EVENT&&e.u.CreateProcessInfo.hFile)CloseHandle(e.u.CreateProcessInfo.hFile);
  if(e.dwDebugEventCode==LOAD_DLL_DEBUG_EVENT&&e.u.LoadDll.hFile)CloseHandle(e.u.LoadDll.hFile);
  if(e.dwDebugEventCode==EXCEPTION_DEBUG_EVENT){
   DWORD code=e.u.Exception.ExceptionRecord.ExceptionCode;
   /* The initial breakpoint belongs to the debugger. Deliver application
      exceptions to their normal handlers; do not hide an actual failure. */
   if(code!=EXCEPTION_BREAKPOINT){
    record(e.u.Exception.dwFirstChance?"setup first-chance exception":"setup UNHANDLED exception",code);
    record("exception address",(DWORD)(ULONG_PTR)e.u.Exception.ExceptionRecord.ExceptionAddress);
    if(!e.u.Exception.dwFirstChance)snapshot("exception");
    disposition=DBG_EXCEPTION_NOT_HANDLED;
   }
  }
  if(e.dwDebugEventCode==EXIT_PROCESS_DEBUG_EVENT){setup_result=e.u.ExitProcess.dwExitCode;record("setup exit",setup_result);snapshot("exit");done=TRUE;}
  ContinueDebugEvent(e.dwProcessId,e.dwThreadId,disposition);if(done)break;
 }
 CloseHandle(pi.hProcess);PostMessageA(window,WM_APP,0,0);return 0;
}
void entry(void){
 InitializeCriticalSection(&lock);GetModuleFileNameA(0,folder,sizeof(folder));int i=lstrlenA(folder);while(i&&folder[i-1]!='\\')i--;folder[i]=0;
 char path[MAX_PATH];wsprintfA(path,"%ssetup-supervisor.log",folder);
 logfile=CreateFileA(path,FILE_APPEND_DATA,FILE_SHARE_READ,0,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_WRITE_THROUGH,0);
 GetWindowsDirectoryA(windows,sizeof(windows));wsprintfA(setup,"%s\\system32\\setup.exe",windows);
 record("USOS XP GUI trace v1 start",1);
 MEMORYSTATUSEX mem={0};mem.dwLength=sizeof(mem);if(GlobalMemoryStatusEx(&mem)){record("physical MB",(DWORD)(mem.ullTotalPhys>>20));record("available physical MB",(DWORD)(mem.ullAvailPhys>>20));record("commit limit MB",(DWORD)(mem.ullTotalPageFile>>20));record("available commit MB",(DWORD)(mem.ullAvailPageFile>>20));}
 /* Restore Microsoft's original command before running it. Setup may update
    its own state; nothing in this helper marks installation complete. */
 HKEY k;LONG rc=RegOpenKeyExA(HKEY_LOCAL_MACHINE,"SYSTEM\\Setup",0,KEY_QUERY_VALUE|KEY_SET_VALUE,&k);
 if(rc==ERROR_SUCCESS){
  char value[512]={0};DWORD bytes=sizeof(value),type=0;rc=RegQueryValueExA(k,"CmdLine",0,&type,(BYTE*)value,&bytes);
  if(rc==ERROR_SUCCESS&&(type==REG_SZ||type==REG_EXPAND_SZ)&&lstrcmpiA(value,"C:\\USOS\\x.exe")==0){
   const char original[]="setup -newsetup";rc=RegSetValueExA(k,"CmdLine",0,REG_SZ,(const BYTE*)original,sizeof(original));RegFlushKey(k);
  }else rc=ERROR_INVALID_DATA;
  RegCloseKey(k);
 }
 record("restore setup command",rc);
 if(rc!=ERROR_SUCCESS){MessageBoxA(0,"Cannot restore the original Setup command. See USOS\\XP\\setup-supervisor.log.","USOS XP diagnostics",MB_OK|MB_ICONERROR);ExitProcess(rc);}
 rc=RegOpenKeyExA(HKEY_LOCAL_MACHINE,"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Setup",0,KEY_SET_VALUE,&k);
 if(rc==ERROR_SUCCESS){DWORD level=0x4800ffff;rc=RegSetValueExA(k,"LogLevel",0,REG_DWORD,(const BYTE*)&level,sizeof(level));RegFlushKey(k);RegCloseKey(k);}record("enable verbose SetupAPI flush",rc);
 snapshot("start");WNDCLASSA wc={0};wc.lpfnWndProc=wndproc;wc.lpszClassName="UsosXpSetupTrace";wc.hInstance=GetModuleHandleA(0);
 if(!RegisterClassA(&wc)){record("RegisterClass failed",GetLastError());ExitProcess(1);}
 window=CreateWindowExA(0,wc.lpszClassName,"USOS XP Setup supervisor",0,0,0,0,0,0,0,wc.hInstance,0);
 if(!window){record("CreateWindow failed",GetLastError());ExitProcess(1);}
 HANDLE thread=CreateThread(0,0,supervise,0,0,0);if(!thread){record("CreateThread failed",GetLastError());ExitProcess(1);}
 MSG msg;while(GetMessageA(&msg,0,0,0)>0){TranslateMessage(&msg);DispatchMessageA(&msg);}
 WaitForSingleObject(thread,INFINITE);CloseHandle(thread);
 if(setup_result){char text[500];wsprintfA(text,"Windows XP Setup stopped. Exit code: 0x%08lx.\nDiagnostics: %ssetup-supervisor.log\nPlease photograph this message.",setup_result,folder);MessageBoxA(0,text,"USOS XP Setup diagnostics",MB_OK|MB_ICONERROR);}
 if(logfile!=INVALID_HANDLE_VALUE)CloseHandle(logfile);ExitProcess(setup_result);
}
