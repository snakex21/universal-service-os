/* Execute the real compatibility preparation with mocked WinPE boundaries.
 * No disk, registry, DOS-device or process API below reaches Windows. */
#include <windows.h>
#include <assert.h>
static WCHAR base[MAX_PATH]=L"X:\\USOS\\",command[2048];
static BOOL csm_target_nvme;
static int scenario,calls,copied,mapped,refreshed;
static void path(WCHAR *d,const WCHAR *a,const WCHAR *b){lstrcpyW(d,a);lstrcatW(d,b);}
static void logcode(const char *s,DWORD n){(void)s;(void)n;}
static BOOL directory(LPCWSTR p,LPSECURITY_ATTRIBUTES s){(void)s;calls++;assert(!lstrcmpW(p,L"X:\\USOS\\nvme-setup"));return scenario!=1;}
static UINT system_directory(LPWSTR p,UINT n){assert(n==MAX_PATH);lstrcpyW(p,L"X:\\Windows\\System32");return lstrlenW(p);}
static DWORD run(const WCHAR *exe,WCHAR *line){
 assert(!lstrcmpW(exe,L"X:\\Windows\\System32\\robocopy.exe"));
 assert(wcsstr(line,L"\"T:\\sources\" \"X:\\USOS\\nvme-setup\\sources\""));
 assert(wcsstr(line,L"/xf install.wim install.esd install.swm"));copied++;
 return scenario==2?8:7; /* robocopy 7 is success, 8 is failure */
}
static BOOL attributes(LPCWSTR p,DWORD a){assert(wcsstr(p,L"sources\\hwcompat.txt"));assert(a==FILE_ATTRIBUTE_NORMAL);return TRUE;}
static HANDLE mock_file(LPCWSTR p,DWORD a,DWORD s,LPSECURITY_ATTRIBUTES q,DWORD d,DWORD f,HANDLE h){
 (void)p;(void)s;(void)q;(void)h;assert(a==FILE_APPEND_DATA&&d==OPEN_EXISTING&&f==FILE_FLAG_WRITE_THROUGH);return(HANDLE)1;
}
static BOOL write_data(HANDLE h,LPCVOID data,DWORD size,LPDWORD count,LPOVERLAPPED o){
 (void)h;(void)o;static const char expected[]="\r\nstornvme.inf:\r\nPCI\\CC_010802\r\n";
 assert(size==sizeof(expected)-1&&!memcmp(data,expected,size));*count=scenario==3?size-1:size;return TRUE;
}
static BOOL flush(HANDLE h){(void)h;return scenario!=4;}
static BOOL close_handle(HANDLE h){(void)h;return TRUE;}
static DWORD drives(void){return scenario==9?0x03ffffff:(1u<<23);}
static BOOL define_drive(DWORD f,LPCWSTR d,LPCWSTR p){assert(!f&&d[1]==L':'&&!lstrcmpW(p,L"X:\\USOS\\nvme-setup"));mapped++;return scenario!=5;}
static BOOL vista_file(const WCHAR *p,BOOL sp2){assert(!lstrcmpW(p,L"Z:\\sources\\setup.exe")&&sp2);return scenario!=6;}
static LONG open_key(HKEY h,LPCWSTR p,DWORD f,REGSAM a,PHKEY out){
 assert(h==HKEY_LOCAL_MACHINE&&!f&&a==KEY_SET_VALUE&&wcsstr(p,L"CrashControl"));*out=(HKEY)1;return scenario==10?ERROR_ACCESS_DENIED:0;
}
static LONG set_value(HKEY h,LPCWSTR n,DWORD r,DWORD t,const BYTE *b,DWORD s){
 (void)h;assert((!lstrcmpW(n,L"CrashDumpEnabled")||!lstrcmpW(n,L"AutoReboot"))&&!r&&t==REG_DWORD&&s==4&&*(const DWORD*)b==0);return 0;
}
static LONG close_key(HKEY h){(void)h;return 0;}
static BOOL privilege(const WCHAR *p){assert(!lstrcmpW(p,L"SeCreatePagefilePrivilege"));return scenario!=7;}
static LONG WINAPI set_info(ULONG n,PVOID p,ULONG size){assert(n==34&&size==4&&*(ULONG*)p==0);refreshed++;return scenario==8?(LONG)0xc0000022:0;}
static HMODULE module(LPCWSTR p){assert(!lstrcmpW(p,L"ntdll.dll"));return(HMODULE)1;}
static FARPROC function(HMODULE h,LPCSTR p){(void)h;assert(!lstrcmpA(p,"NtSetSystemInformation"));return(FARPROC)set_info;}
#define CreateDirectoryW directory
#define GetSystemDirectoryW system_directory
#define SetFileAttributesW attributes
#define CreateFileW mock_file
#define WriteFile write_data
#define FlushFileBuffers flush
#define CloseHandle close_handle
#define GetLogicalDrives drives
#define DefineDosDeviceW define_drive
#define RegOpenKeyExW open_key
#define RegSetValueExW set_value
#define RegCloseKey close_key
#define GetModuleHandleW module
#define GetProcAddress function
#include "../windows_vista_nvme_setup.h"
int main(void){
 WCHAR setup[MAX_PATH]=L"T:\\sources\\setup.exe";
 csm_target_nvme=FALSE;assert(prepare_nvme64_setup(L"T:",setup));assert(!calls&&!copied&&!mapped&&!refreshed);
 csm_target_nvme=TRUE;assert(prepare_nvme64_setup(L"T:",setup));assert(copied==1&&mapped==1&&refreshed==1);
 for(scenario=1;scenario<=10;scenario++){
  copied=mapped=refreshed=0;assert(!prepare_nvme64_setup(L"T:",setup));
  if(scenario<=2)assert(!mapped&&!refreshed);
  if(scenario==3||scenario==4)assert(!mapped&&!refreshed);
 }
 return 0;
}
