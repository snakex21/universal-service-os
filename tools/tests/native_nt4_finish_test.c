/* SPDX-License-Identifier: GPL-3.0-or-later
 * Actual production BOOT.INI routines, with an in-memory Win32 file model.
 * All disk APIs are replaced; this executable cannot open a host file.
 */
#include <windows.h>
static char image[12288],saved[12288];
static const char options[]="boot_options=/NUMPROC=2 /MAXMEM=1024\r\n";
static DWORD size;
static int failed_write,failed_flush,removed;
static HANDLE g_BootWrite=INVALID_HANDLE_VALUE;
static int g_BootFlushed;
static int len(const char *s){return lstrlenA(s);}
static void say(const char *s){(void)s;}
static void say_hex(const char *s,DWORD n){(void)s;(void)n;}
static void bytes(void *d,const void *s,DWORD n){DWORD i;for(i=0;i<n;i++)((volatile char *)d)[i]=((const char *)s)[i];}
static HANDLE WINAPI FCreate(LPCSTR p,DWORD a,DWORD b,LPSECURITY_ATTRIBUTES c,DWORD d,DWORD e,HANDLE f)
{(void)b;(void)c;(void)d;(void)e;(void)f;if(!lstrcmpiA(p,"C:\\BOOT.INI")){if((a&GENERIC_WRITE)&&failed_write)return INVALID_HANDLE_VALUE;return (HANDLE)1;}return (HANDLE)2;}
static BOOL WINAPI FRead(HANDLE h,LPVOID p,DWORD n,LPDWORD done,LPOVERLAPPED o)
{DWORD k=h==(HANDLE)1?size:sizeof(options)-1;(void)o;if(k>n)k=n;bytes(p,h==(HANDLE)1?image:options,k);*done=k;return TRUE;}
static BOOL WINAPI FWrite(HANDLE h,LPCVOID p,DWORD n,LPDWORD done,LPOVERLAPPED o)
{(void)h;(void)o;if(n>=sizeof(image))return FALSE;bytes(image,p,n);image[n]=0;size=n;*done=n;return TRUE;}
static BOOL WINAPI FFlush(HANDLE h){(void)h;return !failed_flush;}
static BOOL WINAPI FClose(HANDLE h){(void)h;return TRUE;}
static DWORD WINAPI FAttr(LPCSTR p){(void)p;return FILE_ATTRIBUTE_NORMAL;}
static BOOL WINAPI FSetAttr(LPCSTR p,DWORD a){(void)p;(void)a;return TRUE;}
static BOOL WINAPI FDelete(LPCSTR p){(void)p;removed++;return TRUE;}
#define DIR "C:\\USOS\\NT4\\"
#define CreateFileA FCreate
#define ReadFile FRead
#define WriteFile FWrite
#define FlushFileBuffers FFlush
#define CloseHandle FClose
#define GetFileAttributesA FAttr
#define SetFileAttributesA FSetAttr
#define DeleteFileA FDelete
static int boot_valid(void);
static BOOL WINAPI finish_delete(LPCSTR);
#include "finish_helpers_actual.inc"
#undef CreateFileA
#undef FlushFileBuffers
#undef DeleteFileA
#define CreateFileA finish_create
#define FlushFileBuffers finish_flush
#define DeleteFileA finish_delete
#include "finish_boot_actual.inc"
static void reset(void)
{
    static const char initial[]="[boot loader]\r\ntimeout=30\r\ndefault=multi(0)disk(0)rdisk(0)partition(1)\\WINNT\r\n[operating systems]\r\nmulti(0)disk(0)rdisk(0)partition(1)\\WINNT=\"Windows NT\"\r\nC:\\=\"old bootstrap\"\r\n";
    bytes(image,initial,sizeof initial);size=sizeof initial-1;
    removed=failed_write=failed_flush=g_BootFlushed=0;g_BootWrite=INVALID_HANDLE_VALUE;
}
void entry(void)
{
    DWORD i,previous;
    reset();finish_boot();
    if(!g_BootFlushed || !boot_valid() || removed==0)ExitProcess(1);
    if(!has_ci(image,size,"/numproc=2 /maxmem=1024"))ExitProcess(2);
    for(i=0;i<size;i++)if(!image[i])ExitProcess(3);
    previous=size;bytes(saved,image,size+1);
    g_BootFlushed=0;g_BootWrite=INVALID_HANDLE_VALUE;removed=0;finish_boot();
    if(size!=previous || lstrcmpA(image,saved) || !g_BootFlushed || !removed)ExitProcess(4);
    failed_flush=1;g_BootFlushed=0;removed=0;finish_boot();if(removed || g_BootFlushed)ExitProcess(7);
    reset();failed_write=1;finish_boot();if(removed || g_BootFlushed)ExitProcess(5);
    reset();failed_flush=1;finish_boot();if(removed || g_BootFlushed)ExitProcess(6);
    ExitProcess(0);
}
