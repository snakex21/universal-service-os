#include "../vista_hive.h"
__declspec(dllexport) int arm_oobe_resume(unsigned char *p,uint32_t n){
 VistaHive h;uint32_t v;uint16_t line[64];
 if(!vh_open(&h,p,n)||!vh_dword(&h,"Setup","SystemSetupInProgress",&v)||v!=0||
    !vh_dword(&h,"Setup","OOBEInProgress",&v)||v!=1||
    !vh_dword(&h,"Setup","SetupPhase",&v)||v!=4||
    !vh_dword(&h,"Setup","SetupType",&v)||v!=2||
    !vh_dword(&h,"Setup\\Status\\ChildCompletion","setup.exe",&v)||v!=3||
    !vh_string(&h,"Setup","CmdLine",line,64))return 0;
 const uint16_t normal[]=L"oobe\\windeploy.exe";
 for(unsigned i=0;i<sizeof(normal)/sizeof(normal[0]);i++)if(line[i]!=normal[i])return 0;
 if(!vh_set_string(&h,"Setup","CmdLine",L"C:\\USOS\\end.exe"))return 0;
 vh_seal(&h);return 1;
}
int __stdcall DllMain(void *a,unsigned b,void *c){(void)a;(void)b;(void)c;return 1;}
