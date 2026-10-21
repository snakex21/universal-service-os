/* Test executable for tools/windows_vista_mpart.h. Every filesystem and
 * registry call is a mock (tools/tests/test_usosmpart_vista_x64.py). */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0602
#include <windows.h>
#include <assert.h>
#include <string.h>

typedef struct { WCHAR root[8]; } Target;
static BOOL csmwrap;
static WCHAR base[MAX_PATH]=L"X:\\Windows\\System32\\";
static DWORD current=1,def=2;
static unsigned copied,loaded,sets,closed,flushed,fail_set,restored,deleted,file_present;
static LONG filters_error;          /* RegGetValueW result for LowerFilters */
static WCHAR filters_in[64];        /* existing value (multi-sz) */
static DWORD filters_in_bytes;
static WCHAR keys[32][200],names[32][40];
static DWORD types[32],sizes[32];
static BYTE values[32][200];
static LONG WINAPI fake_set(HKEY h,LPCWSTR k,LPCWSTR n,DWORD type,LPCVOID value,DWORD size){
 assert(h==(HKEY)(UINT_PTR)5);assert(sets<32);assert(size<=200);
 lstrcpyW(keys[sets],k);lstrcpyW(names[sets],n);types[sets]=type;sizes[sets]=size;memcpy(values[sets],value,size);sets++;
 return fail_set==sets?ERROR_ACCESS_DENIED:ERROR_SUCCESS;
}
static BOOL WINAPI fake_copy(LPCWSTR src,LPCWSTR dst,BOOL fail){
 (void)fail;copied++;if(wcsstr(src,L"SYSTEM.before-mpart")&&wcsstr(dst,L"config\\SYSTEM"))restored++;
 return TRUE;
}
static BOOL WINAPI fake_delete(LPCWSTR file){assert(wcsstr(file,L"drivers\\usosmpart.sys"));deleted++;return TRUE;}
static DWORD WINAPI fake_attr(LPCWSTR file){assert(wcsstr(file,L"usosmpart-amd64.sys"));return file_present?FILE_ATTRIBUTE_NORMAL:INVALID_FILE_ATTRIBUTES;}
static LONG WINAPI fake_load(LPCWSTR file,PHKEY h,REGSAM access,DWORD opt,DWORD reserved){
 (void)access;(void)opt;(void)reserved;assert(wcsstr(file,L"Windows\\System32\\config\\SYSTEM"));loaded++;*h=(HKEY)(UINT_PTR)5;return ERROR_SUCCESS;
}
static LONG WINAPI fake_get(HKEY h,LPCWSTR key,LPCWSTR name,DWORD flags,LPDWORD type,PVOID data,LPDWORD size){
 (void)h;
 if(!lstrcmpW(key,L"Select")){
  assert(flags==RRF_RT_REG_DWORD&&*size==sizeof(DWORD));*type=REG_DWORD;
  *(DWORD*)data=!lstrcmpW(name,L"Current")?current:def;return ERROR_SUCCESS;
 }
 assert(wcsstr(key,L"\\Control\\Class\\{4D36E967-E325-11CE-BFC1-08002BE10318}"));
 assert(!lstrcmpW(name,L"LowerFilters")&&flags==RRF_RT_REG_MULTI_SZ);
 if(filters_error)return filters_error;
 assert(*size>=filters_in_bytes);memcpy(data,filters_in,filters_in_bytes);*size=filters_in_bytes;*type=REG_MULTI_SZ;
 return ERROR_SUCCESS;
}
static LONG WINAPI fake_flush(HKEY h){(void)h;flushed++;return ERROR_SUCCESS;}
static LONG WINAPI fake_close(HKEY h){(void)h;closed++;return ERROR_SUCCESS;}
static void path(WCHAR *dst,const WCHAR *root,const WCHAR *tail){lstrcpyW(dst,root);lstrcatW(dst,tail);}
static BOOL hash_file(const WCHAR *p,BYTE h[32]){(void)p;memset(h,42,32);return TRUE;}
static BOOL same(const void *a,const void *b,unsigned n){return !memcmp(a,b,n);}
static void logcode(const char *msg,DWORD value){(void)msg;(void)value;}
#define RegSetKeyValueW fake_set
#define CopyFileW fake_copy
#define DeleteFileW fake_delete
#define GetFileAttributesW fake_attr
#define RegLoadAppKeyW fake_load
#define RegGetValueW fake_get
#define RegFlushKey fake_flush
#define RegCloseKey fake_close
#include "../windows_vista_mpart.h"

static void reset(void){
 copied=loaded=sets=closed=flushed=fail_set=restored=deleted=0;current=1;def=2;file_present=1;
 filters_error=ERROR_FILE_NOT_FOUND;filters_in_bytes=0;csmwrap=TRUE;
}
static void existing(const WCHAR *multi,DWORD bytes){filters_error=0;memcpy(filters_in,multi,bytes);filters_in_bytes=bytes;}
static unsigned find(const WCHAR *key_tail,const WCHAR *name){
 for(unsigned i=0;i<sets;i++){size_t k=wcslen(keys[i]),t=wcslen(key_tail);
  if(k>=t&&!wcscmp(keys[i]+k-t,key_tail)&&!lstrcmpW(names[i],name))return i;}
 return ~0u;
}
int main(void){
 Target t={L"C:\\"};
 /* UEFI path (no testsigning step of configure_boot_bios): nothing at all. */
 reset();csmwrap=FALSE;assert(install_mpart64(&t));assert(!copied&&!loaded&&!sets&&!deleted);
 /* Build without the signed filter: skipped, not fatal. */
 reset();file_present=0;assert(install_mpart64(&t));assert(!copied&&!loaded&&!sets);
 /* No LowerFilters yet (Vista): created as "usosmpart\0\0" in both control sets. */
 reset();assert(install_mpart64(&t));
 assert(loaded==1&&closed==1&&flushed==1&&!restored&&!deleted&&copied==2);
 assert(sets==14);
 assert(!lstrcmpW(keys[0],L"ControlSet001\\Services\\usosmpart")&&!lstrcmpW(names[0],L"Type")&&*(DWORD*)values[0]==1);
 assert(!lstrcmpW(names[1],L"Start")&&*(DWORD*)values[1]==0);
 assert(!lstrcmpW(names[2],L"ErrorControl")&&*(DWORD*)values[2]==1);
 assert(!lstrcmpW(names[3],L"Group")&&types[3]==REG_SZ&&!lstrcmpW((WCHAR*)values[3],L"Filter"));
 assert(types[4]==REG_EXPAND_SZ&&!lstrcmpW((WCHAR*)values[4],L"system32\\drivers\\usosmpart.sys"));
 assert(!lstrcmpW(keys[6],L"ControlSet001\\Control\\Class\\{4D36E967-E325-11CE-BFC1-08002BE10318}"));
 assert(!lstrcmpW(names[6],L"LowerFilters")&&types[6]==REG_MULTI_SZ&&sizes[6]==11*sizeof(WCHAR));
 assert(!memcmp(values[6],L"usosmpart\0",11*sizeof(WCHAR)));
 assert(!lstrcmpW(keys[7],L"ControlSet002\\Services\\usosmpart"));
 assert(!lstrcmpW(keys[13],L"ControlSet002\\Control\\Class\\{4D36E967-E325-11CE-BFC1-08002BE10318}"));
 /* Current == Default: one control set. */
 reset();current=def=3;assert(install_mpart64(&t));assert(sets==7&&!lstrcmpW(keys[0],L"ControlSet003\\Services\\usosmpart"));
 /* Existing filter list: appended after it, order kept. */
 reset();existing(L"EhStorClass\0PartMgr\0",21*sizeof(WCHAR));current=def=1;assert(install_mpart64(&t));
 {unsigned i=find(L"{4D36E967-E325-11CE-BFC1-08002BE10318}",L"LowerFilters");assert(i!=~0u);
  assert(sizes[i]==31*sizeof(WCHAR));assert(!memcmp(values[i],L"EhStorClass\0PartMgr\0usosmpart\0",31*sizeof(WCHAR)));}
 /* Empty multi-sz (one NUL). */
 reset();existing(L"",sizeof(WCHAR));current=def=1;assert(install_mpart64(&t));
 {unsigned i=find(L"{4D36E967-E325-11CE-BFC1-08002BE10318}",L"LowerFilters");assert(sizes[i]==11*sizeof(WCHAR));}
 /* Already listed (any case): value not rewritten. */
 reset();existing(L"EhStorClass\0USOSMPART\0",23*sizeof(WCHAR));current=def=1;assert(install_mpart64(&t));
 assert(find(L"{4D36E967-E325-11CE-BFC1-08002BE10318}",L"LowerFilters")==~0u&&sets==6&&flushed==1);
 /* LowerFilters of another type: refused, hive restored, file removed. */
 reset();filters_error=ERROR_UNSUPPORTED_TYPE;assert(!install_mpart64(&t));assert(restored==1&&deleted==1&&closed==1&&!flushed);
 /* A failed write: restored, removed. */
 reset();fail_set=4;assert(!install_mpart64(&t));assert(sets==4&&restored==1&&deleted==1&&closed==1&&!flushed);
 /* Broken Select: nothing written, restored, removed. */
 reset();current=1000;assert(!install_mpart64(&t));assert(!sets&&restored==1&&deleted==1);
 return 0;
}
