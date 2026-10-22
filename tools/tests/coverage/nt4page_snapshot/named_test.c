#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static const BYTE own_dialog[]={0,0,0,0,0,0,0,0,1,0,0,0,0,0,100,0,50,0,0,0,0,0,79,0,119,0,110,0,32,0,112,0,117,0,98,0,108,0,105,0,99,0,32,0,100,0,105,0,97,0,108,0,111,0,103,0,46,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,100,0,10,0,104,0,255,255,130,0,79,0,119,0,110,0,32,0,112,0,117,0,98,0,108,0,105,0,99,0,32,0,115,0,116,0,97,0,116,0,105,0,99,0,32,0,99,0,111,0,110,0,116,0,114,0,111,0,108,0,46,0,0,0,0,0};
static unsigned exact_name_seen,got_named_output;static char output[4096];static unsigned used;
static HRSRC WINAPI named_find(HMODULE module,LPCWSTR name,LPCWSTR type){(void)module;if((ULONG_PTR)name>65535&&lstrcmpW(name,L"CRITERR")==0&&(ULONG_PTR)type==5){exact_name_seen++;return(HRSRC)7;}return 0;}
static DWORD WINAPI named_size(HMODULE module,HRSRC resource){(void)module;(void)resource;return sizeof(own_dialog);}
static HGLOBAL WINAPI named_load(HMODULE module,HRSRC resource){(void)module;(void)resource;return(HGLOBAL)7;}
static LPVOID WINAPI named_lock(HGLOBAL resource){(void)resource;return (LPVOID)own_dialog;}
static BOOL WINAPI own_write(HANDLE file,LPCVOID data,DWORD count,LPDWORD written,LPOVERLAPPED ov){unsigned i;(void)file;(void)ov;for(i=0;i<count&&used+1<sizeof(output);i++)output[used++]=((const char*)data)[i];output[used]=0;*written=count;return TRUE;}
#define FindResourceW named_find
#define SizeofResource named_size
#define LoadResource named_load
#define LockResource named_lock
#define WriteFile own_write
#define entry unused_entry
#include "page.c"
#undef entry
static int contains(const char *needle){unsigned i,j;for(i=0;i<used;i++){for(j=0;needle[j]&&output[i+j]&&needle[j]==output[i+j];j++){}if(!needle[j])return 1;}return 0;}
__declspec(dllexport) unsigned actual_named(unsigned known){unsigned i;N4DIALOG id;exact_name_seen=0;got_named_output=0;used=0;for(i=0;i<N4_MODULE_COUNT;i++)if(lstrcmpA(n4_module_names[i],"SETUPDLL")==0)break;if(i==N4_MODULE_COUNT)return 0;id.module=(unsigned short)i;id.id=0;id.name=known?L"CRITERR":L"UNKNOWN";id.public_name=known?"CRITERR":"UNKNOWN";modules[i]=(HMODULE)1;public_file=(HANDLE)7;serial=INVALID_HANDLE_VALUE;text_count=1;roles[0]=1;n4_normalize((const N4W*)L"Own public static control.",(N4W*)texts[0],TEXT_CAP);compare_dialog(&id);got_named_output=contains("NT4PAGE DIALOGNAME SETUPDLL CRITERR 1 STATIC\r\n");return exact_name_seen|(got_named_output<<8);}
BOOL WINAPI DllMain(HINSTANCE h,DWORD reason,LPVOID reserved){(void)h;(void)reason;(void)reserved;return TRUE;}
