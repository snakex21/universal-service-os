/* Exercise the production Vista Int10-dispatcher step (windows_vista_install.c,
 * install_int10_dispatcher) on a disposable directory, without disks. */
#define entry unused_vista_entry
#include "../windows_vista_install.c"
#undef entry
void entry(void){
 static WCHAR esp[MAX_PATH],loader[MAX_PATH];
 unsigned n=GetModuleFileNameW(0,base,MAX_PATH);
 if(!n||n>=MAX_PATH-48)ExitProcess(2);
 while(n&&base[n-1]!=L'\\')n--;base[n]=0;
 path(esp,base,L"target\\");path(loader,esp,L"EFI\\Microsoft\\Boot\\bootmgfw.efi");
 ExitProcess(install_int10_dispatcher(esp,loader)?0:1);
}
