/* Recovery for the existing Vista SP2 test account only, never fresh setup. */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0600
#include <windows.h>
#include <lm.h>
static HANDLE log_file=INVALID_HANDLE_VALUE;
static void report(const char *label,DWORD value){
 DWORD n;char hex[13]="0x00000000\r\n";
 for(unsigned i=0;i<8;i++)hex[9-i]="0123456789abcdef"[(value>>(4*i))&15];
 if(log_file!=INVALID_HANDLE_VALUE){WriteFile(log_file,label,lstrlenA(label),&n,0);WriteFile(log_file,hex,12,&n,0);FlushFileBuffers(log_file);}
}
static BOOL value(HKEY key,const WCHAR *name,DWORD expected){
 DWORD n=4,type=0,v=0;
 return RegQueryValueExW(key,name,0,&type,(BYTE*)&v,&n)==ERROR_SUCCESS&&type==REG_DWORD&&n==4&&v==expected;
}
static LONG put(const WCHAR *path,const WCHAR *name,DWORD v){
 HKEY key=0;LONG status=RegCreateKeyExW(HKEY_LOCAL_MACHINE,path,0,0,0,KEY_QUERY_VALUE|KEY_SET_VALUE,0,&key,0);
 if(!status){status=RegSetValueExW(key,name,0,REG_DWORD,(BYTE*)&v,4);
  if(!status)status=RegFlushKey(key);
  if(!status&&!value(key,name,v))status=ERROR_INVALID_DATA;
  RegCloseKey(key);
 }return status;
}
void entry(void){
 static OSVERSIONINFOW os={sizeof(os)};static WCHAR windows[MAX_PATH],self[MAX_PATH],file[MAX_PATH],old[MAX_PATH];
 if(!GetVersionExW(&os)||os.dwMajorVersion!=6||os.dwMinorVersion!=0||os.dwBuildNumber!=6002)ExitProcess(2);
 if(!GetWindowsDirectoryW(windows,MAX_PATH)||!GetModuleFileNameW(0,self,MAX_PATH))ExitProcess(2);
 lstrcpyW(file,L"C:\\USOS\\end.exe");file[0]=windows[0];if(lstrcmpiW(file,self))ExitProcess(2);
 lstrcpyW(file,L"C:\\USOS\\oobe-resume.log");file[0]=windows[0];
 log_file=CreateFileW(file,GENERIC_WRITE,FILE_SHARE_READ,0,OPEN_ALWAYS,FILE_FLAG_WRITE_THROUGH,0);
 if(log_file==INVALID_HANDLE_VALUE)ExitProcess(GetLastError());
 SetFilePointer(log_file,0,0,FILE_END);report("Vista existing-account OOBE resume v2=",0);
 HKEY setup=0;LONG status=RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SYSTEM\\Setup",0,KEY_QUERY_VALUE|KEY_SET_VALUE,&setup);
 if(status){report("Open Setup=",status);ExitProcess(status);}
 DWORD type=0,n=sizeof(old);
 /* Winlogon may consume SetupType before dispatching CmdLine. OOBE state and
  * the already-completed setup child are the relevant runtime boundaries. */
 if((!value(setup,L"SystemSetupInProgress",0)&&!value(setup,L"SystemSetupInProgress",1))||!value(setup,L"OOBEInProgress",1)||!value(setup,L"SetupPhase",4)||
    RegQueryValueExW(setup,L"CmdLine",0,&type,(BYTE*)old,&n)||type!=REG_SZ||n>sizeof(old)||old[MAX_PATH-1]||lstrcmpiW(old,self)){
  report("Unexpected Setup state; no changes=",ERROR_INVALID_DATA);ExitProcess(3);
 }
 HKEY children=0;status=RegOpenKeyExW(setup,L"Status\\ChildCompletion",0,KEY_QUERY_VALUE,&children);
 if(status||!value(children,L"setup.exe",3)){report("Setup child not completed=",ERROR_INVALID_DATA);ExitProcess(3);}
 RegCloseKey(children);
 USER_INFO_1 *user=0;status=NetUserGetInfo(0,L"test",1,(BYTE**)&user);
 report("Existing test account query=",status);
 if(status||!user)ExitProcess(4);
 BOOL enabled=(user->usri1_flags&UF_ACCOUNTDISABLE)==0;NetApiBufferFree(user);
 if(!enabled){report("Existing account disabled=",ERROR_ACCESS_DENIED);ExitProcess(4);}
 status=put(L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\WinSAT",L"MOOBE",2);
 report("Automatic WinSAT guard readback=",status);if(status)ExitProcess(status);
 /* msoobe.exe 6002 reads this DWORD directly before creating its UI. The
  * already processed Panther answer file does not reliably reach this read. */
 status=put(L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE",L"SkipMachineOOBE",1);
 report("Native SkipMachineOOBE readback=",status);if(status)ExitProcess(status);
 static const WCHAR normal[]=L"oobe\\windeploy.exe";
 status=RegSetValueExW(setup,L"CmdLine",0,REG_SZ,(const BYTE*)normal,sizeof(normal));
 if(!status)status=RegFlushKey(setup);RegCloseKey(setup);
 report("Restore native windeploy entry=",status);if(status)ExitProcess(status);
 lstrcpyW(file,windows);lstrcatW(file,L"\\System32\\oobe\\windeploy.exe");
 static STARTUPINFOW si={sizeof(si)};static PROCESS_INFORMATION pi;
 if(!CreateProcessW(file,0,0,0,FALSE,0,0,0,&si,&pi)){report("Native windeploy launch=",GetLastError());ExitProcess(5);}
 CloseHandle(pi.hThread);DWORD result=ERROR_GEN_FAILURE;
 if(WaitForSingleObject(pi.hProcess,INFINITE)==WAIT_OBJECT_0)GetExitCodeProcess(pi.hProcess,&result);
 CloseHandle(pi.hProcess);report("Native windeploy exit=",result);CloseHandle(log_file);ExitProcess(result);
}
