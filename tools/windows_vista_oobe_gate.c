/* Vista SP2 OOBE gate. Setup is watched through notifications, never polling.
 * Frozen USB helpers and native Windows retain their original responsibilities. */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0600
#include <windows.h>
#include <lm.h>
#include "vista_oobe_recovery_policy.h"
#include "vista_autochk.h"
static WCHAR windows[MAX_PATH],self[MAX_PATH],file[MAX_PATH];
static HANDLE log_file=INVALID_HANDLE_VALUE;
static const WCHAR native[]=L"oobe\\windeploy.exe";
static void report(const char *label,DWORD v){
 DWORD n;char hex[13]="0x00000000\r\n";
 for(unsigned i=0;i<8;i++)hex[9-i]="0123456789abcdef"[(v>>(4*i))&15];
 if(log_file!=INVALID_HANDLE_VALUE){WriteFile(log_file,label,lstrlenA(label),&n,0);WriteFile(log_file,hex,12,&n,0);FlushFileBuffers(log_file);}
}
static BOOL get(HKEY key,const WCHAR *name,DWORD *v){
 DWORD n=4,type=0;return !RegQueryValueExW(key,name,0,&type,(BYTE*)v,&n)&&type==REG_DWORD&&n==4;
}
static BOOL line(HKEY key,WCHAR *out){
 DWORD n=MAX_PATH*2,type=0;out[0]=0;
 return !RegQueryValueExW(key,L"CmdLine",0,&type,(BYTE*)out,&n)&&type==REG_SZ&&n>=2&&n<=MAX_PATH*2&&!(n&1)&&out[n/2-1]==0;
}
static LONG setline(HKEY key,const WCHAR *text){
 LONG e=RegSetValueExW(key,L"CmdLine",0,REG_SZ,(const BYTE*)text,(lstrlenW(text)+1)*2);return e?e:RegFlushKey(key);
}
static LONG put(const WCHAR *path,const WCHAR *name,DWORD v){
 HKEY key=0;LONG e=RegCreateKeyExW(HKEY_LOCAL_MACHINE,path,0,0,0,KEY_QUERY_VALUE|KEY_SET_VALUE,0,&key,0);
 if(!e){e=RegSetValueExW(key,name,0,REG_DWORD,(BYTE*)&v,4);if(!e)e=RegFlushKey(key);
  DWORD actual=0;if(!e&&(!get(key,name,&actual)||actual!=v))e=ERROR_INVALID_DATA;RegCloseKey(key);}
 return e;
}
static DWORD child_state(HKEY setup){
 HKEY key=0;DWORD v=0xffffffff;
 if(!RegOpenKeyExW(setup,L"Status\\ChildCompletion",0,KEY_QUERY_VALUE,&key)){if(!get(key,L"setup.exe",&v))v=0xffffffff;RegCloseKey(key);}return v;
}
static void watch(HKEY setup){
 HANDLE unique=CreateMutexW(0,FALSE,L"Local\\USOSVistaOOBEWatcher");
 if(!unique||GetLastError()==ERROR_ALREADY_EXISTS)ExitProcess(ERROR_ALREADY_EXISTS);
 HANDLE event=CreateEventW(0,FALSE,FALSE,0),ready=OpenEventW(EVENT_MODIFY_STATE,FALSE,L"Local\\USOSVistaOOBEReady");
 if(!event||!ready)ExitProcess(ERROR_INVALID_HANDLE);
 BOOL seen=FALSE,announced=FALSE;static WCHAR current[MAX_PATH];
 for(;;){
  LONG e=RegNotifyChangeKeyValue(setup,TRUE,REG_NOTIFY_CHANGE_LAST_SET,event,TRUE);
  if(e){report("Setup notification failure=",e);ExitProcess(e);}
  DWORD active=1,oobe=0;
  BOOL known=get(setup,L"SystemSetupInProgress",&active)&&get(setup,L"OOBEInProgress",&oobe)&&line(setup,current);
  if(known&&oobe==1&&child_state(setup)==3){
   seen=TRUE;
   if(!lstrcmpiW(current,native)){e=setline(setup,self);report("Interrupted OOBE resume entry armed=",e);if(e)ExitProcess(e);}
  }
  if(known&&seen&&oobe==0&&active==0){
   if(!lstrcmpiW(current,self)){e=setline(setup,native);if(e)ExitProcess(e);}
   report("Native Windows finished OOBE; watcher leaving=",0);ExitProcess(0);
  }
  if(!announced){SetEvent(ready);CloseHandle(ready);announced=TRUE;}
  if(WaitForSingleObject(event,INFINITE)!=WAIT_OBJECT_0)ExitProcess(ERROR_INVALID_HANDLE);
 }
}
static BOOL start_watch(void){
 HANDLE existing=OpenMutexW(SYNCHRONIZE,FALSE,L"Local\\USOSVistaOOBEWatcher");
 if(existing){CloseHandle(existing);return TRUE;}
 HANDLE ready=CreateEventW(0,TRUE,FALSE,L"Local\\USOSVistaOOBEReady");if(!ready)return FALSE;
 ResetEvent(ready);static WCHAR cmd[MAX_PATH+32];lstrcpyW(cmd,L"\"");lstrcatW(cmd,self);lstrcatW(cmd,L"\" --watch");
 STARTUPINFOW si={sizeof(si)};PROCESS_INFORMATION pi={0};
 if(!CreateProcessW(self,cmd,0,0,FALSE,CREATE_NO_WINDOW,0,0,&si,&pi)){CloseHandle(ready);return FALSE;}
 CloseHandle(pi.hThread);HANDLE waits[]={ready,pi.hProcess};DWORD event=WaitForMultipleObjects(2,waits,FALSE,10000);
 BOOL ok=event==WAIT_OBJECT_0;
 if(event==WAIT_OBJECT_0+1){DWORD code=0;GetExitCodeProcess(pi.hProcess,&code);ok=code==ERROR_ALREADY_EXISTS;}
 CloseHandle(pi.hProcess);CloseHandle(ready);return ok;
}
static BOOL account(WCHAR *name,DWORD *count){
 DWORD resume=0,read=0,total=0;*count=0;
 do{
  USER_INFO_3 *users=0;NET_API_STATUS s=NetUserEnum(0,3,FILTER_NORMAL_ACCOUNT,(BYTE**)&users,MAX_PREFERRED_LENGTH,&read,&total,&resume);
  if(s!=NERR_Success&&s!=ERROR_MORE_DATA){if(users)NetApiBufferFree(users);return FALSE;}
  for(DWORD i=0;i<read;i++)if(users[i].usri3_user_id>=1000){
   if(users[i].usri3_flags&(UF_ACCOUNTDISABLE|UF_LOCKOUT)){NetApiBufferFree(users);return FALSE;}
   if(++*count==1){if(lstrlenW(users[i].usri3_name)>256){NetApiBufferFree(users);return FALSE;}lstrcpyW(name,users[i].usri3_name);}
  }
  if(users)NetApiBufferFree(users);if(s==NERR_Success)break;
 }while(resume);
 return TRUE;
}
static BOOL evidence(const WCHAR *user){
 static char encoded[1024];if(!WideCharToMultiByte(CP_UTF8,0,user,-1,encoded,sizeof(encoded),0,0))return FALSE;
 lstrcpyW(file,windows);lstrcatW(file,L"\\Panther\\UnattendGC\\setupact.log");
 HANDLE f=CreateFileW(file,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,0,OPEN_EXISTING,0,0);if(f==INVALID_HANDLE_VALUE)return FALSE;
 LARGE_INTEGER size;DWORD got=0;BOOL ok=FALSE;
 if(GetFileSizeEx(f,&size)&&size.QuadPart>0&&size.QuadPart<=8*1024*1024){
  char *bytes=LocalAlloc(LMEM_FIXED,(SIZE_T)size.QuadPart);
  if(bytes){if(ReadFile(f,bytes,(DWORD)size.QuadPart,&got,0)&&got==size.QuadPart)ok=vo_completed(bytes,got,encoded);LocalFree(bytes);}
 }CloseHandle(f);return ok;
}
static DWORD run(const WCHAR *path){
 STARTUPINFOW si={sizeof(si)};PROCESS_INFORMATION pi={0};DWORD result=ERROR_GEN_FAILURE;
 if(!CreateProcessW(path,0,0,0,FALSE,0,0,0,&si,&pi))return GetLastError();
 CloseHandle(pi.hThread);if(WaitForSingleObject(pi.hProcess,INFINITE)==WAIT_OBJECT_0)GetExitCodeProcess(pi.hProcess,&result);CloseHandle(pi.hProcess);return result;
}
/* No boot-time autochk on fixed volumes other than the system volume
 * (vista_autochk.h). Only the untouched Windows default is replaced; the
 * system volume keeps its check (runs only when dirty). Never fatal. */
static void limit_autochk(void){
 static const WCHAR sm[]=L"SYSTEM\\CurrentControlSet\\Control\\Session Manager";
 HKEY key=0;LONG e=RegOpenKeyExW(HKEY_LOCAL_MACHINE,sm,0,KEY_QUERY_VALUE|KEY_SET_VALUE,&key);
 if(e){report("Autochk: Session Manager not opened=",e);return;}
 static WCHAR current[512],wanted[128];DWORD type=0,bytes=sizeof(current);
 e=RegQueryValueExW(key,L"BootExecute",0,&type,(BYTE*)current,&bytes);
 DWORD mask=0,drives=GetLogicalDrives();
 for(unsigned d=2;d<26;d++)if(drives&(1u<<d)){WCHAR root[4]={(WCHAR)(L'A'+d),L':',L'\\',0};if(GetDriveTypeW(root)==DRIVE_FIXED)mask|=1u<<d;}
 report("Autochk: fixed drive letters (bit 2 = C:)=",mask);
 if(e||type!=REG_MULTI_SZ||!usos_autochk_is_default(current,bytes/2)){report("Autochk: BootExecute is not the Windows default; left unchanged=",e?e:ERROR_INVALID_DATA);}
 else{
  unsigned chars=usos_autochk_value(wanted,128,mask,windows[0]);
  if(!chars)report("Autochk: no other fixed volume with a letter; default kept=",0);
  else{
   e=RegSetValueExW(key,L"BootExecute",0,REG_MULTI_SZ,(const BYTE*)wanted,chars*2);if(!e)e=RegFlushKey(key);
   bytes=sizeof(current);if(!e&&(RegQueryValueExW(key,L"BootExecute",0,&type,(BYTE*)current,&bytes)||bytes!=chars*2))e=ERROR_INVALID_DATA;
   report("Autochk: other fixed volumes excluded (autocheck autochk /k:X *), readback=",e);
  }
 }
 /* The countdown before a (dirty-volume) check: 3 s instead of 10. */
 DWORD timeout=3;e=RegSetValueExW(key,L"AutoChkTimeout",0,REG_DWORD,(const BYTE*)&timeout,4);if(!e)e=RegFlushKey(key);
 report("Autochk: AutoChkTimeout = 3 s=",e);
 RegCloseKey(key);
}
void entry(void){
 static OSVERSIONINFOW os={sizeof(os)};
 if(!GetVersionExW(&os)||os.dwMajorVersion!=6||os.dwMinorVersion!=0||os.dwBuildNumber!=6002)ExitProcess(2);
 if(!GetWindowsDirectoryW(windows,MAX_PATH)||!GetModuleFileNameW(0,self,MAX_PATH))ExitProcess(2);
 lstrcpyW(file,L"C:\\USOS\\oobe.exe");file[0]=windows[0];if(lstrcmpiW(file,self))ExitProcess(2);
 static WCHAR watch_command[MAX_PATH+32];lstrcpyW(watch_command,L"\"");lstrcatW(watch_command,self);lstrcatW(watch_command,L"\" --watch");
 BOOL watcher=!lstrcmpW(GetCommandLineW(),watch_command);
 lstrcpyW(file,L"C:\\USOS\\");file[0]=windows[0];lstrcatW(file,watcher?L"oobe-watch.log":L"oobe-prep.log");
 log_file=CreateFileW(file,GENERIC_WRITE,FILE_SHARE_READ,0,OPEN_ALWAYS,FILE_FLAG_WRITE_THROUGH,0);if(log_file==INVALID_HANDLE_VALUE)ExitProcess(GetLastError());
 SetFilePointer(log_file,0,0,FILE_END);report("Vista OOBE gate v3 / guarded interruption recovery / autochk limited to the system volume=",0);
 HKEY setup=0;LONG error=RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SYSTEM\\Setup",0,KEY_QUERY_VALUE|KEY_SET_VALUE|KEY_NOTIFY,&setup);if(error)ExitProcess(error);
 if(watcher)watch(setup);
 DWORD active=0,oobe=0,phase=0;
 if(!get(setup,L"SystemSetupInProgress",&active)||!get(setup,L"OOBEInProgress",&oobe)||!get(setup,L"SetupPhase",&phase)||phase!=4)ExitProcess(3);
 DWORD child=child_state(setup);
 if(!(oobe==1&&child==3)&&!(active==1&&child==0))ExitProcess(3);
 error=put(L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\WinSAT",L"MOOBE",2);report("Automatic WinSAT guard readback=",error);if(error)ExitProcess(error);
 limit_autochk();
 if(oobe==1&&child==3){
  static WCHAR name[257];DWORD count=0;BOOL enumerated=account(name,&count),completed=enumerated&&count==1&&evidence(name);
  int decision=enumerated?vo_decide(oobe,child==3,count,completed):-1;
  report("Enabled non-builtin account count=",count);report("Mandatory OOBE task evidence=",completed);report("Recovery decision (FFFFFFFF = inspect logs)=",(DWORD)decision);
  if(decision<0){MessageBoxW(0,L"USOS: Nie mozna potwierdzic zakonczenia konfiguracji istniejacego konta. Nie tworz drugiego konta. Log: USOS\\oobe-prep.log. Zachowaj dysk do diagnostyki.",L"USOS - Vista recovery",MB_OK|MB_ICONWARNING);ExitProcess(ERROR_INVALID_DATA);}
  error=put(L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE",L"SkipMachineOOBE",decision==1?1:0);report("Native OOBE skip readback=",error);if(error)ExitProcess(error);
  if(!start_watch())ExitProcess(ERROR_NOT_READY);
  error=setline(setup,native);if(error)ExitProcess(error);
  lstrcpyW(file,windows);lstrcatW(file,L"\\System32\\oobe\\windeploy.exe");
 }else{
  if(!start_watch())ExitProcess(ERROR_NOT_READY);
  lstrcpyW(file,L"C:\\USOS\\usb.exe");file[0]=windows[0];
 }
 RegCloseKey(setup);DWORD result=run(file);report("Native bootstrap/deploy exit=",result);CloseHandle(log_file);ExitProcess(result);
}
