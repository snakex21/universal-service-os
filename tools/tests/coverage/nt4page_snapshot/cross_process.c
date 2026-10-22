/* Host test adapter; invokes the actual reader in page.c against another process. */
#define entry unused_nt4page_entry
#include "page.c"
#undef entry
__declspec(dllexport) unsigned long real_read(HWND target,const WCHAR *expected,DWORD used){
 text_count=0;excluded_edit=0;capture_timed_out=0;capture_started=GetTickCount()-used;
 remember(target,target,0);
 return (text_count&&n4_equal((const N4W*)texts[0],(const N4W*)expected)?1u:0u)|(excluded_edit?2u:0u)|(capture_timed_out?4u:0u);
}
BOOL WINAPI DllMain(HINSTANCE a,DWORD b,LPVOID c){(void)a;(void)b;(void)c;return TRUE;}
