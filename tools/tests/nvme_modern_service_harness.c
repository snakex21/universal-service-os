#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0600
#include <windows.h>
#include <wincrypt.h>
#include <shellapi.h>
#include <assert.h>
#include <string.h>
static DWORD count,fail_at;static WCHAR opened[160],names[8][40];static DWORD types[8];static BYTE values[8][256];
static LONG WINAPI open_fake(HKEY h,LPCWSTR name,DWORD opt,REGSAM access,PHKEY out){(void)h;(void)opt;(void)access;lstrcpyW(opened,name);*out=(HKEY)5;return ERROR_SUCCESS;}
static LONG WINAPI create_fake(HKEY h,LPCWSTR name,DWORD r,LPWSTR c,DWORD o,REGSAM a,LPSECURITY_ATTRIBUTES s,PHKEY out,LPDWORD d){(void)h;(void)name;(void)r;(void)c;(void)o;(void)a;(void)s;(void)d;*out=(HKEY)6;return ERROR_SUCCESS;}
static LONG WINAPI set_fake(HKEY h,LPCWSTR name,DWORD r,DWORD type,const BYTE *data,DWORD size){(void)h;(void)r;assert(count<8&&size<=256);lstrcpyW(names[count],name);types[count]=type;memcpy(values[count],data,size);count++;return count==fail_at?ERROR_ACCESS_DENIED:ERROR_SUCCESS;}
static LONG WINAPI flush_fake(HKEY h){(void)h;return ERROR_SUCCESS;}
static LONG WINAPI close_fake(HKEY h){(void)h;return ERROR_SUCCESS;}
#define RegOpenKeyExW open_fake
#define RegCreateKeyExW create_fake
#define RegSetValueExW set_fake
#define RegFlushKey flush_fake
#define RegCloseKey close_fake
#define entry unused_entry
#include "../windows_nvme_modern.c"
int main(void){
 assert(!service((HKEY)4,0)&&!count);assert(!service((HKEY)4,1000)&&!count);
 assert(service((HKEY)4,42));assert(!lstrcmpW(opened,L"StartOverride"));assert(count==4);
 assert(!lstrcmpW(names[0],L"ImagePath")&&types[0]==REG_EXPAND_SZ);
 assert(!lstrcmpW((WCHAR*)values[0],L"\\SystemRoot\\System32\\drivers\\usosnvme.sys"));
 assert(!lstrcmpW(names[1],L"Start")&&types[1]==REG_DWORD&&*(DWORD*)values[1]==0);
 assert(!lstrcmpW(names[2],L"0")&&*(DWORD*)values[2]==0);
 assert(!lstrcmpW(names[3],L"5")&&*(DWORD*)values[3]==1);
 for(DWORD at=1;at<=4;at++){count=0;fail_at=at;assert(!service((HKEY)4,1));assert(count==at);}
 return 0;
}
