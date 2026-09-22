/* Native Vista prerequisite servicing, executed on the target before Setup. */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0600
#include <windows.h>
#include <wincrypt.h>
static HANDLE log_file=INVALID_HANDLE_VALUE;
static WCHAR base[MAX_PATH];
static void note(const char *s,DWORD code){
 char h[13]="0x00000000\r\n";DWORD n;
 for(unsigned i=0;i<8;i++)h[9-i]="0123456789abcdef"[(code>>(i*4))&15];
 WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),s,lstrlenA(s),&n,0);WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),h,12,&n,0);
 if(log_file!=INVALID_HANDLE_VALUE){WriteFile(log_file,s,lstrlenA(s),&n,0);WriteFile(log_file,h,12,&n,0);FlushFileBuffers(log_file);}
}
static BOOL current_framework(void){
 static WCHAR file[MAX_PATH];GetSystemDirectoryW(file,MAX_PATH);lstrcatW(file,L"\\drivers\\Wdf01000.sys");
 DWORD unused,n=GetFileVersionInfoSizeW(file,&unused);if(!n||n>1048576)return FALSE;
 void *b=HeapAlloc(GetProcessHeap(),0,n);if(!b)return FALSE;
 VS_FIXEDFILEINFO *v=0;UINT size=0;BOOL good=FALSE;
 if(GetFileVersionInfoW(file,0,n,b)&&VerQueryValueW(b,L"\\",(void**)&v,&size)&&size>=sizeof(*v)){
  note("KMDF file major/minor=",v->dwFileVersionMS);good=v->dwFileVersionMS>=0x0001000b;
 }
 HeapFree(GetProcessHeap(),0,b);return good;
}
static BOOL verify_cab(const WCHAR *path){
 /* Filled from the Microsoft MSU whose published SHA256 was checked. */
 #include "vista_kmdf_cab_hash.h"
 HCRYPTPROV p=0;HCRYPTHASH h=0;HANDLE f=INVALID_HANDLE_VALUE;BOOL good=FALSE;
 static BYTE b[32768];BYTE digest[32];DWORD n,size=32;
 if(!CryptAcquireContextW(&p,0,0,PROV_RSA_AES,CRYPT_VERIFYCONTEXT)||!CryptCreateHash(p,CALG_SHA_256,0,0,&h))goto end;
 f=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(f==INVALID_HANDLE_VALUE)goto end;
 for(;;){if(!ReadFile(f,b,sizeof(b),&n,0))goto end;if(!n)break;if(!CryptHashData(h,b,n,0))goto end;}
 if(CryptGetHashParam(h,HP_HASHVAL,digest,&size,0)&&size==32){good=TRUE;for(unsigned i=0;i<32;i++)if(digest[i]!=expected[i])good=FALSE;}
 end:if(f!=INVALID_HANDLE_VALUE)CloseHandle(f);if(h)CryptDestroyHash(h);if(p)CryptReleaseContext(p,0);return good;
}
void entry(void){
 static OSVERSIONINFOW v={sizeof(v)};static WCHAR windows[MAX_PATH],path[MAX_PATH],marker[MAX_PATH],cab[MAX_PATH],command[2048],app[MAX_PATH];
 if(!GetVersionExW(&v)||v.dwMajorVersion!=6||v.dwMinorVersion!=0||v.dwBuildNumber!=6002)ExitProcess(2);
 DWORD n=GetModuleFileNameW(0,base,MAX_PATH);if(!n||n>=MAX_PATH-100)ExitProcess(3);
 if(!GetWindowsDirectoryW(windows,MAX_PATH)||windows[0]!=base[0])ExitProcess(3);
 while(n&&base[n-1]!=L'\\')n--;base[n]=0;
 lstrcpyW(path,base);lstrcatW(path,L"kmdf-before-setup.log");
 log_file=CreateFileW(path,GENERIC_WRITE,FILE_SHARE_READ,0,OPEN_ALWAYS,FILE_FLAG_WRITE_THROUGH,0);
 if(log_file==INVALID_HANDLE_VALUE)ExitProcess(GetLastError());SetFilePointer(log_file,0,0,FILE_END);
 note("Vista KB2864202 prerequisite v5=",v.dwBuildNumber);
 lstrcpyW(marker,base);lstrcatW(marker,L"kmdf-install-attempted.flag");
 BOOL ready=current_framework();
 if(ready){note("KMDF 1.11 present; continue to USB=",0);CloseHandle(log_file);ExitProcess(0);}
 if(GetFileAttributesW(marker)!=INVALID_FILE_ATTRIBUTES){note("STOP: previous servicing attempt needs inspection=",ERROR_NOT_READY);ExitProcess(ERROR_NOT_READY);}
 lstrcpyW(cab,base);lstrcatW(cab,L"Updates\\Windows6.0-KB2864202-x64.cab");
 if(!verify_cab(cab)){note("STOP: Microsoft CAB SHA256 mismatch=",ERROR_CRC);ExitProcess(ERROR_CRC);}
 lstrcpyW(path,base);lstrcatW(path,L"Scratch");if(!CreateDirectoryW(path,0)&&GetLastError()!=ERROR_ALREADY_EXISTS)ExitProcess(GetLastError());
 lstrcpyW(app,windows);lstrcatW(app,L"\\System32\\pkgmgr.exe");
 lstrcpyW(command,L"\"");lstrcatW(command,app);lstrcatW(command,L"\" /ip /m:\"");lstrcatW(command,cab);
 lstrcatW(command,L"\" /quiet /norestart /s:\"");lstrcatW(command,path);lstrcatW(command,L"\" /l:\"");
 lstrcatW(command,base);lstrcatW(command,L"kmdf-pkgmgr.log\"");
 HANDLE marker_file=CreateFileW(marker,GENERIC_WRITE,FILE_SHARE_READ,0,CREATE_NEW,FILE_FLAG_WRITE_THROUGH,0);
 if(marker_file==INVALID_HANDLE_VALUE)ExitProcess(GetLastError());CloseHandle(marker_file);
 STARTUPINFOW si={sizeof(si)};PROCESS_INFORMATION pi={0};
 note("Installing full Microsoft package; waiting for Pkgmgr=",0);
 if(!CreateProcessW(app,command,0,0,FALSE,0,0,base,&si,&pi)){note("Pkgmgr start failed=",GetLastError());ExitProcess(4);}
 CloseHandle(pi.hThread);DWORD code=ERROR_GEN_FAILURE;
 if(WaitForSingleObject(pi.hProcess,INFINITE)==WAIT_OBJECT_0)GetExitCodeProcess(pi.hProcess,&code);CloseHandle(pi.hProcess);
 note("Pkgmgr exit=",code);
 if(code!=0&&code!=ERROR_SUCCESS_REBOOT_REQUIRED){CloseHandle(log_file);ExitProcess(code);}
 /* Never load a new framework into this boot: restart before USB regardless of
  * whether pkgmgr reports 0 or 3010. On the next boot inspect actual files. */
 note("Package accepted; restart required before USB=",ERROR_SUCCESS_REBOOT_REQUIRED);
 CloseHandle(log_file);ExitProcess(ERROR_SUCCESS_REBOOT_REQUIRED);
}
