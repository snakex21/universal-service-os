/* Own windowless test-only NT4 first-logon and NET runner, GPL-3.0-or-later.
 * All data beside this executable. Only the two exact own OS autostart
 * values are removed. No profile, account, credential or registry dump.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "observer_core.h"
static char directory[MAX_PATH];
static const char *states[]={"INVALID","ARM_ABSENT","STAGING_FAILED","HOOK_CLEANUP_FAILED",
 "ARM_CLEANUP_FAILED","FIRSTLO_FAILED","READY","NOT_READY","TESTNET_FAILED","TESTNET_DONE"};
static void zero(void *p,DWORD n){BYTE *b=p;while(n--)*b++=0;}
static int local(char *p,const char *name){if(lstrlenA(directory)+lstrlenA(name)+2>=MAX_PATH)return 0;lstrcpyA(p,directory);lstrcatA(p,"\\");lstrcatA(p,name);return 1;}
static DWORD read_local(const char *name,char *out,DWORD cap){char path[MAX_PATH];DWORD n=0;HANDLE f;
 if(!local(path,name))return 0;f=CreateFileA(path,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
 if(f==INVALID_HANDLE_VALUE)return 0;if(!ReadFile(f,out,cap-1,&n,0))n=0;CloseHandle(f);out[n]=0;return n;}
static void status(void *c,int value){char path[MAX_PATH],text[80];HANDLE f;DWORD n,written;(void)c;
 if(!local(path,"OBSERVER.STATUS"))return;lstrcpyA(text,"NT4_OBSERVER_STATUS=");lstrcatA(text,states[value]);lstrcatA(text,"\r\n");
 f=CreateFileA(path,GENERIC_WRITE,FILE_SHARE_READ,0,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);if(f==INVALID_HANDLE_VALUE)return;
 n=(DWORD)lstrlenA(text);WriteFile(f,text,n,&written,0);CloseHandle(f);}
static int arm(void *c){char text[80];(void)c;return read_local("ARMED.TXT",text,sizeof(text))==32 && !lstrcmpA(text,"NT4_PREPARED_FIRST_LOGON_READY\r\n");}
static int file_size(const char *name,DWORD minimum,DWORD maximum){char path[MAX_PATH];HANDLE f;DWORD size,high=0;
 if(!local(path,name))return 0;f=CreateFileA(path,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
 if(f==INVALID_HANDLE_VALUE)return 0;size=GetFileSize(f,&high);CloseHandle(f);return !high && size>=minimum && size<=maximum;}
static int staged(void *c){(void)c;return file_size("FIRSTLO.CMD",64,1024)&&file_size("TESTNET.CMD",64,2048)&&file_size("USOSLOG.EXE",1024000,1024000);}
static int remove_key(const char *path){HKEY key;LONG rc=RegOpenKeyExA(HKEY_LOCAL_MACHINE,path,0,KEY_SET_VALUE,&key);
 if(rc==ERROR_FILE_NOT_FOUND||rc==ERROR_PATH_NOT_FOUND)return 1;if(rc!=ERROR_SUCCESS)return 0;
 rc=RegDeleteValueA(key,"USOSCoverage");RegCloseKey(key);return rc==ERROR_SUCCESS||rc==ERROR_FILE_NOT_FOUND;}
static int remove_once(void *c){(void)c;return remove_key("Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce");}
static int remove_run(void *c){(void)c;return remove_key("Software\\Microsoft\\Windows\\CurrentVersion\\Run");}
static int remove_arm(void *c){char path[MAX_PATH];(void)c;return local(path,"ARMED.TXT")&&DeleteFileA(path);}
static int hidden(void *c,int network){char cmd[MAX_PATH],script[MAX_PATH],line[MAX_PATH*2+32];STARTUPINFOA si;PROCESS_INFORMATION pi;DWORD n,code=1;BOOL ok;(void)c;
 n=GetSystemDirectoryA(cmd,MAX_PATH);if(!n||n+9>=MAX_PATH||!local(script,network?"TESTNET.CMD":"FIRSTLO.CMD"))return 0;lstrcatA(cmd,"\\cmd.exe");
 lstrcpyA(line,"\"");lstrcatA(line,cmd);lstrcatA(line,"\" /c \"");lstrcatA(line,script);lstrcatA(line,"\"");zero(&si,sizeof(si));zero(&pi,sizeof(pi));
 si.cb=sizeof(si);si.dwFlags=STARTF_USESHOWWINDOW;si.wShowWindow=SW_HIDE;
 /* Give native console utilities a hidden child console. The detached
  * launch failed FIRSTLO in NT4 while the exact same script succeeded
  * in its existing console; native qualification checks this change. */
 ok=CreateProcessA(cmd,line,0,0,FALSE,CREATE_NEW_CONSOLE,0,directory,&si,&pi);if(!ok)return 0;
 ok=WaitForSingleObject(pi.hProcess,INFINITE)==WAIT_OBJECT_0&&GetExitCodeProcess(pi.hProcess,&code);CloseHandle(pi.hThread);CloseHandle(pi.hProcess);return ok&&code==0;}
static int ready(void *c){char text[80];(void)c;read_local("OBSERVER.STATUS",text,sizeof(text));return !lstrcmpA(text,"NT4_OBSERVER_STATUS=READY\r\n")||!lstrcmpA(text,"NT4_OBSERVER_STATUS=TESTNET_DONE\r\n");}
static int testnet(void){const char *s=GetCommandLineA();while(*s){if(*s=='/'){char word[9];int i;for(i=0;i<8&&s[i]&&s[i]!=' '&&s[i]!='\t';i++)word[i]=s[i];word[i]=0;if(!lstrcmpiA(word,"/testnet")&&(s[i]==0||s[i]==' '||s[i]=='\t'))return 1;}s++;}return 0;}
void entry(void){DWORD n,i;int result;HANDLE mutex;OBS_OPS ops={0,arm,staged,remove_once,remove_run,remove_arm,hidden,ready,status};
 n=GetModuleFileNameA(0,directory,MAX_PATH);if(!n||n>=MAX_PATH)ExitProcess(20);i=n;while(i&&directory[i-1]!='\\'&&directory[i-1]!='/')i--;if(!i)ExitProcess(20);directory[i-1]=0;
 mutex=CreateMutexA(0,FALSE,"USOS_NT4_CoverageObserver");if(!mutex)ExitProcess(21);if(WaitForSingleObject(mutex,INFINITE)!=WAIT_OBJECT_0)ExitProcess(22);
 result=testnet()?obs_testnet(&ops):obs_first(&ops);ReleaseMutex(mutex);CloseHandle(mutex);ExitProcess(result==OBS_READY||result==OBS_TESTNET_DONE?0:(UINT)result);}
