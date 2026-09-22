/* Quiet WinPE shell: no console on success, explicit diagnostics on failure.
 * All files are beside this injected executable in the WinPE RAM image.
 * No CRT dependency, including on original Vista/Windows 7 installation media.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static WCHAR base[MAX_PATH], cmd[MAX_PATH], script[MAX_PATH], logpath[MAX_PATH], line[2048];
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
 static char message[80]="\r\n[USOS] startup-exit-code=";unsigned at=0;while(message[at])at++;WCHAR digits[12];decimal(digits,code);for(unsigned i=0;digits[i];i++)message[at++]=(char)digits[i];message[at++]='\r';message[at++]='\n';DWORD written=0;WriteFile(log,message,at,&written,0);FlushFileBuffers(log);
 CloseHandle(input);CloseHandle(log);export_logs();return code?1:0;
}
static void diagnostics(void){
 if(MessageBoxW(0,L"Windows Setup could not start or returned an error.\nUSOS attempted to save diagnostics to EFI\\USOS\\Logs on the source USB.\nIf USB logging was unavailable, the log remains in WinPE RAM.\nOpen the diagnostic log and command prompt?",L"USOS - Windows Setup",MB_YESNO|MB_ICONERROR|MB_SETFOREGROUND)!=IDYES)return;
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
 SetErrorMode(SEM_FAILCRITICALERRORS|SEM_NOOPENFILEERRORBOX);
 WCHAR pid[12];decimal(pid,GetCurrentProcessId());SetEnvironmentVariableW(L"USOS_LAUNCHER_PID",pid);
 int result=launch_script();if(result)diagnostics();ExitProcess(result);
}
