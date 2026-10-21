/* Vista Setup's hwcompat check predates NVMe. Use the same RAM-copy route
 * as windows_x86_csmwrap.cmd:nvme_setup; do not inject PE10's driver store
 * into an NT 6.0 image. The ISO and normal SATA path remain unchanged. */
static BOOL prepare_nvme64_setup(const WCHAR *source,WCHAR *setup){
 if(!csm_target_nvme)return TRUE;
 WCHAR root[MAX_PATH],compat[MAX_PATH],exe[MAX_PATH];
 path(root,base,L"nvme-setup");
 if(!CreateDirectoryW(root,0))return FALSE;
 GetSystemDirectoryW(exe,MAX_PATH);lstrcatW(exe,L"\\robocopy.exe");
 lstrcpyW(command,L"\"");lstrcatW(command,exe);lstrcatW(command,L"\" \"");
 lstrcatW(command,source);lstrcatW(command,L"\\sources\" \"");lstrcatW(command,root);
 lstrcatW(command,L"\\sources\" /e /r:1 /w:1 /xf install.wim install.esd install.swm /njh /njs /nfl /ndl /np");
 DWORD result=run(exe,command);logcode("NVMe64: Setup RAM copy (robocopy)=",result);if(result>=8)return FALSE;
 path(compat,root,L"\\sources\\hwcompat.txt");
 if(!SetFileAttributesW(compat,FILE_ATTRIBUTE_NORMAL))return FALSE;
 HANDLE file=CreateFileW(compat,FILE_APPEND_DATA,FILE_SHARE_READ,0,OPEN_EXISTING,FILE_FLAG_WRITE_THROUGH,0);
 static const char block[]="\r\nstornvme.inf:\r\nPCI\\CC_010802\r\n";DWORD count=0;
 BOOL ok=file!=INVALID_HANDLE_VALUE&&WriteFile(file,block,sizeof(block)-1,&count,0)&&count==sizeof(block)-1&&FlushFileBuffers(file);
 if(file!=INVALID_HANDLE_VALUE)CloseHandle(file);
 if(!ok)return FALSE;
 /* Vista 6.0 must not see Setup on the PE system drive. DefineDosDevice is
  * SUBST without a shell; select an unused letter and retain it until reboot. */
 WCHAR drive[3]={0,L':',0};DWORD letters=GetLogicalDrives();if(!letters)return FALSE;
 for(int i=25;i>=7;i--)if(!(letters&(1u<<i))){drive[0]=L'A'+i;if(DefineDosDeviceW(0,drive,root))break;drive[0]=0;}
 if(!drive[0])return FALSE;
 path(setup,drive,L"\\sources\\setup.exe");if(!vista_file(setup,TRUE))return FALSE;
 /* The PE booted through the donor's stornvme alias. Disable its dump stack
  * before Setup touches that disk, as the existing x86 path does. */
 HKEY key;DWORD zero=0;
 LONG e=RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SYSTEM\\CurrentControlSet\\Control\\CrashControl",0,KEY_SET_VALUE,&key);
 if(e==ERROR_SUCCESS){
  e=RegSetValueExW(key,L"CrashDumpEnabled",0,REG_DWORD,(const BYTE*)&zero,sizeof(zero));
  if(!e)e=RegSetValueExW(key,L"AutoReboot",0,REG_DWORD,(const BYTE*)&zero,sizeof(zero));
  RegCloseKey(key);
 }
 if(e!=ERROR_SUCCESS||!privilege(L"SeCreatePagefilePrivilege"))return FALSE;
 typedef LONG (WINAPI *SetInfo)(ULONG,PVOID,ULONG);
 SetInfo set_info=(SetInfo)(void*)GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"NtSetSystemInformation");
 ULONG state=0;LONG status=set_info?set_info(34,&state,sizeof(state)):(LONG)0xc0000002;
 logcode("NVMe64: dump-stack refresh NTSTATUS=",(DWORD)status);if(status<0)return FALSE;
 logcode("NVMe64: Setup uses RAM hwcompat copy on SUBST drive=",drive[0]);return TRUE;
}
