/* usos-run-hidden.exe: runs the answer commands of a USOS profile without a
 * console window (tools/windows_hidden_commands.h). GUI subsystem, no C
 * runtime, Vista and later.
 *
 *   usos-run-hidden.exe <command line>
 *       Windows Setup (specialize, windowsPE) runs this instead of the
 *       command: the command starts with CREATE_NO_WINDOW, stdout/stderr go
 *       to %WINDIR%\Panther\usos-hidden-commands.log with the command and its
 *       exit code, and the exit code is returned to Setup (which logs a
 *       failure as before). Run from the installed system's System32, the
 *       runner also marks itself for deletion at the next restart.
 *   usos-run-hidden.exe --wrap <in.xml> <out.xml>
 *       WinPE, before Setup: out = in with the commands prefixed. Exit 0
 *       written, 10 nothing to wrap (out not written: use in), 1 error.
 *   usos-run-hidden.exe --install <answer.xml> <usos-disk>
 *       WinPE, after Setup applied the image (/noreboot): copies this runner
 *       into System32 of the one Windows volume Setup wrote after <answer.xml>
 *       was written (SYSTEM hive or Panther\setupact.log newer), not on the
 *       USOS disk and not WinPE's own volume. Exit 0 copied and verified,
 *       3 no such volume, 4 more than one, 1 error. Messages on stdout.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winioctl.h>
#include "windows_hidden_commands.h"

static WCHAR self[MAX_PATH],a[MAX_PATH+64],b[MAX_PATH+64];
static WCHAR args[3][MAX_PATH];
static WCHAR line[32768];
static BYTE left[65536],right[65536];
static void zero(void *p,DWORD n){BYTE *q=p;while(n--)*q++=0;}
static unsigned len(const WCHAR *s){unsigned n=0;while(s[n])n++;return n;}
static void copy(WCHAR *d,const WCHAR *s){while((*d++=*s++));}
static void cat(WCHAR *d,const WCHAR *s){copy(d+len(d),s);}
static WCHAR up(WCHAR c){return c>='a'&&c<='z'?(WCHAR)(c-32):c;}
static int ieq(const WCHAR *p,const WCHAR *q){while(*p&&up(*p)==up(*q)){p++;q++;}return up(*p)==up(*q);}
static int prefix(const WCHAR *s,const WCHAR *p){while(*p)if(*s++!=*p++)return 0;return 1;}
static void say(const char *p){DWORD n=0,w;while(p[n])n++;WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),p,n,&w,0);}
static void sayw(const WCHAR *p){char o[600];unsigned i=0;while(p[i]&&i<sizeof(o)-1){o[i]=p[i]<128?(char)p[i]:'?';i++;}o[i]=0;say(o);}
static void decimal(char *out,DWORD v){char d[12];unsigned n=0;do{d[n++]=(char)('0'+v%10);v/=10;}while(v);unsigned i=0;while(n)out[i++]=d[--n];out[i]=0;}
static int winpe(void){HKEY k;if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SYSTEM\\CurrentControlSet\\Control\\MiniNT",0,KEY_READ,&k)!=ERROR_SUCCESS)return 0;RegCloseKey(k);return 1;}

static void log_text(HANDLE log,const char *text){DWORD n=0,w;while(text[n])n++;if(log!=INVALID_HANDLE_VALUE){WriteFile(log,text,n,&w,0);}}
static DWORD run(const WCHAR *command){
 SECURITY_ATTRIBUTES sa={sizeof(sa),0,TRUE};
 WCHAR logpath[MAX_PATH+48];UINT n=GetWindowsDirectoryW(logpath,MAX_PATH);
 HANDLE log=INVALID_HANDLE_VALUE;
 if(n&&n<MAX_PATH){cat(logpath,L"\\Panther");CreateDirectoryW(logpath,0);cat(logpath,L"\\usos-hidden-commands.log");
  log=CreateFileW(logpath,FILE_APPEND_DATA,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);}
 static char utf8[8192];
 int bytes=WideCharToMultiByte(CP_UTF8,0,command,-1,utf8,sizeof(utf8),0,0);
 log_text(log,"[USOS] run: ");log_text(log,bytes>0?utf8:"(command not representable)");log_text(log,"\r\n");
 HANDLE input=CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,OPEN_EXISTING,0,0);
 STARTUPINFOW si;PROCESS_INFORMATION pi;zero(&si,sizeof(si));zero(&pi,sizeof(pi));si.cb=sizeof(si);
 if(log!=INVALID_HANDLE_VALUE&&input!=INVALID_HANDLE_VALUE){si.dwFlags=STARTF_USESTDHANDLES;si.hStdInput=input;si.hStdOutput=si.hStdError=log;}
 copy(line,command);
 DWORD code;char number[12];
 if(CreateProcessW(0,line,0,0,si.dwFlags!=0,CREATE_NO_WINDOW,0,0,&si,&pi)){
  code=1;if(WaitForSingleObject(pi.hProcess,INFINITE)!=WAIT_OBJECT_0||!GetExitCodeProcess(pi.hProcess,&code))code=GetLastError();
  CloseHandle(pi.hThread);CloseHandle(pi.hProcess);
  decimal(number,code);log_text(log,"[USOS] exit=");log_text(log,number);log_text(log,"\r\n");
 }else{
  code=GetLastError();if(!code)code=1;
  decimal(number,code);log_text(log,"[USOS] the command could not be started, error=");log_text(log,number);log_text(log,"\r\n");
 }
 /* From the installed system's System32 (copied there by --install): gone
  * after the next restart; Setup runs no more commands after specialize. */
 if(!winpe()){
  WCHAR system[MAX_PATH+32];UINT s=GetSystemDirectoryW(system,MAX_PATH);
  if(s&&s<MAX_PATH){cat(system,L"\\" USOS_HIDDEN_RUNNER_W);
   if(ieq(system,self)){BOOL removed=MoveFileExW(self,0,MOVEFILE_DELAY_UNTIL_REBOOT);decimal(number,removed?0:GetLastError());
    log_text(log,"[USOS] runner removal at the next restart=");log_text(log,number);log_text(log,"\r\n");}}
 }
 if(input!=INVALID_HANDLE_VALUE)CloseHandle(input);
 if(log!=INVALID_HANDLE_VALUE){FlushFileBuffers(log);CloseHandle(log);}
 return code;
}

static int read_all(const WCHAR *file,char **data,DWORD *size){
 HANDLE f=CreateFileW(file,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(f==INVALID_HANDLE_VALUE)return 0;
 LARGE_INTEGER s;DWORD got=0;int ok=GetFileSizeEx(f,&s)&&s.QuadPart>0&&s.QuadPart<=1024*1024;
 char *p=ok?LocalAlloc(LMEM_FIXED,(SIZE_T)s.QuadPart):0;
 ok=p&&ReadFile(f,p,(DWORD)s.QuadPart,&got,0)&&got==s.QuadPart;CloseHandle(f);
 if(!ok){if(p)LocalFree(p);return 0;}*data=p;*size=got;return 1;
}
static DWORD wrap(const WCHAR *in,const WCHAR *out){
 char *text=0;DWORD size=0,wrapped=0;
 if(!read_all(in,&text,&size)){say("USOS hidden commands: cannot read the answer file\r\n");return 1;}
 DWORD cap=size+64*1024;char *result=LocalAlloc(LMEM_FIXED,cap);
 DWORD n=result?usos_hidden_wrap(text,size,result,cap,&wrapped):0;LocalFree(text);
 if(!n){if(result)LocalFree(result);say("USOS hidden commands: the answer file could not be processed\r\n");return 1;}
 if(!wrapped){LocalFree(result);say("USOS hidden commands: nothing to wrap (not a USOS profile answer, or no commands)\r\n");return 10;}
 HANDLE f=CreateFileW(out,GENERIC_WRITE,FILE_SHARE_READ,0,CREATE_ALWAYS,FILE_FLAG_WRITE_THROUGH,0);DWORD w=0;
 int ok=f!=INVALID_HANDLE_VALUE&&WriteFile(f,result,n,&w,0)&&w==n&&FlushFileBuffers(f);
 if(f!=INVALID_HANDLE_VALUE)CloseHandle(f);LocalFree(result);
 if(!ok){DeleteFileW(out);say("USOS hidden commands: cannot write the wrapped answer file\r\n");return 1;}
 char number[12];decimal(number,wrapped);say("USOS hidden commands: answer commands run without console windows: ");say(number);say("\r\n");
 return 0;
}

static int later(const FILETIME *t,const FILETIME *start){
 ULARGE_INTEGER x,y;x.LowPart=t->dwLowDateTime;x.HighPart=t->dwHighDateTime;y.LowPart=start->dwLowDateTime;y.HighPart=start->dwHighDateTime;return x.QuadPart>=y.QuadPart;
}
static int fresh(const WCHAR *volume,const WCHAR *file,const FILETIME *start){
 WIN32_FILE_ATTRIBUTE_DATA d;copy(a,volume);cat(a,file);return GetFileAttributesExW(a,GetFileExInfoStandard,&d)&&later(&d.ftLastWriteTime,start);
}
static int same_file(const WCHAR *p,const WCHAR *q){
 HANDLE x=CreateFileW(p,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0),y=CreateFileW(q,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);
 int ok=x!=INVALID_HANDLE_VALUE&&y!=INVALID_HANDLE_VALUE;
 LARGE_INTEGER xs,ys;if(ok)ok=GetFileSizeEx(x,&xs)&&GetFileSizeEx(y,&ys)&&xs.QuadPart>0&&xs.QuadPart==ys.QuadPart;
 while(ok){DWORD xn=0,yn=0;ok=ReadFile(x,left,sizeof(left),&xn,0)&&ReadFile(y,right,sizeof(right),&yn,0)&&xn==yn;for(DWORD i=0;ok&&i<xn;i++)if(left[i]!=right[i])ok=0;if(!xn)break;}
 if(x!=INVALID_HANDLE_VALUE)CloseHandle(x);if(y!=INVALID_HANDLE_VALUE)CloseHandle(y);return ok;
}
static DWORD parse_disk(const WCHAR *s){DWORD n=0;if(*s<'0'||*s>'9')return 0xFFFFFFFF;while(*s>='0'&&*s<='9'){n=n*10+(DWORD)(*s++-'0');if(n>100000)return 0xFFFFFFFF;}return *s?0xFFFFFFFF:n;}
static DWORD install(const WCHAR *answer,const WCHAR *disk_text){
 if(!winpe()){say("USOS hidden commands: --install runs only in WinPE\r\n");return 1;}
 DWORD usos_disk=parse_disk(disk_text);if(usos_disk==0xFFFFFFFF)return 1;
 WIN32_FILE_ATTRIBUTE_DATA d;if(!GetFileAttributesExW(answer,GetFileExInfoStandard,&d)){say("USOS hidden commands: the answer file is missing\r\n");return 1;}
 FILETIME start=d.ftLastWriteTime;
 /* WinPE's own volume (X:) holds a fresh SYSTEM hive and Panther log too. */
 WCHAR own[64]={0},windows[MAX_PATH];UINT w=GetWindowsDirectoryW(windows,MAX_PATH);
 if(w<3||w>=MAX_PATH)return 1;windows[3]=0;GetVolumeNameForVolumeMountPointW(windows,own,64);
 static WCHAR found[64];unsigned count=0;WCHAR name[64];
 HANDLE find=FindFirstVolumeW(name,64);if(find==INVALID_HANDLE_VALUE)return 1;
 do{
  unsigned n=len(name);if(n<5||name[n-1]!='\\'||ieq(name,own))continue;
  DWORD got_paths=0;int winpe_volume=0;
  if(GetVolumePathNamesForVolumeNameW(name,line,sizeof(line)/sizeof(line[0]),&got_paths))
   for(WCHAR *p=line;*p;p+=len(p)+1)if(ieq(p,windows))winpe_volume=1;
  if(winpe_volume)continue;
  copy(a,name);a[n-1]=0;HANDLE h=CreateFileW(a,0,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_EXISTING,0,0);if(h==INVALID_HANDLE_VALUE)continue;
  STORAGE_DEVICE_NUMBER number;DWORD got=0;
  int disk=DeviceIoControl(h,IOCTL_STORAGE_GET_DEVICE_NUMBER,0,0,&number,sizeof(number),&got,0)&&number.DeviceType==FILE_DEVICE_DISK;CloseHandle(h);
  if(!disk||number.DeviceNumber==usos_disk)continue;
  copy(a,name);cat(a,L"Windows\\System32\\config\\SOFTWARE");if(GetFileAttributesW(a)==INVALID_FILE_ATTRIBUTES)continue;
  if(!fresh(name,L"Windows\\System32\\config\\SYSTEM",&start)&&!fresh(name,L"Windows\\Panther\\setupact.log",&start))continue;
  copy(found,name);count++;
 }while(FindNextVolumeW(find,name,64));
 FindVolumeClose(find);
 if(count!=1){say(count?"USOS hidden commands: more than one Windows volume was written by this Setup; the runner was not installed\r\n":"USOS hidden commands: no Windows volume written by this Setup; the runner was not installed\r\n");return count?4:3;}
 copy(b,found);cat(b,L"Windows\\System32\\" USOS_HIDDEN_RUNNER_W);
 if(!CopyFileW(self,b,FALSE)||!same_file(self,b)){say("USOS hidden commands: cannot copy the runner to the installed Windows\r\n");return 1;}
 HANDLE f=CreateFileW(b,GENERIC_WRITE,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(f==INVALID_HANDLE_VALUE)return 1;
 BOOL flushed=FlushFileBuffers(f);CloseHandle(f);if(!flushed)return 1;
 say("USOS hidden commands: runner installed on ");sayw(found);say("\r\n");
 return 0;
}

/* Splits "--mode a b" (quoted arguments allowed) into args; returns the count. */
static unsigned split(const WCHAR *s){
 unsigned count=0;
 while(*s){while(*s==' '||*s=='\t')s++;if(!*s)break;if(count==3)return 4;int quote=0;unsigned n=0;
  while(*s&&(quote||(*s!=' '&&*s!='\t'))){if(*s=='"'){quote=!quote;s++;continue;}if(n+1>=MAX_PATH)return 4;args[count][n++]=*s++;}
  if(quote)return 4;args[count++][n]=0;}
 return count;
}
void entry(void){
 SetErrorMode(SEM_FAILCRITICALERRORS|SEM_NOOPENFILEERRORBOX);
 DWORD n=GetModuleFileNameW(0,self,MAX_PATH);if(!n||n>=MAX_PATH)ExitProcess(1);
 /* The command line after this program's own name, exactly as given. */
 const WCHAR *c=GetCommandLineW();int quote=0;
 while(*c){if(*c=='"')quote=!quote;else if((*c==' '||*c=='\t')&&!quote)break;c++;}
 while(*c==' '||*c=='\t')c++;
 if(!*c)ExitProcess(ERROR_INVALID_PARAMETER);
 if(prefix(c,L"--wrap ")){if(split(c)!=3)ExitProcess(1);ExitProcess(wrap(args[1],args[2]));}
 if(prefix(c,L"--install ")){if(split(c)!=3)ExitProcess(1);ExitProcess(install(args[1],args[2]));}
 if(len(c)>=sizeof(line)/sizeof(line[0]))ExitProcess(ERROR_INVALID_PARAMETER);
 ExitProcess(run(c));
}
