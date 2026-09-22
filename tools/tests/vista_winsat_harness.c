#include "../vista_hive.h"
__declspec(dllexport) int skip_moobe(unsigned char *p,uint32_t n){
 VistaHive h;uint32_t old;
 if(!vh_open(&h,p,n)||!vh_dword(&h,"Microsoft\\Windows NT\\CurrentVersion\\WinSAT","MOOBE",&old)||old!=1)return 0;
 if(!vh_set_dword(&h,"Microsoft\\Windows NT\\CurrentVersion\\WinSAT","MOOBE",2))return 0;
 vh_seal(&h);return 1;
}
int __stdcall DllMain(void *module,unsigned reason,void *reserved){(void)module;(void)reason;(void)reserved;return 1;}
