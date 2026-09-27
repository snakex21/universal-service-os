/* Host harness for tools/vista_autochk.h: argv[1] = fixed-drive mask (hex),
 * argv[2] = system letter, argv[3] = current BootExecute (one string or "").
 * Prints "DEFAULT=<0|1>" and "VALUE=<multi-sz with | for NUL>" (empty = kept). */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include "../vista_autochk.h"
int wmain(int argc,wchar_t **argv){
 if(argc<4)return 2;
 DWORD mask=(DWORD)wcstoul(argv[1],0,16);WCHAR current[256]={0};unsigned n=(unsigned)wcslen(argv[3]);
 wcscpy(current,argv[3]);current[n]=0;current[n+1]=0;
 printf("DEFAULT=%d\n",usos_autochk_is_default(current,n+2));
 WCHAR out[128];unsigned chars=usos_autochk_value(out,128,mask,argv[2][0]);
 printf("VALUE=");for(unsigned i=0;i<chars;i++)putchar(out[i]?(char)out[i]:'|');printf("\n");
 return 0;
}
