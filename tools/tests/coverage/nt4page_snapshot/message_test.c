#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "core.h"
#include "message_table.h"
__declspec(dllexport) int actual_message(const unsigned char *b,unsigned n,unsigned long id,N4MESSAGE *v){return n4_message_view(b,n,id,v);}
__declspec(dllexport) int actual_controls(const WCHAR *a,WCHAR *b,unsigned n){return (int)n4_message_controls((const N4W*)a,(N4W*)b,n);}
BOOL WINAPI DllMain(HINSTANCE h,DWORD reason,LPVOID reserved){(void)h;(void)reason;(void)reserved;return TRUE;}
