/* Test executable. Every filesystem/registry write is replaced by a mock. */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0602
#include <windows.h>
#include <assert.h>
#include <string.h>

typedef struct { WCHAR root[8]; } Target;
static BOOL csm_target_nvme;
static WCHAR base[MAX_PATH]=L"X:\\Windows\\System32\\";
static DWORD current=1,def=2;
static unsigned copied,loaded,sets,closed,flushed,fail_set,restored;
static WCHAR keys[32][200],names[32][40];
static DWORD types[32];
static BYTE values[32][160];
static LONG WINAPI fake_set(HKEY h,LPCWSTR k,LPCWSTR n,DWORD type,LPCVOID value,DWORD size){
 assert(h==(HKEY)(UINT_PTR)5);assert(sets<32);assert(size<=160);
 lstrcpyW(keys[sets],k);lstrcpyW(names[sets],n);types[sets]=type;memcpy(values[sets],value,size);sets++;
 return fail_set==sets?ERROR_ACCESS_DENIED:ERROR_SUCCESS;
}
static BOOL WINAPI fake_copy(LPCWSTR src,LPCWSTR dst,BOOL fail){
 (void)fail;copied++;if(wcsstr(src,L"SYSTEM.before-nvme")&&wcsstr(dst,L"config\\SYSTEM"))restored++;
 return TRUE;
}
static LONG WINAPI fake_load(LPCWSTR file,PHKEY h,REGSAM access,DWORD opt,DWORD reserved){
 (void)access;(void)opt;(void)reserved;assert(wcsstr(file,L"Windows\\System32\\config\\SYSTEM"));loaded++;*h=(HKEY)(UINT_PTR)5;return ERROR_SUCCESS;
}
static LONG WINAPI fake_get(HKEY h,LPCWSTR path,LPCWSTR name,DWORD flags,LPDWORD type,PVOID data,LPDWORD size){
 (void)h;(void)flags;assert(!lstrcmpW(path,L"Select"));assert(*size==sizeof(DWORD));*type=REG_DWORD;
 *(DWORD*)data=!lstrcmpW(name,L"Current")?current:def;return ERROR_SUCCESS;
}
static LONG WINAPI fake_flush(HKEY h){(void)h;flushed++;return ERROR_SUCCESS;}
static LONG WINAPI fake_close(HKEY h){(void)h;closed++;return ERROR_SUCCESS;}
static BOOL mkdirs(WCHAR *p){assert(wcsstr(p,L"C:\\USOS\\nvme"));return TRUE;}
static void path(WCHAR *dst,const WCHAR *root,const WCHAR *tail){lstrcpyW(dst,root);lstrcatW(dst,tail);}
static BOOL hash_file(const WCHAR *p,BYTE h[32]){(void)p;memset(h,42,32);return TRUE;}
static BOOL same(const void *a,const void *b,unsigned n){return !memcmp(a,b,n);}
static void logcode(const char *msg,DWORD value){(void)msg;(void)value;}
#define RegSetKeyValueW fake_set
#define CopyFileW fake_copy
#define RegLoadAppKeyW fake_load
#define RegGetValueW fake_get
#define RegFlushKey fake_flush
#define RegCloseKey fake_close
#include "../windows_vista_nvme.h"

static void reset(void){copied=loaded=sets=closed=flushed=fail_set=restored=0;current=1;def=2;}
int main(void){
 Target t={L"C:\\"};reset();csm_target_nvme=FALSE;
 assert(install_nvme64(&t));assert(!copied&&!loaded&&!sets);
 csm_target_nvme=TRUE;assert(install_nvme64(&t));assert(loaded==1&&sets==16&&closed==1&&flushed==1&&!restored);
 assert(!lstrcmpW(keys[0],L"ControlSet001\\Services\\usosnvme"));
 assert(!lstrcmpW(keys[8],L"ControlSet002\\Services\\usosnvme"));
 assert(!lstrcmpW(names[1],L"Start")&&types[1]==REG_DWORD&&*(DWORD*)values[1]==0);
 assert(types[4]==REG_EXPAND_SZ&&!lstrcmpW((WCHAR*)values[4],L"system32\\drivers\\usosnvme.sys"));
 assert(!lstrcmpW(keys[6],L"ControlSet001\\Control\\CriticalDeviceDatabase\\pci#cc_010802"));
 reset();current=def=42;assert(install_nvme64(&t));assert(sets==8);assert(!lstrcmpW(keys[0],L"ControlSet042\\Services\\usosnvme"));
 reset();current=1000;assert(!install_nvme64(&t));assert(!sets&&closed==1&&restored==1&&!flushed);
 reset();fail_set=5;assert(!install_nvme64(&t));assert(sets==5&&closed==1&&restored==1&&!flushed);
 return 0;
}
