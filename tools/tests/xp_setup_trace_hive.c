#include "../vista_hive.h"
__declspec(dllexport) int patch(unsigned char *p,uint32_t n){
 VistaHive h;uint32_t active;uint16_t old[128];
 const uint16_t expected[]={'s','e','t','u','p',' ','-','n','e','w','s','e','t','u','p',0};
 const uint16_t line[]={'C',':','\\','U','S','O','S','\\','x','.','e','x','e',0};
 if(!vh_open(&h,p,n)||!vh_dword(&h,"Setup","SystemSetupInProgress",&active)||active!=1||!vh_string(&h,"Setup","CmdLine",old,128))return 0;
 for(unsigned i=0;i<sizeof(expected)/2;i++)if(old[i]!=expected[i])return 0;
 if(!vh_set_string(&h,"Setup","CmdLine",line))return 0;
 vh_seal(&h);return 1;
}
int __stdcall DllMain(void *m,unsigned r,void *v){(void)m;(void)r;(void)v;return 1;}
