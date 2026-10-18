/* SPDX-License-Identifier: GPL-3.0-or-later
 * USOS user-mode test-mode desktop presentation, Copyright (c) 2026 USOS.
 */
#ifndef USOSWM_COMMON_H
#define USOSWM_COMMON_H
#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0600
#define COBJMACROS
#include <windows.h>

typedef LONG (WINAPI *WmQuerySystem)(ULONG,void *,ULONG,ULONG *);
typedef LONG (WINAPI *WmVersion)(OSVERSIONINFOW *);
static BOOL wm_supported(void){
 OSVERSIONINFOW os={sizeof(os)};HMODULE nt=GetModuleHandleW(L"ntdll.dll");
 WmVersion version=(WmVersion)GetProcAddress(nt,"RtlGetVersion");
 WmQuerySystem query=(WmQuerySystem)GetProcAddress(nt,"NtQuerySystemInformation");
 struct {ULONG length,options;} ci={sizeof(ci),0};
 return version&&query&&version(&os)==0&&os.dwMajorVersion==6&&os.dwMinorVersion==0&&os.dwBuildNumber==6002
     &&query(103,&ci,sizeof(ci),0)==0&&(ci.options&2)!=0;
}
static BOOL wm_default_desktop(void){
 WCHAR name[64];DWORD size=0;
 return GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()),UOI_NAME,name,sizeof(name),&size)&&!lstrcmpiW(name,L"Default");
}
static BOOL wm_directory(HMODULE module,WCHAR out[MAX_PATH]){
 DWORD n=GetModuleFileNameW(module,out,MAX_PATH);if(!n||n>=MAX_PATH-64)return FALSE;
 while(n&&out[n-1]!=L'\\')n--;out[n]=0;return n!=0;
}
static BOOL wm_explorer(void){
 WCHAR actual[MAX_PATH],expected[MAX_PATH];
 DWORD n=GetWindowsDirectoryW(expected,MAX_PATH);if(!n||n>=MAX_PATH-20)return FALSE;lstrcatW(expected,L"\\explorer.exe");
 n=GetModuleFileNameW(0,actual,MAX_PATH);return n&&n<MAX_PATH&&!lstrcmpiW(actual,expected);
}
static void wm_number(WCHAR *out,DWORD n){WCHAR digits[10];DWORD count=0;do{digits[count++]=L'0'+n%10;n/=10;}while(n);for(DWORD i=0;i<count;i++)out[i]=digits[count-i-1];out[count]=0;}
static void wm_log(HMODULE module,const char *message){
 WCHAR file[MAX_PATH],digits[12];if(!wm_directory(module,file))return;lstrcatW(file,L"logs");CreateDirectoryW(file,0);lstrcatW(file,L"\\session-");
 DWORD session=0;ProcessIdToSessionId(GetCurrentProcessId(),&session);wm_number(digits,session);lstrcatW(file,digits);lstrcatW(file,L"-pid-");wm_number(digits,GetCurrentProcessId());lstrcatW(file,digits);lstrcatW(file,L".log");
 HANDLE log=CreateFileW(file,FILE_APPEND_DATA|FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_ALWAYS,FILE_FLAG_OPEN_REPARSE_POINT,0);if(log==INVALID_HANDLE_VALUE)return;
 BY_HANDLE_FILE_INFORMATION info;
 if(!GetFileInformationByHandle(log,&info)||info.nNumberOfLinks!=1||(info.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT)){CloseHandle(log);return;}
 DWORD written;WriteFile(log,message,lstrlenA(message),&written,0);WriteFile(log,"\r\n",2,&written,0);CloseHandle(log);
}
static BOOL wm_visible(HMODULE module){WCHAR path[MAX_PATH];if(!wm_directory(module,path))return TRUE;lstrcatW(path,L"testmode-watermark-on.txt");if(GetFileAttributesW(path)!=INVALID_FILE_ATTRIBUTES)return TRUE;DWORD error=GetLastError();return error!=ERROR_FILE_NOT_FOUND&&error!=ERROR_PATH_NOT_FOUND;}
#endif
