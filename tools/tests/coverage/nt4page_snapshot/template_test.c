#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "core.h"
#include "template.h"
__declspec(dllexport) int actual_template(const WCHAR *a,const WCHAR *p){N4W an[768],pn[768];if(!n4_normalize((const N4W*)a,an,768)||!n4_normalize((const N4W*)p,pn,768))return 0;return n4_public_template(an,pn);}
__declspec(dllexport) int actual_fragment(const WCHAR *a,const WCHAR *p){N4W an[768],pn[768];if(!n4_normalize((const N4W*)a,an,768)||!n4_normalize((const N4W*)p,pn,768))return 0;return n4_public_fragment(an,pn);}
BOOL WINAPI DllMain(HINSTANCE h,DWORD reason,LPVOID reserved){(void)h;(void)reason;(void)reserved;return TRUE;}
