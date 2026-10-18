/* SPDX-License-Identifier: GPL-3.0-or-later */
#define entry unused_gate_entry
#include "../windows_vista_oobe_gate.c"
#undef entry
void entry(void){
 WCHAR target[MAX_PATH];DWORD count=GetModuleFileNameW(0,target,MAX_PATH);
 if(!count||count>=MAX_PATH-32)ExitProcess(1);
 while(count&&target[count-1]!=L'\\')count--;target[count]=0;
 lstrcatW(target,L"console-child.exe");ExitProcess(run(target,TRUE));
}
