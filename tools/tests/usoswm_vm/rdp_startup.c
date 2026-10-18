/* SPDX-License-Identifier: GPL-3.0-or-later
 * Lab-only use of the existing Startup link, no additional persistence.
 * Starts the byte-identical canonical launcher under an explicit test alias,
 * then launches the evidence actor only inside an actual remote session.
 */
#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#include <windows.h>
static void start(WCHAR *file,const WCHAR *argument,BOOL idle){
 WCHAR command[2*MAX_PATH];lstrcpyW(command,L"\"");lstrcatW(command,file);lstrcatW(command,L"\"");
 if(argument){lstrcatW(command,L" ");lstrcatW(command,argument);}
 STARTUPINFOW si={sizeof(si)};PROCESS_INFORMATION child={0};
 if(CreateProcessW(file,command,0,0,FALSE,CREATE_NO_WINDOW,0,0,&si,&child)){
  CloseHandle(child.hThread);if(idle)WaitForInputIdle(child.hProcess,10000);CloseHandle(child.hProcess);
 }
}
void entry(void){
 WCHAR path[MAX_PATH];DWORD count=GetModuleFileNameW(0,path,MAX_PATH);if(!count||count>=MAX_PATH-48)ExitProcess(2);
 while(count&&path[count-1]!=L'\\')count--;path[count]=0;
 if(lstrcmpiW(path,L"C:\\USOS\\usoswm\\"))ExitProcess(2);
 lstrcatW(path,L"usoswm-real.exe");start(path,0,TRUE);
 if(GetSystemMetrics(SM_REMOTESESSION)){
  WCHAR actor[]=L"C:\\USOS\\WMTEST\\wm-full.exe";start(actor,L"--rdp-session",FALSE);
 }
 ExitProcess(0);
}
