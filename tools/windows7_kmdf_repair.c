/* Opt-in, WinPE-only offline repair. No formatting, driver replacement or BCD
 * changes. The request pins both GPT identities and exact disk/partition sizes.
 * DISM applies the complete signed package, including its registry/component store.
 * Exit 10: no request; 0: repaired; 1: stop (never fall through to Setup). */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winioctl.h>
#include <wincrypt.h>
#include <stdio.h>
#include <stdint.h>
#include <wchar.h>
#include <wctype.h>
#include <string.h>

typedef struct { char magic[8]; GUID disk,part; uint64_t offset,length,disk_length; } Request;
_Static_assert(sizeof(Request)==64,"request wire size");
static WCHAR base[MAX_PATH],logs[MAX_PATH],request[MAX_PATH],running[MAX_PATH];
static HANDLE report=INVALID_HANDLE_VALUE;
static void note(const char *s){DWORD n;printf("%s\n",s);if(report!=INVALID_HANDLE_VALUE){WriteFile(report,s,(DWORD)strlen(s),&n,0);WriteFile(report,"\r\n",2,&n,0);FlushFileBuffers(report);}}
static int fail(const char *s){char message[512];snprintf(message,sizeof(message),"STOP: %s (Win32=%lu)",s,GetLastError());note(message);return 1;}
static int read_exact(const WCHAR *path,void *data,DWORD size){
 HANDLE f=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(f==INVALID_HANDLE_VALUE)return 0;
 LARGE_INTEGER length;DWORD n;int ok=GetFileSizeEx(f,&length)&&length.QuadPart==size&&ReadFile(f,data,size,&n,0)&&n==size;CloseHandle(f);return ok;
}
static int paths(void){
 DWORD n=GetModuleFileNameW(0,base,MAX_PATH);if(!n||n>=MAX_PATH-80)return 0;
 WCHAR *slash=wcsrchr(base,L'\\');if(!slash)return 0;slash[1]=0;
 WCHAR path[MAX_PATH];swprintf(path,MAX_PATH,L"%lsusos-log-root.txt",base);
 HANDLE f=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_EXISTING,0,0);if(f==INVALID_HANDLE_VALUE)return 0;
 char data[MAX_PATH];DWORD got;int ok=ReadFile(f,data,sizeof(data),&got,0);CloseHandle(f);if(!ok||got>=MAX_PATH)return 0;
 unsigned i=0;while(i<got&&data[i]!='\r'&&data[i]!='\n'){if(data[i]<32||data[i]>126)return 0;logs[i]=(WCHAR)data[i];i++;}logs[i]=0;
 const WCHAR *prefix=L"\\\\?\\GLOBALROOT\\Device\\Harddisk";
 if(i>MAX_PATH-80||wcsstr(logs,L"..")||wcsncmp(logs,prefix,wcslen(prefix)))return 0;
 wcscpy(request,logs);slash=wcsstr(request,L"\\EFI\\USOS\\Logs\\WinSetup-");if(!slash)return 0;
 wcscpy(slash,L"\\EFI\\USOS\\win7-kmdf-repair.request");
 swprintf(running,MAX_PATH,L"%ls.running",request);
 return 1;
}
static int match_disk(WCHAR letter,const Request *r){
 WCHAR device[]=L"\\\\.\\C:";device[4]=letter;
 HANDLE h=CreateFileW(device,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_EXISTING,0,0);if(h==INVALID_HANDLE_VALUE)return 0;
 PARTITION_INFORMATION_EX p;STORAGE_DEVICE_NUMBER d;DWORD n;
 int ok=DeviceIoControl(h,IOCTL_DISK_GET_PARTITION_INFO_EX,0,0,&p,sizeof(p),&n,0)&&n>=sizeof(p)&&p.PartitionStyle==PARTITION_STYLE_GPT&&
  !memcmp(&p.Gpt.PartitionId,&r->part,16)&&(uint64_t)p.StartingOffset.QuadPart==r->offset&&(uint64_t)p.PartitionLength.QuadPart==r->length&&
  DeviceIoControl(h,IOCTL_STORAGE_GET_DEVICE_NUMBER,0,0,&d,sizeof(d),&n,0)&&n>=sizeof(d);CloseHandle(h);if(!ok)return 0;
 unsigned source=0;if(swscanf(logs,L"\\\\?\\GLOBALROOT\\Device\\Harddisk%u",&source)!=1||source==d.DeviceNumber)return 0;
 WCHAR path[64];swprintf(path,64,L"\\\\.\\PhysicalDrive%lu",d.DeviceNumber);
 h=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_EXISTING,0,0);if(h==INVALID_HANDLE_VALUE)return 0;
 BYTE layout[65536];GET_LENGTH_INFORMATION length;
 ok=DeviceIoControl(h,IOCTL_DISK_GET_DRIVE_LAYOUT_EX,0,0,layout,sizeof(layout),&n,0)&&n>=sizeof(DRIVE_LAYOUT_INFORMATION_EX)&&
  ((DRIVE_LAYOUT_INFORMATION_EX*)layout)->PartitionStyle==PARTITION_STYLE_GPT&&!memcmp(&((DRIVE_LAYOUT_INFORMATION_EX*)layout)->Gpt.DiskId,&r->disk,16)&&
  DeviceIoControl(h,IOCTL_DISK_GET_LENGTH_INFO,0,0,&length,sizeof(length),&n,0)&&(uint64_t)length.Length.QuadPart==r->disk_length;
 CloseHandle(h);return ok;
}
static int win7(WCHAR letter){
 WCHAR path[MAX_PATH];swprintf(path,MAX_PATH,L"%lc:\\Windows\\System32\\ntoskrnl.exe",letter);DWORD unused,size=GetFileVersionInfoSizeW(path,&unused);
 if(!size||size>1024*1024)return 0;void *buffer=HeapAlloc(GetProcessHeap(),0,size);if(!buffer)return 0;
 VS_FIXEDFILEINFO *v=0;UINT length=0;
 int ok=GetFileVersionInfoW(path,0,size,buffer)&&VerQueryValueW(buffer,L"\\",(void**)&v,&length)&&length>=sizeof(*v)&&v->dwSignature==0xfeef04bd&&v->dwFileVersionMS==0x00060001;
 HeapFree(GetProcessHeap(),0,buffer);return ok;
}
static int cab_hash(const WCHAR *path){
 static const BYTE expected[32]={0x60,0x5d,0x94,0x34,0x70,0x93,0x67,0xea,0x39,0x0c,0x00,0x51,0xf9,0x7b,0x77,0xcb,0x1a,0x9a,0x55,0xb2,0x7e,0xb4,0x6e,0x57,0xcc,0x44,0xbd,0x97,0x91,0xc7,0x03,0xbc};
 HCRYPTPROV provider=0;HCRYPTHASH hash=0;HANDLE f=INVALID_HANDLE_VALUE;int ok=0;BYTE bytes[65536],digest[32];DWORD n=0,length=32;
 if(!CryptAcquireContextW(&provider,0,0,PROV_RSA_AES,CRYPT_VERIFYCONTEXT)||!CryptCreateHash(provider,CALG_SHA_256,0,0,&hash))goto end;
 f=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(f==INVALID_HANDLE_VALUE)goto end;
 for(;;){if(!ReadFile(f,bytes,sizeof(bytes),&n,0))goto end;if(!n)break;if(!CryptHashData(hash,bytes,n,0))goto end;}
 ok=CryptGetHashParam(hash,HP_HASHVAL,digest,&length,0)&&length==32&&!memcmp(digest,expected,32);
 end:if(f!=INVALID_HANDLE_VALUE)CloseHandle(f);if(hash)CryptDestroyHash(hash);if(provider)CryptReleaseContext(provider,0);return ok;
}
static int repair(void){
 HKEY key;if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SYSTEM\\CurrentControlSet\\Control\\MiniNT",0,KEY_READ,&key)!=ERROR_SUCCESS)return fail("repair is restricted to WinPE");RegCloseKey(key);
 if(!paths())return fail("verified USB log path unavailable");
 if(GetFileAttributesW(running)!=INVALID_FILE_ATTRIBUTES)return fail("previous repair unfinished; collect USB logs before retry");
 if(GetFileAttributesW(request)==INVALID_FILE_ATTRIBUTES){DWORD error=GetLastError();return error==ERROR_FILE_NOT_FOUND?10:fail("cannot inspect repair request");}
 WCHAR path[MAX_PATH];swprintf(path,MAX_PATH,L"%ls\\kmdf-repair.log",logs);
 report=CreateFileW(path,GENERIC_WRITE,FILE_SHARE_READ,0,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,0);if(report==INVALID_HANDLE_VALUE)return fail("cannot create persistent repair log");
 Request r;if(!read_exact(request,&r,sizeof(r))||memcmp(r.magic,"USOSKMD1",8)||!r.offset||!r.length||!r.disk_length)return fail("invalid repair request");
 WCHAR target=0,windows[MAX_PATH];GetWindowsDirectoryW(windows,MAX_PATH);unsigned found=0;
 for(WCHAR c=L'A';c<=L'Z';c++)if(c!=towupper(windows[0])&&match_disk(c,&r)){target=c;found++;}
 if(found!=1||!win7(target))return fail("exact requested Win7 target not found uniquely");
 WCHAR cab[MAX_PATH];swprintf(cab,MAX_PATH,L"%lsWindows6.1-KB2685811-x64.cab",base);if(!cab_hash(cab))return fail("KMDF package SHA256 mismatch");
 char status[160];snprintf(status,sizeof(status),"Verified target %c: disk/partition GUIDs, sizes and Win7 version. No formatting.",(char)target);note(status);
 swprintf(path,MAX_PATH,L"%ls\\before-kmdf",logs);if(!CreateDirectoryW(path,0))return fail("cannot create backup directory");
 const WCHAR *files[]={L"System32\\config\\SYSTEM",L"System32\\config\\SOFTWARE",L"System32\\config\\COMPONENTS",L"System32\\drivers\\Wdf01000.sys",L"System32\\drivers\\WdfLdr.sys"};
 for(unsigned i=0;i<sizeof(files)/sizeof(files[0]);i++){
  WCHAR from[MAX_PATH],to[MAX_PATH];swprintf(from,MAX_PATH,L"%lc:\\Windows\\%ls",target,files[i]);swprintf(to,MAX_PATH,L"%ls\\before-kmdf\\%ls",logs,wcsrchr(files[i],L'\\')+1);
  if(!CopyFileW(from,to,TRUE))return fail("cannot back up registry/driver files to USB");
 }
 WCHAR scratch[MAX_PATH],dism[MAX_PATH],command[2048],dism_log[MAX_PATH];
 swprintf(scratch,MAX_PATH,L"%lsusos-kmdf-scratch",base);if(!CreateDirectoryW(scratch,0)&&GetLastError()!=ERROR_ALREADY_EXISTS)return fail("cannot create WinPE scratch directory");
 UINT n=GetSystemDirectoryW(dism,MAX_PATH);if(!n||n>MAX_PATH-12)return fail("invalid WinPE system directory");wcscat(dism,L"\\dism.exe");
 /* DISM accepts a normal drive-letter log path reliably; copy it to USB after
  * the process exits. The durable repair log records entry/exit immediately. */
 swprintf(dism_log,MAX_PATH,L"%lsusos-kmdf-dism.log",base);
 swprintf(command,2048,L"\"%ls\" /English /Image:%lc:\\ /Add-Package /PackagePath:\"%ls\" /NoRestart /ScratchDir:\"%ls\" /LogPath:\"%ls\"",dism,target,cab,scratch,dism_log);
 if(!MoveFileW(request,running))return fail("cannot claim one-shot repair request");
 note("Applying complete Microsoft KB2685811 with WinPE DISM. Waiting for process exit.");
 STARTUPINFOW si={0};PROCESS_INFORMATION pi={0};si.cb=sizeof(si);si.lpTitle=L"USOS - KMDF 1.11 / USB dependency repair";
 if(!CreateProcessW(dism,command,0,0,FALSE,CREATE_NEW_CONSOLE,0,base,&si,&pi))return fail("cannot launch WinPE DISM");
 DWORD code=1;int waited=WaitForSingleObject(pi.hProcess,INFINITE)==WAIT_OBJECT_0&&GetExitCodeProcess(pi.hProcess,&code);CloseHandle(pi.hThread);CloseHandle(pi.hProcess);
 swprintf(path,MAX_PATH,L"%ls\\kmdf-dism.log",logs);if(!CopyFileW(dism_log,path,FALSE))note("WARNING: DISM log copy failed; inspect WinPE RAM before reboot.");
 snprintf(status,sizeof(status),"DISM exit=%lu; wait-complete=%d",code,waited);note(status);
 if(!waited||(code!=0&&code!=3010))return fail("DISM did not apply package; request retained as .running; Setup blocked");
 swprintf(path,MAX_PATH,L"%ls.done",request);if(!MoveFileW(running,path))return fail("package accepted but request completion marker failed");
 note("DISM accepted KB2685811. Reboot required; USB function and Windows startup still require hardware verification.");
 MessageBoxW(0,L"Dodano pakiet KMDF 1.11 wymagany przez sterowniki USB.\n\nUruchom ponownie komputer z dysku Intel.\nNie rozpoczeto instalacji Windows. Log zapisano na pendrivie.",L"USOS - naprawa zaleznosci USB",MB_OK|MB_ICONINFORMATION|MB_SETFOREGROUND);
 return 0;
}
int main(void){int code=repair();if(report!=INVALID_HANDLE_VALUE)CloseHandle(report);return code;}
