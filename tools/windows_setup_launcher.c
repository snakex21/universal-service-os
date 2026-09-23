/* Quiet WinPE shell: no console on success, explicit diagnostics on failure.
 * All files are beside this injected executable in the WinPE RAM image.
 * No CRT dependency, including on original Vista/Windows 7 installation media.
 *
 * When the startup script fails, a user who cancelled Windows Setup gets a
 * localized "installation cancelled" dialog (restart / shut down / command
 * prompt) instead of the diagnostic one. Cancel is recognized only when
 * Setup itself ran (usos-setup-result.txt, written by the helper that
 * started setup.exe) and its Panther logs show a cancel and no error; see
 * setup_cancelled(). */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#define USOS_UI_DIALOG
#include "windows_winpe_ui.h"

static WCHAR base[MAX_PATH], cmd[MAX_PATH], script[MAX_PATH], logpath[MAX_PATH], line[2048];
static WCHAR message_text[2048];
static BYTE scan[65536 + 64];
static DWORD script_code = 1;
static unsigned len(const WCHAR *s){unsigned n=0;while(s[n])n++;return n;}
static void copy(WCHAR *d,const WCHAR *s){while((*d++=*s++));}
static void append(WCHAR *d,const WCHAR *s){copy(d+len(d),s);}
static void zero(void *p,unsigned n){BYTE *b=p;while(n--)*b++=0;}
static void decimal(WCHAR *out,DWORD value){WCHAR digits[12];unsigned n=0;do{digits[n++]='0'+value%10;value/=10;}while(value);unsigned i=0;while(n)out[i++]=digits[--n];out[i]=0;}
static void export_logs(void){
 WCHAR helper[MAX_PATH];copy(helper,base);
#ifdef _WIN64
 append(helper,L"usos-log-x86_64.exe");
#else
 append(helper,L"usos-log-x86.exe");
#endif
 STARTUPINFOW si;PROCESS_INFORMATION pi;zero(&si,sizeof(si));si.cb=sizeof(si);
 if(CreateProcessW(helper,0,0,0,FALSE,CREATE_NO_WINDOW,0,base,&si,&pi)){WaitForSingleObject(pi.hProcess,INFINITE);CloseHandle(pi.hThread);CloseHandle(pi.hProcess);}
}
static void log_append(const char *text,const char *suffix,DWORD value,int with_value){
 HANDLE log=CreateFileW(logpath,FILE_APPEND_DATA,FILE_SHARE_READ,0,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
 if(log==INVALID_HANDLE_VALUE)return;
 static char out[256];unsigned at=0;
 while(*text&&at<200)out[at++]=*text++;
 while(suffix&&*suffix&&at<230)out[at++]=*suffix++;
 if(with_value){WCHAR digits[12];decimal(digits,value);for(unsigned i=0;digits[i];i++)out[at++]=(char)digits[i];}
 out[at++]='\r';out[at++]='\n';
 DWORD written=0;WriteFile(log,out,at,&written,0);FlushFileBuffers(log);CloseHandle(log);
}
static int launch_script(void){
 SECURITY_ATTRIBUTES sa={sizeof(sa),0,TRUE};
 HANDLE log=CreateFileW(logpath,GENERIC_WRITE,FILE_SHARE_READ,&sa,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
 HANDLE input=CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,OPEN_EXISTING,0,0);
 if(log==INVALID_HANDLE_VALUE||input==INVALID_HANDLE_VALUE){if(log!=INVALID_HANDLE_VALUE)CloseHandle(log);if(input!=INVALID_HANDLE_VALUE)CloseHandle(input);return 1;}
 line[0]=0;append(line,L"\"");append(line,cmd);append(line,L"\" /d /s /c \"\"");append(line,script);append(line,L"\"\"");
 STARTUPINFOW si;PROCESS_INFORMATION pi;zero(&si,sizeof(si));si.cb=sizeof(si);
 si.dwFlags=STARTF_USESTDHANDLES;si.hStdInput=input;si.hStdOutput=si.hStdError=log;
 BOOL ok=CreateProcessW(cmd,line,0,0,TRUE,CREATE_NO_WINDOW,0,base,&si,&pi);
 DWORD code=1;
 if(ok){if(WaitForSingleObject(pi.hProcess,INFINITE)==WAIT_OBJECT_0)GetExitCodeProcess(pi.hProcess,&code);CloseHandle(pi.hThread);CloseHandle(pi.hProcess);}
 script_code=code;
 static char message[80]="\r\n[USOS] startup-exit-code=";unsigned at=0;while(message[at])at++;WCHAR digits[12];decimal(digits,code);for(unsigned i=0;digits[i];i++)message[at++]=(char)digits[i];message[at++]='\r';message[at++]='\n';DWORD written=0;WriteFile(log,message,at,&written,0);FlushFileBuffers(log);
 CloseHandle(input);CloseHandle(log);return code?1:0;
}

/* usos-setup-result.txt: "exit=<decimal>" from the helper that ran setup.exe. */
static int setup_exit(DWORD *code){
 WCHAR path[MAX_PATH];copy(path,base);append(path,L"usos-setup-result.txt");
 HANDLE file=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);
 if(file==INVALID_HANDLE_VALUE)return 0;
 char text[32];DWORD got=0;BOOL ok=ReadFile(file,text,sizeof(text)-1,&got,0);CloseHandle(file);
 if(!ok||got<6||text[0]!='e'||text[1]!='x'||text[2]!='i'||text[3]!='t'||text[4]!='=')return 0;
 DWORD value=0;unsigned i=5,digits=0;
 while(i<got&&text[i]>='0'&&text[i]<='9'&&digits<10){value=value*10+(DWORD)(text[i]-'0');i++;digits++;}
 if(!digits)return 0;
 *code=value;return 1;
}
static int file_nonempty(const WCHAR *path){
 WIN32_FILE_ATTRIBUTE_DATA data;
 if(!GetFileAttributesExW(path,GetFileExInfoStandard,&data))return 0;
 return data.nFileSizeHigh||data.nFileSizeLow;
}
/* True when the ASCII needle occurs in the file (streamed, any size). */
static int file_contains(const WCHAR *path,const char *needle){
 unsigned n=0;while(needle[n])n++;
 HANDLE file=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,0,OPEN_EXISTING,0,0);
 if(file==INVALID_HANDLE_VALUE)return 0;
 unsigned keep=0;int found=0;
 for(;;){
  DWORD got=0;
  if(!ReadFile(file,scan+keep,65536,&got,0)||!got)break;
  unsigned total=keep+got;
  for(unsigned i=0;i+n<=total&&!found;i++){unsigned j=0;while(j<n&&scan[i+j]==(BYTE)needle[j])j++;if(j==n)found=1;}
  if(found)break;
  keep=n-1<total?n-1:total;
  for(unsigned i=0;i<keep;i++)scan[i]=scan[total-keep+i];
 }
 CloseHandle(file);return found;
}
/* Windows Setup that the user closed ("Cancel" / window close, confirmed)
 * versus Setup that failed. Evidence, in order:
 *  - Setup must have run: usos-setup-result.txt exists; otherwise USOS
 *    itself failed before or after Setup and the diagnostics are shown.
 *  - Panther setupact.log records the cancel ("Accepting Cancel", the UI
 *    module's entry when the user leaves a page through Cancel/close).
 *  - Or: Setup returned a small non-zero code (not an NTSTATUS/HRESULT
 *    failure) and wrote no error at all: X:\Windows\Panther\setuperr.log
 *    and every <drive>:\$WINDOWS.~BT\Sources\Panther\setuperr.log are empty
 *    or absent. Real failures (e.g. Vista's 0x1F) log to setuperr.log. */
static int setup_cancelled(DWORD *setup_code,const char **reason){
 *reason="setup-not-run";
 if(!setup_exit(setup_code))return 0;
 WCHAR windows[MAX_PATH],act[MAX_PATH],err[MAX_PATH];
 UINT n=GetWindowsDirectoryW(windows,MAX_PATH);if(!n||n>=MAX_PATH-40)return 0;
 copy(act,windows);append(act,L"\\Panther\\setupact.log");
 copy(err,windows);append(err,L"\\Panther\\setuperr.log");
 if(file_contains(act,"Accepting Cancel")){*reason="panther-cancel";return 1;}
 *reason="setup-returned-success";
 if(*setup_code==0)return 0;
 *reason="setup-failure-code";
 if(*setup_code>=0x80000000u)return 0;
 *reason="setup-did-not-log";
 if(GetFileAttributesW(act)==INVALID_FILE_ATTRIBUTES)return 0;
 *reason="setuperr-not-empty";
 if(file_nonempty(err))return 0;
 DWORD drives=GetLogicalDrives();
 for(unsigned i=2;i<26;i++)if(drives&(1u<<i)){
  WCHAR path[64];path[0]=(WCHAR)('A'+i);path[1]=':';path[2]='\\';path[3]=0;
  append(path,L"$WINDOWS.~BT\\Sources\\Panther\\setuperr.log");
  if(file_nonempty(path))return 0;
 }
 *reason="no-setup-error";
 return 1;
}
static void run_wait(WCHAR *command_line,DWORD flags){
 STARTUPINFOW si;PROCESS_INFORMATION pi;zero(&si,sizeof(si));si.cb=sizeof(si);
 if(CreateProcessW(0,command_line,0,0,FALSE,flags,0,base,&si,&pi)){WaitForSingleObject(pi.hProcess,INFINITE);CloseHandle(pi.hThread);CloseHandle(pi.hProcess);}
}
static void wpeutil(const WCHAR *verb){
 WCHAR exe[MAX_PATH];UINT n=GetSystemDirectoryW(exe,MAX_PATH);if(!n||n>=MAX_PATH-16)return;append(exe,L"\\wpeutil.exe");
 line[0]=0;append(line,L"\"");append(line,exe);append(line,L"\" ");append(line,verb);
 run_wait(line,CREATE_NO_WINDOW);
}
static void command_prompt(void){
 line[0]=0;append(line,L"\"");append(line,cmd);append(line,L"\" /d /k cd /d X:\\");
 run_wait(line,CREATE_NEW_CONSOLE);
}
static void cancelled(void){
 for(;;){
  int choice=usos_ui_dialog(USOS_UI_TEXT(CANCELLED),USOS_UI_TEXT(SETUP_TITLE),MB_YESNOCANCEL|MB_ICONINFORMATION|MB_DEFBUTTON1,
   USOS_UI_TEXT(RESTART),USOS_UI_TEXT(SHUTDOWN),USOS_UI_TEXT(COMMAND_PROMPT));
  if(choice==IDYES){log_append("[USOS] user-choice=restart",0,0,0);export_logs();wpeutil(L"reboot");}
  else if(choice==IDNO){log_append("[USOS] user-choice=shutdown",0,0,0);export_logs();wpeutil(L"shutdown");}
  else command_prompt();
 }
}
static void diagnostics(void){
 usos_ui_format(message_text,sizeof(message_text)/sizeof(WCHAR),USOS_UI_TEXT(FAILED),script_code);
 if(usos_ui_dialog(message_text,USOS_UI_TEXT(SETUP_TITLE),MB_YESNO|MB_ICONERROR,USOS_UI_TEXT(YES),USOS_UI_TEXT(NO),0)!=IDYES)return;
 line[0]=0;append(line,L"\"");append(line,cmd);append(line,L"\" /d /k type \"");append(line,logpath);append(line,L"\"");
 STARTUPINFOW si;PROCESS_INFORMATION pi;zero(&si,sizeof(si));si.cb=sizeof(si);
 if(CreateProcessW(cmd,line,0,0,FALSE,CREATE_NEW_CONSOLE,0,base,&si,&pi)){WaitForSingleObject(pi.hProcess,INFINITE);CloseHandle(pi.hThread);CloseHandle(pi.hProcess);}
}
void entry(void){
 HKEY key;
 if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SYSTEM\\CurrentControlSet\\Control\\MiniNT",0,KEY_READ,&key)!=ERROR_SUCCESS){ExitProcess(1);}
 RegCloseKey(key);
 unsigned n=GetModuleFileNameW(0,base,MAX_PATH);
 if(!n||n>=MAX_PATH-32)ExitProcess(1);
 while(n&&base[n-1]!='\\')n--;base[n]=0;if(!n)ExitProcess(1);
 n=GetSystemDirectoryW(cmd,MAX_PATH);if(!n||n>=MAX_PATH-12)ExitProcess(1);append(cmd,L"\\cmd.exe");
 copy(script,base);append(script,L"usos-start.cmd");
 copy(logpath,base);append(logpath,L"usos-startup.log");
 WCHAR stale[MAX_PATH];copy(stale,base);append(stale,L"usos-setup-result.txt");DeleteFileW(stale);
 SetErrorMode(SEM_FAILCRITICALERRORS|SEM_NOOPENFILEERRORBOX);
 WCHAR pid[12];decimal(pid,GetCurrentProcessId());SetEnvironmentVariableW(L"USOS_LAUNCHER_PID",pid);
 int result=launch_script();
 if(result){
  DWORD setup_code=0;const char *reason="";
  int user_cancel=setup_cancelled(&setup_code,&reason);
  log_append(user_cancel?"[USOS] setup-cancelled-by-user=1 reason=":"[USOS] setup-cancelled-by-user=0 reason=",reason,0,0);
  log_append("[USOS] setup-exe-exit-code=",0,setup_code,1);
  export_logs();
  if(user_cancel)cancelled();
  diagnostics();
 }else export_logs();
 ExitProcess(result);
}
