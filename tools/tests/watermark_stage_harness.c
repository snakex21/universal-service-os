/* SPDX-License-Identifier: GPL-3.0-or-later
 * Calls only the file-staging function in a disposable folder. No disk APIs,
 * BCD edits, Setup, registry registration or physical media are called.
 */
#define entry vista_entry_not_called
#include "../windows_vista_install.c"
#undef entry
void entry(void){
 DWORD n=GetModuleFileNameW(0,base,MAX_PATH);if(!n||n>=MAX_PATH-64)ExitProcess(2);while(n&&base[n-1]!=L'\\')n--;base[n]=0;
 WCHAR target[MAX_PATH];path(target,base,L"target\\");if(!mkdirs(target))ExitProcess(3);
 stage_testmode_desktop_root(target);ExitProcess(0);
}
