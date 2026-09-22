/* Run the USB helper before windeploy; no dependency on specialize succeeding. */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0600
#include <windows.h>
static HANDLE log_file=INVALID_HANDLE_VALUE;
static void output(const char *text,DWORD length){
 DWORD n;WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),text,length,&n,0);
 if(log_file!=INVALID_HANDLE_VALUE){
  if(!WriteFile(log_file,text,length,&n,0)||n!=length||!FlushFileBuffers(log_file)){
   static const char failed[]="USOS: writing diagnostic log failed.\r\n";
   WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),failed,sizeof(failed)-1,&n,0);
  }
 }
}
static void logcode(const char *label,DWORD code){
 char h[13]="0x00000000\r\n";
 for(unsigned i=0;i<8;i++)h[9-i]="0123456789abcdef"[(code>>(i*4))&15];
 output(label,lstrlenA(label));output(h,12);
}
static DWORD run(const WCHAR *file){
 static STARTUPINFOW si;static PROCESS_INFORMATION pi;
 si.cb=sizeof(si);
 if(!CreateProcessW(file,0,0,0,FALSE,0,0,0,&si,&pi)){DWORD e=GetLastError();logcode("CreateProcess error=",e);return 0xffffffff;}
 CloseHandle(pi.hThread);DWORD code=0xffffffff;
 WaitForSingleObject(pi.hProcess,INFINITE);GetExitCodeProcess(pi.hProcess,&code);CloseHandle(pi.hProcess);return code;
}
void entry(void){
 static OSVERSIONINFOW v={sizeof(v)};static WCHAR exe[MAX_PATH],dir[MAX_PATH],helper[MAX_PATH],logpath[MAX_PATH],deploy[MAX_PATH];
 if(!GetVersionExW(&v)||v.dwMajorVersion!=6||v.dwMinorVersion!=0||v.dwBuildNumber!=6002)ExitProcess(2);
 if(!GetWindowsDirectoryW(dir,MAX_PATH)||!GetModuleFileNameW(0,exe,MAX_PATH)||exe[0]!=dir[0])ExitProcess(3);
 SetConsoleTitleW(L"USOS - Vista USB diagnostics");
 lstrcpyW(logpath,L"D:\\USOS\\usb-bootstrap.log");logpath[0]=dir[0];
 log_file=CreateFileW(logpath,GENERIC_WRITE,FILE_SHARE_READ,0,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_WRITE_THROUGH,0);
 if(log_file!=INVALID_HANDLE_VALUE)SetFilePointer(log_file,0,0,FILE_END);
 logcode("USOS USB-before-Setup v8 persistent publisher trust, Vista build=",v.dwBuildNumber);
 HKEY setup;DWORD active=0,size=sizeof(active),type=0;
 LONG status=RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SYSTEM\\Setup",0,KEY_READ|KEY_SET_VALUE,&setup);
 if(status!=ERROR_SUCCESS){logcode("Cannot open Setup=",status);ExitProcess(4);}
 if(RegQueryValueExW(setup,L"SystemSetupInProgress",0,&type,(BYTE*)&active,&size)!=ERROR_SUCCESS||type!=REG_DWORD||active!=1){logcode("Setup is not active=",active);ExitProcess(5);}
 lstrcpyW(helper,L"D:\\USOS\\Vista\\usos-vista-kmdf.exe");helper[0]=dir[0];
 lstrcpyW(deploy,dir);lstrcatW(deploy,L"\\system32\\oobe\\windeploy.exe");
 logcode("Checking/installing Microsoft KMDF BEFORE USB=",0);
 DWORD usb=run(helper);logcode("KMDF prerequisite exit=",usb);
 if(usb==ERROR_SUCCESS_REBOOT_REQUIRED){
  /* SetupType can be consumed/reset during the servicing boot. CmdLine alone
   * does not resume this entry: re-arm both values before requesting reboot. */
  DWORD resume_type=2;
  status=RegSetValueExW(setup,L"CmdLine",0,REG_SZ,(const BYTE*)exe,(lstrlenW(exe)+1)*sizeof(WCHAR));
  if(status==ERROR_SUCCESS)status=RegSetValueExW(setup,L"SetupType",0,REG_DWORD,(const BYTE*)&resume_type,sizeof(resume_type));
  if(status==ERROR_SUCCESS)status=RegFlushKey(setup);
  logcode("Re-arm pre-Setup entry after package servicing=",status);
  if(status!=ERROR_SUCCESS){RegCloseKey(setup);ExitProcess(status);}
  HANDLE token=0;TOKEN_PRIVILEGES privilege={0};BOOL reboot=FALSE;
  if(OpenProcessToken(GetCurrentProcess(),TOKEN_ADJUST_PRIVILEGES|TOKEN_QUERY,&token)){
   privilege.PrivilegeCount=1;
   if(LookupPrivilegeValueW(0,L"SeShutdownPrivilege",&privilege.Privileges[0].Luid)){
    privilege.Privileges[0].Attributes=SE_PRIVILEGE_ENABLED;
    if(AdjustTokenPrivileges(token,FALSE,&privilege,0,0,0)&&GetLastError()==ERROR_SUCCESS){
     RegFlushKey(setup);
     reboot=InitiateSystemShutdownExW(0,L"USOS: restart after Microsoft KMDF update; USB and Setup follow on next boot.",10,TRUE,TRUE,0x80000000);
    }
   }
   CloseHandle(token);
  }
  logcode("KMDF restart request=",reboot?0:GetLastError());
  if(reboot){RegCloseKey(setup);HANDLE hold=CreateEventW(0,TRUE,FALSE,0);if(hold)WaitForSingleObject(hold,INFINITE);ExitProcess(3010);}
 }
 if(usb==ERROR_SUCCESS){
  lstrcpyW(helper,L"D:\\USOS\\Vista\\usos-vista-trust.exe");helper[0]=dir[0];
  logcode("Persisting certificate stores BEFORE USB helper process=",0);
  usb=run(helper);logcode("Machine trust preparation exit=",usb);
 }
 if(usb==ERROR_SUCCESS){
  lstrcpyW(helper,L"D:\\USOS\\Vista\\usos-vista-firstboot.exe");helper[0]=dir[0];
  logcode("Starting USB helper BEFORE Windows Setup=",0);
  usb=run(helper);logcode("USB helper exit=",usb);
 }
 if(usb!=ERROR_SUCCESS){
  DWORD retry_type=2;
  LONG retry_status=RegSetValueExW(setup,L"SetupType",0,REG_DWORD,(const BYTE*)&retry_type,sizeof(retry_type));
  if(retry_status==ERROR_SUCCESS)retry_status=RegFlushKey(setup);
  logcode("Preserve USB retry entry after failure=",retry_status);
  static const char stopped[]="\r\nUSB IS NOT READY - WINDOWS SETUP HAS NOT STARTED.\r\n"
   "Connect a USB keyboard AND mouse directly to the motherboard.\r\n"
   "Log: D:\\USOS\\Vista\\firstboot-usb.log\r\n"
   "Photograph this screen. Shut down before reconnecting the Intel SSD.\r\n";
  output(stopped,sizeof(stopped)-1);RegCloseKey(setup);
  /* Keep the pre-Setup entry for the next manually requested boot. No automatic
   * reboot, no 15-second fall-through into a failed specialize pass. */
  HANDLE hold=CreateEventW(0,TRUE,FALSE,0);
  if(hold)WaitForSingleObject(hold,INFINITE);
  ExitProcess(usb);
 }
 /* Only hand back to Windows once controller AND input devnodes are started. */
 static const WCHAR normal[]=L"oobe\\windeploy.exe";
 status=RegSetValueExW(setup,L"CmdLine",0,REG_SZ,(const BYTE*)normal,sizeof(normal));
 logcode("Restore windeploy entry=",status);
 if(status!=ERROR_SUCCESS)ExitProcess(7);
 DWORD normal_type=0;
 status=RegSetValueExW(setup,L"SetupType",0,REG_DWORD,(const BYTE*)&normal_type,sizeof(normal_type));
 logcode("Restore SetupType=",status);RegFlushKey(setup);RegCloseKey(setup);
 if(status!=ERROR_SUCCESS)ExitProcess(7);
 logcode("USB controller, keyboard and mouse started; launching Setup=",0);
 logcode("Starting windeploy=",0);
 DWORD result=run(deploy);logcode("Windeploy exit=",result);CloseHandle(log_file);ExitProcess(result);
}
