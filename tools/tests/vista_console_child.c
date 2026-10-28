/* SPDX-License-Identifier: GPL-3.0-or-later
 * Test that stdout works and an ordinary console child inherits the hidden
 * console without changing either child binary or a host console setting.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
void entry(void){
 HWND console=GetConsoleWindow();if(!console||IsWindowVisible(console))ExitProcess(2);
 DWORD written=0;if(!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),"hidden console stdout works\r\n",28,&written,0)||written!=28)ExitProcess(3);
 const WCHAR *line=GetCommandLineW();DWORD length=lstrlenW(line);
 if(length>=7&&!lstrcmpW(line+length-7,L"--grand"))ExitProcess(0);
 WCHAR self[MAX_PATH],command[MAX_PATH+32];DWORD count=GetModuleFileNameW(0,self,MAX_PATH);if(!count||count>=MAX_PATH)ExitProcess(4);
 lstrcpyW(command,L"\"");lstrcatW(command,self);lstrcatW(command,L"\" --grand");
 STARTUPINFOW start={sizeof(start)};PROCESS_INFORMATION child={0};
 if(!CreateProcessW(self,command,0,0,FALSE,0,0,0,&start,&child))ExitProcess(5);
 CloseHandle(child.hThread);DWORD result=ERROR_TIMEOUT;
 if(WaitForSingleObject(child.hProcess,10000)==WAIT_OBJECT_0)GetExitCodeProcess(child.hProcess,&result);
 else TerminateProcess(child.hProcess,ERROR_TIMEOUT);
 CloseHandle(child.hProcess);ExitProcess(result);
}
