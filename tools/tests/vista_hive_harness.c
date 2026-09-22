#include "../vista_hive.h"
__declspec(dllexport) int inspect_string(unsigned char *p,uint32_t n,const char *key,const char *name,uint16_t *out,unsigned count){VistaHive h;return vh_open(&h,p,n)&&vh_string(&h,key,name,out,count);}
__declspec(dllexport) int patch_setup(unsigned char *p,uint32_t n,const uint16_t *line){
 VistaHive h;uint32_t active,phase,child;
 if(!vh_open(&h,p,n)||!vh_dword(&h,"Setup","SystemSetupInProgress",&active)||active!=1||!vh_dword(&h,"Setup","SetupPhase",&phase)||phase!=4||!vh_dword(&h,"Setup\\Status\\ChildCompletion","setup.exe",&child)||child!=0)return 0;
 if(!vh_set_string(&h,"Setup","CmdLine",line)||!vh_set_dword(&h,"Setup","SetupType",2))return 0;
 vh_seal(&h);return 1;
}
int __stdcall DllMain(void *module,unsigned reason,void *reserved){(void)module;(void)reason;(void)reserved;return 1;}
