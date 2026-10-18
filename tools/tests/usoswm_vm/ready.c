/* SPDX-License-Identifier: GPL-3.0-or-later
 * Short-lived first-logon notification. Never starts long-lived children:
 * Windows must finish its profile/logon job before desktop tests begin.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stddef.h>
void *memcpy(void *destination,const void *source,size_t count){BYTE *out=destination;const BYTE *in=source;while(count--)*out++=*in++;return destination;}
void *memset(void *destination,int value,size_t count){BYTE *out=destination;while(count--)*out++=(BYTE)value;return destination;}
void entry(void){
 const WCHAR *raw=GetCommandLineW();BOOL arm=FALSE;for(const WCHAR *p=raw;*p;p++)if(p[0]==L'-'&&p[1]==L'-'&&p[2]==L'a')arm=TRUE;
 if(arm){
  HKEY key=0;LONG result=RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SYSTEM\\Setup",0,KEY_QUERY_VALUE|KEY_SET_VALUE,&key);DWORD type=0,phase=0,bytes=4;
  if(!result)result=RegQueryValueExW(key,L"SetupPhase",0,&type,(BYTE*)&phase,&bytes);
  if(!result&&(type!=REG_DWORD||phase!=4))result=ERROR_INVALID_DATA;
  const WCHAR own[]=L"C:\\USOS\\oobe.exe";DWORD setup_type=2;
  if(!result)result=RegSetValueExW(key,L"CmdLine",0,REG_SZ,(const BYTE*)own,sizeof(own));
  if(!result)result=RegSetValueExW(key,L"SetupType",0,REG_DWORD,(const BYTE*)&setup_type,sizeof(setup_type));
  if(!result)result=RegFlushKey(key);if(key)RegCloseKey(key);ExitProcess(result);
 }
 BOOL setup=FALSE;const WCHAR *command=GetCommandLineW();for(;*command;command++)if(command[0]==L'-'&&command[1]==L'-'&&command[2]==L's')setup=TRUE;
 HANDLE port=CreateFileW(L"\\\\.\\COM1",GENERIC_READ|GENERIC_WRITE,0,0,OPEN_EXISTING,0,0);
 if(port!=INVALID_HANDLE_VALUE){
  DCB settings={sizeof(settings)};GetCommState(port,&settings);settings.BaudRate=115200;settings.ByteSize=8;settings.StopBits=ONESTOPBIT;settings.Parity=NOPARITY;SetCommState(port,&settings);
  const char *message=setup?"WM_SETUP_FINISHING\n":"WM_READY_FOR_DESKTOP\n";DWORD written;WriteFile(port,message,lstrlenA(message),&written,0);
  if(setup){char ack;ReadFile(port,&ack,1,&written,0);}
  CloseHandle(port);
 }
 ExitProcess(0);
}
