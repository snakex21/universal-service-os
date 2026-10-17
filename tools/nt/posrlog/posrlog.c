/* POSReady FBA first-logon helper. Own code, GPL-3.0-or-later.
 * Credentials go directly from the existing Setup answer into Winlogon.
 * There is no password-bearing command line, REG file or diagnostic output.
 */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0501
#include <windows.h>
#include "credentials.h"

static char xml[65536],password[2048];
static WCHAR wide[1024],source[MAX_PATH],volume[MAX_PATH],file[MAX_PATH];
static void clear(void *p,unsigned n){volatile BYTE *b=(volatile BYTE*)p;while(n--)*b++=0;}
static BOOL read_file(const WCHAR *path,void *data,DWORD limit,DWORD *size){
 HANDLE h=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(h==INVALID_HANDLE_VALUE)return FALSE;
 DWORD bytes=GetFileSize(h,0);BOOL ok=bytes<limit&&ReadFile(h,data,bytes,size,0)&&*size==bytes;CloseHandle(h);return ok;
}
static LONG set_string(HKEY key,const WCHAR *name,const WCHAR *value){return RegSetValueExW(key,name,0,REG_SZ,(const BYTE*)value,(lstrlenW(value)+1)*2);}
#ifdef __cplusplus
extern "C"
#endif
void PosrMain(void){
 static OSVERSIONINFOW os={sizeof(os)};DWORD n=0,id=0,matches=0,size=0;
 /* Refuse to run on the development host, modern Windows or the PE. */
 if(!GetVersionExW(&os)||os.dwMajorVersion!=5||os.dwMinorVersion!=1)ExitProcess(2);
 HKEY mini;if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SYSTEM\\CurrentControlSet\\Control\\MiniNT",0,KEY_READ,&mini)==ERROR_SUCCESS){RegCloseKey(mini);ExitProcess(2);}
 n=GetModuleFileNameW(0,file,MAX_PATH);if(!n||n>=MAX_PATH-16)ExitProcess(3);while(n&&file[n-1]!='\\')n--;file[n]=0;lstrcatW(file,L"SOURCE.ID");
 char hex[32];if(!read_file(file,hex,sizeof(hex),&size)||size<8)ExitProcess(3);
 for(unsigned i=0;i<8;i++){unsigned c=(unsigned char)hex[i];if(c>='0'&&c<='9')c-='0';else if(c>='a'&&c<='f')c=c-'a'+10;else if(c>='A'&&c<='F')c=c-'A'+10;else ExitProcess(3);id=(id<<4)|c;}
 HANDLE search=FindFirstVolumeW(volume,MAX_PATH);if(search==INVALID_HANDLE_VALUE)ExitProcess(4);
 do{DWORD serial=0;if(GetVolumeInformationW(volume,0,0,&serial,0,0,0,0)&&serial==id){matches++;lstrcpyW(source,volume);}}while(FindNextVolumeW(search,volume,MAX_PATH));
 FindVolumeClose(search);if(matches!=1)ExitProcess(4);
 lstrcpyW(file,source);lstrcatW(file,L"Setup\\unattended.xml");
 if(!read_file(file,xml,sizeof(xml),&size)||!pr_password(xml,size,password,sizeof(password)))ExitProcess(5);
 int count=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,password,-1,wide,sizeof(wide)/sizeof(wide[0]));
 clear(password,sizeof(password));clear(xml,sizeof(xml));if(!count)ExitProcess(5);
 HKEY key;LONG e=RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon",0,KEY_SET_VALUE,&key);
 if(e==ERROR_SUCCESS){
  DWORD one=1;
  if(!(e=set_string(key,L"DefaultUserName",L"Administrator"))&&!(e=set_string(key,L"DefaultPassword",wide))&&
     !(e=RegSetValueExW(key,L"AutoLogonCount",0,REG_DWORD,(const BYTE*)&one,sizeof(one))))e=set_string(key,L"AutoAdminLogon",L"1");
  if(e==ERROR_SUCCESS)e=RegFlushKey(key);
  if(e!=ERROR_SUCCESS){set_string(key,L"AutoAdminLogon",L"0");RegDeleteValueW(key,L"DefaultPassword");RegFlushKey(key);}
  RegCloseKey(key);
 }
 clear(wide,sizeof(wide));ExitProcess(e==ERROR_SUCCESS?0:6);
}
