/* WinPE-only finalization of the EFI loader written by this Setup run.
 * Snapshot first; never choose by drive letter, disk number or volume label.
 * An ambiguous/unchanged/non-Win7 loader is a hard stop before any EFI writes.
 * All journal and diagnostic data stay beside this executable in WinPE RAM.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winioctl.h>
#include <stddef.h>
#include <winver.h>
#include "windows_setup_result.h"

typedef struct { WCHAR volume[64]; GUID partition; FILETIME loader,bcd; } Record;
typedef struct { DWORD magic,count; Record records[64]; } Snapshot;
static Snapshot before,now;
static WCHAR base[MAX_PATH],a[MAX_PATH],b[MAX_PATH],chosen[MAX_PATH];
static BYTE left[65536],right[65536];
void *memcpy(void *dst,const void *src,size_t n){volatile BYTE *p=dst;const BYTE *q=src;while(n--)*p++=*q++;return dst;}
static void zero(void *v,unsigned n){BYTE *p=v;while(n--)*p++=0;}
static int eq(const void *v,const void *w,unsigned n){const BYTE *p=v,*q=w;while(n--)if(*p++!=*q++)return 0;return 1;}
static unsigned len(const WCHAR *p){unsigned n=0;while(p[n])n++;return n;}
static void copy(WCHAR *p,const WCHAR *q){while((*p++=*q++));}
static void path(WCHAR *p,const WCHAR *dir,const WCHAR *file){copy(p,dir);copy(p+len(p),file);}
static int say(const char *p){DWORD n=0,w;while(p[n])n++;WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),p,n,&w,0);return 1;}
static void number(DWORD n){char s[12];unsigned i=11;s[i]=0;do{s[--i]='0'+n%10;n/=10;}while(n);say(s+i);}
static int same_file(const WCHAR *p,const WCHAR *q){
 HANDLE x=CreateFileW(p,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0),y=CreateFileW(q,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);
 int ok=x!=INVALID_HANDLE_VALUE&&y!=INVALID_HANDLE_VALUE;
 LARGE_INTEGER xs,ys;if(ok)ok=GetFileSizeEx(x,&xs)&&GetFileSizeEx(y,&ys)&&xs.QuadPart>0&&xs.QuadPart==ys.QuadPart;
 while(ok){DWORD xn=0,yn=0;ok=ReadFile(x,left,sizeof(left),&xn,0)&&ReadFile(y,right,sizeof(right),&yn,0)&&xn==yn&&eq(left,right,xn);if(!xn)break;}
 if(x!=INVALID_HANDLE_VALUE)CloseHandle(x);if(y!=INVALID_HANDLE_VALUE)CloseHandle(y);return ok;
}
static FILETIME stamp(const WCHAR *volume,const WCHAR *file){WIN32_FILE_ATTRIBUTE_DATA d;FILETIME t={0,0};path(a,volume,file);if(GetFileAttributesExW(a,GetFileExInfoStandard,&d))t=d.ftLastWriteTime;return t;}
static WCHAR device_names[65536];
static void append_number(WCHAR *s,DWORD n){WCHAR digits[12];unsigned i=0;do{digits[i++]='0'+n%10;n/=10;}while(n);unsigned at=len(s);while(i)s[at++]=digits[--i];s[at]=0;}
static int inventory(Snapshot *s){
 const GUID esp={0xc12a7328,0xf81f,0x11d2,{0xba,0x4b,0,0xa0,0xc9,0x3e,0xc9,0x3b}};
 zero(s,sizeof(*s));s->magic=0x37534555;
 DWORD chars=QueryDosDeviceW(0,device_names,65536);if(!chars)return 0;
 for(WCHAR *name=device_names;*name;name+=len(name)+1){
  unsigned size=len(name);if(size<=13||size>=32||!eq(name,L"PhysicalDrive",13*sizeof(WCHAR)))continue;
  DWORD disk=0;int numeric=1;for(unsigned i=13;i<size;i++){if(name[i]<'0'||name[i]>'9'){numeric=0;break;}if(disk>100000){numeric=0;break;}disk=disk*10+name[i]-'0';}if(!numeric)continue;
  path(a,L"\\\\.\\",name);HANDLE h=CreateFileW(a,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_EXISTING,0,0);if(h==INVALID_HANDLE_VALUE)return 0;
  STORAGE_PROPERTY_QUERY query;zero(&query,sizeof(query));query.PropertyId=StorageDeviceProperty;DWORD got=0;
  int ok=DeviceIoControl(h,IOCTL_STORAGE_QUERY_PROPERTY,&query,sizeof(query),left,sizeof(left),&got,0)&&got>=sizeof(STORAGE_DEVICE_DESCRIPTOR);
  if(ok){STORAGE_DEVICE_DESCRIPTOR *d=(void*)left;ok=!d->RemovableMedia&&(d->BusType==BusTypeAta||d->BusType==BusTypeSata||d->BusType==BusTypeScsi||d->BusType==BusTypeSas||d->BusType==BusTypeRAID||d->BusType==BusTypeNvme);}
  if(!ok){CloseHandle(h);continue;}
  ok=DeviceIoControl(h,IOCTL_DISK_GET_DRIVE_LAYOUT_EX,0,0,left,sizeof(left),&got,0)&&got>=offsetof(DRIVE_LAYOUT_INFORMATION_EX,PartitionEntry);CloseHandle(h);if(!ok)return 0;
  DRIVE_LAYOUT_INFORMATION_EX *layout=(void*)left;if(layout->PartitionStyle!=PARTITION_STYLE_GPT)continue;
  if(layout->PartitionCount>(got - offsetof(DRIVE_LAYOUT_INFORMATION_EX,PartitionEntry))/sizeof(PARTITION_INFORMATION_EX))return 0;
  for(DWORD i=0;i<layout->PartitionCount;i++){
   PARTITION_INFORMATION_EX *p=&layout->PartitionEntry[i];if(p->PartitionStyle!=PARTITION_STYLE_GPT||!eq(&p->Gpt.PartitionType,&esp,sizeof(esp))||p->PartitionLength.QuadPart<=0)continue;
   if(s->count==64)return 0;Record *r=&s->records[s->count++];r->partition=p->Gpt.PartitionId;
   copy(r->volume,L"\\\\?\\GLOBALROOT\\Device\\Harddisk");append_number(r->volume,disk);copy(r->volume+len(r->volume),L"\\Partition");append_number(r->volume,p->PartitionNumber);copy(r->volume+len(r->volume),L"\\");
   r->loader=stamp(r->volume,L"EFI\\Microsoft\\Boot\\bootmgfw.efi");r->bcd=stamp(r->volume,L"EFI\\Microsoft\\Boot\\BCD");
  }
 }
 return 1;
}
static int transfer_snapshot(int write){
 path(a,base,L"uefi-before.bin");HANDLE h=CreateFileW(a,write?GENERIC_WRITE:GENERIC_READ,FILE_SHARE_READ,0,write?CREATE_NEW:OPEN_EXISTING,0,0);if(h==INVALID_HANDLE_VALUE)return 0;
 DWORD n=0;int ok=write?WriteFile(h,&before,sizeof(before),&n,0):ReadFile(h,&before,sizeof(before),&n,0);
 if(write)ok=ok&&FlushFileBuffers(h);CloseHandle(h);return ok&&n==sizeof(before)&&before.magic==0x37534555&&before.count<=64;
}
static WCHAR bcdedit_path[MAX_PATH];
static GUID selected_store;
static int have_store;
static int initialize_store_command(void){
 unsigned n=GetSystemDirectoryW(bcdedit_path,MAX_PATH);if(!n||n>MAX_PATH-16)return 0;copy(bcdedit_path+n,L"\\bcdedit.exe");
 return GetFileAttributesW(bcdedit_path)!=INVALID_FILE_ATTRIBUTES;
}
static int set_temporary_store(const WCHAR *volume){
 WCHAR native[64];copy(native,volume+14);unsigned n=len(native);if(n<2||native[n-1]!='\\')return 0;native[--n]=0;
 DWORD letters=GetLogicalDrives();if(!letters)return 0;WCHAR alias[3]={0,':',0};for(int i=25;i>=3;i--)if(!(letters&(1u<<i))){alias[0]='A'+i;break;}if(!alias[0])return 0;
 /* A short-lived DOS alias lets the original Win7 BCDEdit resolve its own
  * system-device hint. WinPE 7 has no separate bcd.dll to call directly. */
 if(!DefineDosDeviceW(DDD_RAW_TARGET_PATH|DDD_NO_BROADCAST_SYSTEM,alias,native))return 0;
 WCHAR command[MAX_PATH+48];copy(command,L"\"");copy(command+len(command),bcdedit_path);copy(command+len(command),L"\" /sysstore ");copy(command+len(command),alias);
 STARTUPINFOW si;PROCESS_INFORMATION pi;zero(&si,sizeof(si));zero(&pi,sizeof(pi));si.cb=sizeof(si);DWORD result=1;
 int ok=CreateProcessW(bcdedit_path,command,0,0,FALSE,CREATE_NO_WINDOW,0,0,&si,&pi);
 if(ok){ok=WaitForSingleObject(pi.hProcess,INFINITE)==WAIT_OBJECT_0&&GetExitCodeProcess(pi.hProcess,&result);CloseHandle(pi.hThread);CloseHandle(pi.hProcess);}
 int removed=DefineDosDeviceW(DDD_REMOVE_DEFINITION|DDD_EXACT_MATCH_ON_REMOVE|DDD_RAW_TARGET_PATH|DDD_NO_BROADCAST_SYSTEM,alias,native);
 return ok&&result==0&&removed;
}
/* BCD's EFI system-device hint is volatile, like bcdedit /sysstore. Win7
 * otherwise mistakes the USB ESP plus the new internal ESP for an ambiguous
 * system device. No partition or BCD file is written by this operation.
 * Existing multiple ESPs are never resolved by disk order. */
static void refresh_system_store(void){
 if(!inventory(&now))return;
 Record *candidate=0;unsigned count=0;
 if(now.count==1){candidate=&now.records[0];count=1;}
 else for(unsigned i=0;i<now.count;i++){
  Record *r=&now.records[i];int old=0;for(unsigned j=0;j<before.count;j++)if(eq(&r->partition,&before.records[j].partition,sizeof(GUID)))old=1;
  if(!old){candidate=r;count++;}
 }
 if(count!=1||!candidate||(have_store&&eq(&candidate->partition,&selected_store,sizeof(GUID))))return;
 if(!set_temporary_store(candidate->volume))return;
 selected_store=candidate->partition;have_store=1;say("UEFI: selected the unique internal system partition for this WinPE session.\r\n");
}
static int run_setup(const WCHAR *executable,const WCHAR *arguments){
 if(!transfer_snapshot(0)||!initialize_store_command())return say("UEFI: cannot initialize the temporary system-device selection.\r\n");
 static WCHAR command[8192];if(len(executable)+len(arguments)+4>=8192)return 1;
 copy(command,L"\"");copy(command+1,executable);copy(command+len(command),L"\" ");copy(command+len(command),arguments);refresh_system_store();
 STARTUPINFOW si;PROCESS_INFORMATION pi;zero(&si,sizeof(si));zero(&pi,sizeof(pi));si.cb=sizeof(si);
 if(!CreateProcessW(executable,command,0,0,FALSE,CREATE_NO_WINDOW,0,0,&si,&pi))return say("UEFI: cannot launch Windows Setup.\r\n");
 CloseHandle(pi.hThread);DWORD wait;
 while((wait=WaitForSingleObject(pi.hProcess,100))==WAIT_TIMEOUT)refresh_system_store();
 DWORD result=1;int ok=wait==WAIT_OBJECT_0&&GetExitCodeProcess(pi.hProcess,&result);CloseHandle(pi.hProcess);
 if(ok)usos_record_setup_result(result);
 return ok?(int)result:1;
}
#include "windows7_uefi_publish.h"
static int win7_loader(const WCHAR *file){
 DWORD ignored=0,size=GetFileVersionInfoSizeW(file,&ignored);if(!size||size>sizeof(left))return 0;
 if(!GetFileVersionInfoW(file,0,size,left))return 0;
 VS_FIXEDFILEINFO *version=0;UINT bytes=0;
 return VerQueryValueW(left,L"\\",(void**)&version,&bytes)&&bytes>=sizeof(*version)&&version->dwSignature==0xfeef04bd&&version->dwFileVersionMS==0x00060001;
}
static int finish(int modern){
 if(!transfer_snapshot(0)||!inventory(&now))return say("UEFI: cannot read the before/after inventory.\r\n");
 say("UEFI: initial ESPs=");number(before.count);say(" current ESPs=");number(now.count);say("\r\n");
 unsigned count=0;
 for(unsigned i=0;i<now.count;i++){
  Record *r=&now.records[i],*old=0;for(unsigned j=0;j<before.count;j++)if(eq(&r->partition,&before.records[j].partition,sizeof(GUID))){if(old)return say("UEFI: duplicate partition identity.\r\n");old=&before.records[j];}
  if(!(r->loader.dwLowDateTime|r->loader.dwHighDateTime)||!(r->bcd.dwLowDateTime|r->bcd.dwHighDateTime))continue;
  /* Setup can preserve the signed loader's original timestamp when copying.
   * The BCD must have changed in this run, and the loader must match our ISO. */
  if(old&&eq(&old->bcd,&r->bcd,sizeof(FILETIME)))continue;
  path(a,r->volume,L"EFI\\Microsoft\\Boot\\bootmgfw.efi");path(b,base,L"win7.original.efi");
  if(modern){if(!win7_loader(a))continue;}
  else if(!same_file(a,b)){say("UEFI: target loader differs from the selected ISO.\r\n");continue;}copy(chosen,r->volume);count++;
 }
 if(count!=1)return say("UEFI: expected exactly one new Windows 7 EFI loader; no files changed.\r\n");
 /* Modern PE contains its own (newer) loader. Preserve the Win7 loader
  * actually written by Setup, after the unique changed BCD/version checks. */
 if(modern){
  path(a,chosen,L"EFI\\Microsoft\\Boot\\bootmgfw.efi");path(b,base,L"win7.original.efi");
  if(GetFileAttributesW(b)==INVALID_FILE_ATTRIBUTES&&!CopyFileW(a,b,TRUE))return say("UEFI: cannot preserve the installed Windows 7 loader.\r\n");
  if(!same_file(a,b))return say("UEFI: preserved Windows 7 loader readback failed.\r\n");
 }
 if(publish_loaders())return say("UEFI: could not finish both boot entries.\r\n");
 say("UEFI: Windows 7 target loader prepared and verified.\r\n");return 0;
}
void entry(void){
 HKEY k;if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SYSTEM\\CurrentControlSet\\Control\\MiniNT",0,KEY_READ,&k)!=ERROR_SUCCESS)ExitProcess(1);RegCloseKey(k);
 unsigned n=GetModuleFileNameW(0,base,MAX_PATH);if(!n||n>=MAX_PATH-48)ExitProcess(1);while(n&&base[n-1]!='\\')n--;base[n]=0;if(!n)ExitProcess(1);
 const WCHAR *c=GetCommandLineW();int quote=0;while(*c){if(*c=='"')quote=!quote;else if(*c==' '&&!quote)break;c++;}while(*c==' ')c++;
 unsigned count=len(c);
 if(count==6&&eq(c,L"before",6*sizeof(WCHAR))){if(!inventory(&before)||!transfer_snapshot(1))ExitProcess(say("UEFI: cannot save initial inventory.\r\n"));ExitProcess(0);}
 if(count==5&&eq(c,L"after",5*sizeof(WCHAR)))ExitProcess(finish(0));
 if(count==12&&eq(c,L"after-modern",12*sizeof(WCHAR)))ExitProcess(finish(1));
 if(count>4&&eq(c,L"run ",4*sizeof(WCHAR)))ExitProcess(run_setup(L"X:\\sources\\setup.exe",c+4));
 if(count>11&&eq(c,L"run-from \"",10*sizeof(WCHAR))){
  static WCHAR executable[MAX_PATH];const WCHAR *start=c+10;unsigned i=0;
  while(start[i]&&start[i]!='"'&&i<MAX_PATH-1){executable[i]=start[i];i++;}
  if(!i||start[i]!='"')ExitProcess(1);executable[i]=0;c=start+i+1;while(*c==' ')c++;
  ExitProcess(run_setup(executable,c));
 }
 ExitProcess(1);
}
