/* SPDX-License-Identifier: GPL-3.0-or-later
 * Optional machine-wide Windows Startup integration. Application state stays
 * beside the executable. Run only by the target OS installer, after approval
 * for the single common-Startup shortcut; never on the development host.
 */
#include "common.h"
#include <shlobj.h>
#include <objbase.h>
#include <sddl.h>
static const GUID shell_link_class={0x00021401,0x0000,0x0000,{0xc0,0x00,0x00,0x00,0x00,0x00,0x00,0x46}};
static const GUID shell_link_interface={0x000214f9,0x0000,0x0000,{0xc0,0x00,0x00,0x00,0x00,0x00,0x00,0x46}};
static const GUID persist_file_interface={0x0000010b,0x0000,0x0000,{0xc0,0x00,0x00,0x00,0x00,0x00,0x00,0x46}};
static BOOL secure_folder(const WCHAR *directory,const WCHAR *sddl){
 PSECURITY_DESCRIPTOR descriptor=0;if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl,SDDL_REVISION_1,&descriptor,0))return FALSE;
 BOOL ok=SetFileSecurityW(directory,DACL_SECURITY_INFORMATION|PROTECTED_DACL_SECURITY_INFORMATION,descriptor);LocalFree(descriptor);return ok;
}
static BOOL trusted_path(const WCHAR *directory){
 WCHAR part[MAX_PATH];DWORD n=lstrlenW(directory);if(n<4||n>=MAX_PATH)return FALSE;lstrcpyW(part,directory);
 for(DWORD i=3;i<=n;i++)if(part[i]==L'\\'||!part[i]){WCHAR save=part[i];part[i]=0;DWORD a=GetFileAttributesW(part);part[i]=save;if(a==INVALID_FILE_ATTRIBUTES||(a&FILE_ATTRIBUTE_REPARSE_POINT))return FALSE;}
 return TRUE;
}
static DWORD register_shortcut(void){
 WCHAR directory[MAX_PATH],launcher[MAX_PATH],shortcut[MAX_PATH];
 if(!wm_directory(0,directory)||!trusted_path(directory))return ERROR_INVALID_NAME;
 /* This tool only applies ACLs to the dedicated component folder, never
  * to arbitrary parent folders or a directory supplied on the command line. */
 DWORD length=lstrlenW(directory);WCHAR parent[MAX_PATH];lstrcpyW(parent,directory);if(length&&parent[length-1]==L'\\')parent[--length]=0;
 DWORD leaf=length;while(leaf&&parent[leaf-1]!=L'\\')leaf--;if(lstrcmpiW(parent+leaf,L"usoswm"))return ERROR_INVALID_NAME;
 if(!secure_folder(parent,L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;GRGX;;;BU)"))return GetLastError();
 lstrcpyW(launcher,directory);lstrcatW(launcher,L"usoswm.exe");DWORD a=GetFileAttributesW(launcher);if(a==INVALID_FILE_ATTRIBUTES||(a&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT)))return ERROR_FILE_NOT_FOUND;
 if(FAILED(SHGetFolderPathW(0,CSIDL_COMMON_STARTUP,0,SHGFP_TYPE_CURRENT,shortcut)))return ERROR_PATH_NOT_FOUND;
 if(lstrlenW(shortcut)>MAX_PATH-24||!trusted_path(shortcut))return ERROR_INVALID_NAME;lstrcatW(shortcut,L"\\USOS desktop.lnk");
 HRESULT hr=CoInitializeEx(0,COINIT_APARTMENTTHREADED);if(FAILED(hr))return (DWORD)hr;
 IShellLinkW *link=0;IPersistFile *file=0;DWORD result=ERROR_GEN_FAILURE;
 hr=CoCreateInstance(&shell_link_class,0,CLSCTX_INPROC_SERVER,&shell_link_interface,(void**)&link);
 if(FAILED(hr)||!link)goto done;
 hr=link->lpVtbl->QueryInterface(link,&persist_file_interface,(void**)&file);if(FAILED(hr)||!file)goto done;
 if(GetFileAttributesW(shortcut)!=INVALID_FILE_ATTRIBUTES){
  WCHAR target[MAX_PATH]={0},arguments[MAX_PATH]={0};
  if(FAILED(file->lpVtbl->Load(file,shortcut,STGM_READ))||FAILED(link->lpVtbl->GetPath(link,target,MAX_PATH,0,SLGP_RAWPATH))||FAILED(link->lpVtbl->GetArguments(link,arguments,MAX_PATH))||lstrcmpiW(target,launcher)||arguments[0]){result=ERROR_ALREADY_EXISTS;goto done;}
  /* Idempotent: do not rewrite a matching, registered launch entry. */
  if(!wm_visible(0)){result=ERROR_SUCCESS;goto logs;}
  result=DeleteFileW(shortcut)?ERROR_SUCCESS:GetLastError();goto done;
 }
 if(wm_visible(0)){result=ERROR_SUCCESS;goto done;}
 if(FAILED(link->lpVtbl->SetPath(link,launcher))||FAILED(link->lpVtbl->SetArguments(link,L""))||FAILED(link->lpVtbl->SetWorkingDirectory(link,directory))||FAILED(link->lpVtbl->SetShowCmd(link,SW_SHOWNORMAL))||FAILED(link->lpVtbl->SetDescription(link,L"USOS test-mode desktop presentation")))goto done;
 hr=file->lpVtbl->Save(file,shortcut,TRUE);if(FAILED(hr))goto done;result=ERROR_SUCCESS;
logs:
 /* Only interactive, non-elevated launchers write here. Registration has
  * no log in this user-writable folder, including on later idempotent runs. */
 lstrcatW(directory,L"logs");if(!CreateDirectoryW(directory,0)&&GetLastError()!=ERROR_ALREADY_EXISTS){result=GetLastError();goto done;}
 if(GetFileAttributesW(directory)&FILE_ATTRIBUTE_REPARSE_POINT){result=ERROR_INVALID_NAME;goto done;}
 if(!secure_folder(directory,L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1201bf;;;BU)"))result=GetLastError();
done:
 if(file)file->lpVtbl->Release(file);if(link)link->lpVtbl->Release(link);CoUninitialize();return result;
}
void entry(void){
 /* No CLI fallback can register this on NT6.1+, x86, or testsigning OFF. */
 if(!wm_supported())ExitProcess(ERROR_NOT_SUPPORTED);
 SID_IDENTIFIER_AUTHORITY authority=SECURITY_NT_AUTHORITY;PSID admins=0;BOOL member=FALSE;
 if(!AllocateAndInitializeSid(&authority,2,SECURITY_BUILTIN_DOMAIN_RID,DOMAIN_ALIAS_RID_ADMINS,0,0,0,0,0,0,&admins))ExitProcess(ERROR_ACCESS_DENIED);
 CheckTokenMembership(0,admins,&member);FreeSid(admins);if(!member)ExitProcess(ERROR_ELEVATION_REQUIRED);
 ExitProcess(register_shortcut());
}
