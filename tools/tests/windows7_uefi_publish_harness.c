/* Exercise the production publisher on a disposable directory, without disks. */
#define entry unused_finalizer_entry
#include "../windows7_uefi_finalize.c"
#undef entry
void entry(void){
 unsigned n=GetModuleFileNameW(0,base,MAX_PATH);
 if(!n||n>=MAX_PATH-48)ExitProcess(2);
 while(n&&base[n-1]!='\\')n--;base[n]=0;
 path(chosen,base,L"target\\");
 ExitProcess(publish_loaders());
}
