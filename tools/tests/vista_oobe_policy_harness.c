#include "../vista_oobe_recovery_policy.h"
__declspec(dllexport) int completed(const char *p,unsigned n,const char *name){return vo_completed(p,n,name);}
__declspec(dllexport) int decide(unsigned o,unsigned s,unsigned u,unsigned e){return vo_decide(o,s,u,e);}
int __stdcall DllMain(void *a,unsigned b,void *c){(void)a;(void)b;(void)c;return 1;}
