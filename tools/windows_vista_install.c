/* WinPE10-only Vista Setup runner. Target writes happen only after Setup exits
 * successfully and exactly one changed, internal GPT Vista SP2 image is found.
 * No partitioning/formatting: the user makes those choices in Windows Setup.
 */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0602
#include <windows.h>
#include <winioctl.h>
#include <wincrypt.h>
#include <winver.h>
#include <dbt.h>
#include <stddef.h>
#include "vista_deploy_files.h"
#include "vista_boot_files.h"
#include "vista_hive.h"
#include "vista_servicing_answer.h"
#include "windows_setup_result.h"
#include "windows_winpe_ui.h"

static WCHAR base[MAX_PATH], scratch[MAX_PATH], command[2048];
static BYTE buffer[65536];
static HANDLE log_file=INVALID_HANDLE_VALUE;
typedef struct { WCHAR root[4]; DWORD disk; GUID id; BYTE hash[32]; } Target;
static Target before[26],after[26];
static DWORD before_count,after_count;
typedef struct { DWORD disk,number; GUID id,disk_id; ULONGLONG disk_size,offset; BOOL formatted; } Esp;
typedef struct { BYTE magic[8]; GUID disk_id,esp_id; ULONGLONG disk_size; } BootProfile;
_Static_assert(sizeof(BootProfile)==48,"Boot profile wire size");
static BootProfile boot_profile;
static BOOL pinned_esp,store_ready;
static DWORD store_error;
static WCHAR vista_bcdedit[MAX_PATH];
static Esp original_esps[64],selected_esp;
static DWORD original_esp_count;
static DWORD profile_disk_count,profile_disk_number;
static BOOL have_selected_esp;
/* Vista without firmware CSM (usos-vista-csmwrap.flag, profile
 * vista-x64-sp2-uefi-csmwrap; docs/design/csmwrap-integration.md 10): PE10 was
 * booted in BIOS mode through CSMWrap from the target's staging partition, so
 * Vista Setup installs a legacy MBR system. The target disk is the one with
 * the MBR signature of usos-vista-target.ini. */
static BOOL csmwrap;
static DWORD csm_signature,csm_disk=0xffffffff;
static ULONGLONG csm_staging_start,csm_staging_sectors;
void *memcpy(void *d,const void *s,size_t n){volatile BYTE *p=d;const BYTE *q=s;while(n--)*p++=*q++;return d;}
void *memset(void *d,int v,size_t n){volatile BYTE *p=d;while(n--)*p++=(BYTE)v;return d;}
static BOOL same(const void *a,const void *b,DWORD n){const BYTE *x=a,*y=b;while(n--)if(*x++!=*y++)return FALSE;return TRUE;}
static void path(WCHAR *out,const WCHAR *root,const WCHAR *tail){lstrcpyW(out,root);lstrcatW(out,tail);}
static void logcode(const char *text,DWORD code){
 char number[13]="0x00000000\r\n";DWORD n;
 for(unsigned i=0;i<8;i++)number[9-i]="0123456789abcdef"[(code>>(4*i))&15];
 WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),text,lstrlenA(text),&n,0);WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),number,12,&n,0);
 if(log_file!=INVALID_HANDLE_VALUE){WriteFile(log_file,text,lstrlenA(text),&n,0);WriteFile(log_file,number,12,&n,0);FlushFileBuffers(log_file);}
}
static BOOL hash_file(const WCHAR *file,BYTE hash[32]){
 HCRYPTPROV provider=0;HCRYPTHASH digest=0;BOOL ok=FALSE;DWORD got,size=32;
 HANDLE h=CreateFileW(file,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);
 if(h==INVALID_HANDLE_VALUE)return FALSE;
 if(CryptAcquireContextW(&provider,0,0,PROV_RSA_AES,CRYPT_VERIFYCONTEXT)&&CryptCreateHash(provider,CALG_SHA_256,0,0,&digest)){
  ok=TRUE;
  for(;;){if(!ReadFile(h,buffer,sizeof(buffer),&got,0)){ok=FALSE;break;}if(!got)break;if(!CryptHashData(digest,buffer,got,0)){ok=FALSE;break;}}
  if(ok)ok=CryptGetHashParam(digest,HP_HASHVAL,hash,&size,0)&&size==32;
 }
 if(digest)CryptDestroyHash(digest);if(provider)CryptReleaseContext(provider,0);CloseHandle(h);return ok;
}
static BOOL vista_file(const WCHAR *file,BOOL sp2){
 DWORD ignored=0,size=GetFileVersionInfoSizeW(file,&ignored);if(!size||size>sizeof(buffer))return FALSE;
 VS_FIXEDFILEINFO *v=0;UINT bytes=0;
 return GetFileVersionInfoW(file,0,size,buffer)&&VerQueryValueW(buffer,L"\\",(void**)&v,&bytes)&&bytes>=sizeof(*v)&&v->dwFileVersionMS==0x00060000&&(!sp2||(v->dwFileVersionLS>>16)==6002);
}
static BOOL privilege(const WCHAR *name){
 HANDLE token=0;TOKEN_PRIVILEGES p={0};BOOL ok=FALSE;
 if(OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY|TOKEN_ADJUST_PRIVILEGES,&token)){
  p.PrivilegeCount=1;p.Privileges[0].Attributes=SE_PRIVILEGE_ENABLED;
  if(LookupPrivilegeValueW(0,name,&p.Privileges[0].Luid))ok=AdjustTokenPrivileges(token,FALSE,&p,0,0,0)&&GetLastError()==ERROR_SUCCESS;
  CloseHandle(token);
 }return ok;
}
static void decimal(WCHAR *out,DWORD value){WCHAR digits[12];DWORD n=0;do{digits[n++]=L'0'+value%10;value/=10;}while(value);while(n)*out++=digits[--n];*out=0;}
static HANDLE disk_handle(DWORD disk){WCHAR name[40]=L"\\\\.\\PhysicalDrive";decimal(name+lstrlenW(name),disk);return CreateFileW(name,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_EXISTING,0,0);}
static BOOL internal(HANDLE disk){
 STORAGE_PROPERTY_QUERY q={0};q.PropertyId=StorageDeviceProperty;DWORD got;
 if(!DeviceIoControl(disk,IOCTL_STORAGE_QUERY_PROPERTY,&q,sizeof(q),buffer,sizeof(buffer),&got,0)||got<sizeof(STORAGE_DEVICE_DESCRIPTOR))return FALSE;
 STORAGE_DEVICE_DESCRIPTOR *d=(void*)buffer;
 return !d->RemovableMedia&&(d->BusType==BusTypeAta||d->BusType==BusTypeSata||d->BusType==BusTypeScsi||d->BusType==BusTypeSas||d->BusType==BusTypeRAID||d->BusType==BusTypeNvme);
}
static BOOL identity(const WCHAR *root,Target *t){
 WCHAR name[8]=L"\\\\.\\C:";name[4]=root[0];DWORD got;
 HANDLE h=CreateFileW(name,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_EXISTING,0,0);
 if(h==INVALID_HANDLE_VALUE)return FALSE;
 VOLUME_DISK_EXTENTS e;BOOL ok=DeviceIoControl(h,IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS,0,0,&e,sizeof(e),&got,0)&&e.NumberOfDiskExtents==1;
 PARTITION_INFORMATION_EX p;
 if(ok)ok=DeviceIoControl(h,IOCTL_DISK_GET_PARTITION_INFO_EX,0,0,&p,sizeof(p),&got,0)&&p.PartitionStyle==(csmwrap?PARTITION_STYLE_MBR:PARTITION_STYLE_GPT);
 CloseHandle(h);if(!ok)return FALSE;
 /* CSMWrap: only partitions of the prepared MBR disk. */
 if(csmwrap&&e.Extents[0].DiskNumber!=csm_disk)return FALSE;
 h=disk_handle(e.Extents[0].DiskNumber);if(h==INVALID_HANDLE_VALUE)return FALSE;ok=internal(h);CloseHandle(h);
 if(!ok)return FALSE;lstrcpyW(t->root,root);t->disk=e.Extents[0].DiskNumber;
 /* An MBR partition's identity is what MountedDevices stores for it: the
  * disk signature (4 bytes) and the partition offset (8 bytes). */
 if(csmwrap){ULONGLONG offset=(ULONGLONG)p.StartingOffset.QuadPart;memset(&t->id,0,16);memcpy(&t->id,&csm_signature,4);memcpy((BYTE*)&t->id+4,&offset,8);}
 else t->id=p.Gpt.PartitionId;
 return TRUE;
}
static BOOL inventory(Target *targets,DWORD *count){
 DWORD letters=GetLogicalDrives();if(!letters)return FALSE;*count=0;
 for(DWORD i=2;i<26;i++)if(letters&(1u<<i)){
  WCHAR root[4]={L'A'+i,L':',L'\\',0};Target t={0};
  if(!identity(root,&t))continue;
  path(scratch,root,L"Windows\\System32\\ntoskrnl.exe");if(!vista_file(scratch,TRUE))continue;
  path(scratch,root,L"Windows\\System32\\config\\SYSTEM");if(!hash_file(scratch,t.hash))return FALSE;
  targets[(*count)++]=t;
 }return TRUE;
}
static DWORD run(const WCHAR *executable,WCHAR *line){
 STARTUPINFOW si={0};PROCESS_INFORMATION pi={0};si.cb=sizeof(si);DWORD result=1;
 if(!CreateProcessW(executable,line,0,0,FALSE,CREATE_NO_WINDOW,0,base,&si,&pi)){logcode("CreateProcess failed=",GetLastError());return 1;}
 if(WaitForSingleObject(pi.hProcess,INFINITE)==WAIT_OBJECT_0)GetExitCodeProcess(pi.hProcess,&result);
 CloseHandle(pi.hThread);CloseHandle(pi.hProcess);return result;
}
static BOOL bcd_command(const WCHAR *store,const WCHAR *arguments){
 WCHAR exe[MAX_PATH];GetSystemDirectoryW(exe,MAX_PATH);lstrcatW(exe,L"\\bcdedit.exe");
 lstrcpyW(command,L"\"");lstrcatW(command,exe);lstrcatW(command,L"\" ");
 if(store){lstrcatW(command,L"/store \"");lstrcatW(command,store);lstrcatW(command,L"\" ");}
 lstrcatW(command,arguments);DWORD result=run(exe,command);logcode("BCDEdit result=",result);return result==0;
}
static const GUID esp_type={0xc12a7328,0xf81f,0x11d2,{0xba,0x4b,0,0xa0,0xc9,0x3e,0xc9,0x3b}};
static BOOL mount_esp(DWORD disk,WCHAR alias[4]){
 HANDLE h=disk_handle(disk);DWORD got;BOOL ok=h!=INVALID_HANDLE_VALUE&&internal(h);
 if(ok)ok=DeviceIoControl(h,IOCTL_DISK_GET_DRIVE_LAYOUT_EX,0,0,buffer,sizeof(buffer),&got,0)&&got>=offsetof(DRIVE_LAYOUT_INFORMATION_EX,PartitionEntry);
 if(h!=INVALID_HANDLE_VALUE)CloseHandle(h);if(!ok)return FALSE;
 DRIVE_LAYOUT_INFORMATION_EX *layout=(void*)buffer;DWORD count=0,number=0;
 if(layout->PartitionStyle!=PARTITION_STYLE_GPT||layout->PartitionCount>(got - offsetof(DRIVE_LAYOUT_INFORMATION_EX,PartitionEntry))/sizeof(PARTITION_INFORMATION_EX))return FALSE;
 for(DWORD i=0;i<layout->PartitionCount;i++)if(same(&layout->PartitionEntry[i].Gpt.PartitionType,&esp_type,sizeof(GUID))&&
   (!have_selected_esp||(selected_esp.disk==disk&&same(&layout->PartitionEntry[i].Gpt.PartitionId,&selected_esp.id,sizeof(GUID))))){number=layout->PartitionEntry[i].PartitionNumber;count++;}
 if(count!=1)return FALSE;
 DWORD letters=GetLogicalDrives();if(!letters)return FALSE;WCHAR device[80]=L"\\Device\\Harddisk";
 decimal(device+lstrlenW(device),disk);lstrcatW(device,L"\\Partition");decimal(device+lstrlenW(device),number);
 for(int i=25;i>=3;i--)if(!(letters&(1u<<i))){alias[0]=L'A'+i;alias[1]=L':';alias[2]=0;
  if(!DefineDosDeviceW(DDD_RAW_TARGET_PATH|DDD_NO_BROADCAST_SYSTEM,alias,device))return FALSE;
  alias[2]=L'\\';alias[3]=0;return TRUE;
 }return FALSE;
}
static void unmount_esp(WCHAR alias[4]){if(alias[0]){alias[2]=0;DefineDosDeviceW(DDD_REMOVE_DEFINITION|DDD_NO_BROADCAST_SYSTEM,alias,0);alias[0]=0;}}
/* Enumerate internal ESP identities, including unlettered/new partitions.
 * This is called on notifications, never on a timed progress loop. */
static BOOL esp_inventory(Esp *esps,DWORD *count){
 static WCHAR names[65536];DWORD chars=QueryDosDeviceW(0,names,65536);if(!chars)return FALSE;*count=0;profile_disk_count=0;
 for(WCHAR *name=names;*name;name+=lstrlenW(name)+1){
  if(lstrlenW(name)<=13||!same(name,L"PhysicalDrive",13*sizeof(WCHAR)))continue;
  DWORD disk=0;BOOL numeric=TRUE;for(DWORD i=13;name[i];i++){if(name[i]<L'0'||name[i]>L'9'||disk>100000){numeric=FALSE;break;}disk=disk*10+name[i]-L'0';}if(!numeric)continue;
  HANDLE h=disk_handle(disk);if(h==INVALID_HANDLE_VALUE)return FALSE;
  if(!internal(h)){CloseHandle(h);continue;}
  GET_LENGTH_INFORMATION length;DWORD length_got;
  if(!DeviceIoControl(h,IOCTL_DISK_GET_LENGTH_INFO,0,0,&length,sizeof(length),&length_got,0)){CloseHandle(h);return FALSE;}
  DWORD got;BOOL ok=DeviceIoControl(h,IOCTL_DISK_GET_DRIVE_LAYOUT_EX,0,0,buffer,sizeof(buffer),&got,0);CloseHandle(h);
  if(!ok||got<offsetof(DRIVE_LAYOUT_INFORMATION_EX,PartitionEntry))return FALSE;
  DRIVE_LAYOUT_INFORMATION_EX *layout=(void*)buffer;if(layout->PartitionStyle!=PARTITION_STYLE_GPT)continue;
  if(pinned_esp&&same(&layout->Gpt.DiskId,&boot_profile.disk_id,16)&&length.Length.QuadPart==boot_profile.disk_size){profile_disk_count++;profile_disk_number=disk;}
  if(layout->PartitionCount>(got - offsetof(DRIVE_LAYOUT_INFORMATION_EX,PartitionEntry))/sizeof(PARTITION_INFORMATION_EX))return FALSE;
  for(DWORD i=0;i<layout->PartitionCount;i++){
   PARTITION_INFORMATION_EX *p=&layout->PartitionEntry[i];if(p->PartitionStyle!=PARTITION_STYLE_GPT||!same(&p->Gpt.PartitionType,&esp_type,16))continue;
   if(*count==64)return FALSE;Esp *e=&esps[(*count)++];e->disk=disk;e->number=p->PartitionNumber;e->id=p->Gpt.PartitionId;e->disk_id=layout->Gpt.DiskId;e->disk_size=length.Length.QuadPart;e->offset=(ULONGLONG)p->StartingOffset.QuadPart;e->formatted=FALSE;
  }
 }return TRUE;
}
static int choose_esp(const Esp *old_esps,DWORD old_count,const Esp *current,DWORD count){
 DWORD new_count=0;int candidate=-1;
 for(DWORD i=0;i<count;i++){
  BOOL old=FALSE;for(DWORD j=0;j<old_count;j++)if(current[i].disk==old_esps[j].disk&&same(&current[i].id,&old_esps[j].id,16))old=TRUE;
  if(!old){candidate=(int)i;new_count++;}
 }
 if(new_count==0&&count==1)return 0;
 /* Several ESPs that all existed before Setup (X470 2026-09-27: the Windows 7
  * ESP plus a raw ESP left by a failed run; Vista's disk page does not list
  * ESPs, so the user cannot delete them): use the only one that carried a FAT
  * file system before Setup started. */
 if(new_count==0&&count>1){
  int only=-1;DWORD formatted=0;
  for(DWORD i=0;i<count;i++)for(DWORD j=0;j<old_count;j++)
   if(current[i].disk==old_esps[j].disk&&same(&current[i].id,&old_esps[j].id,16)&&old_esps[j].formatted){only=(int)i;formatted++;}
  if(formatted==1)return only;
 }
 return new_count==1?candidate:-1;
}
static BOOL profile_matches(const BootProfile *profile,const Esp *esp){
 return same(&esp->disk_id,&profile->disk_id,16)&&esp->disk_size==profile->disk_size;
}
static int choose_pinned_esp(const BootProfile *profile,const Esp *previous,DWORD previous_count,const Esp *current,DWORD count){
 int preferred=-1,only=-1,fresh=-1;DWORD matches=0,new_count=0;
 for(DWORD i=0;i<count;i++)if(profile_matches(profile,&current[i])){
  /* A duplicated partition identity is never a unique target. */
  for(DWORD j=0;j<i;j++)if(profile_matches(profile,&current[j])&&same(&current[i].id,&current[j].id,16))return -1;
  only=(int)i;matches++;
  if(same(&current[i].id,&profile->esp_id,16))preferred=(int)i;
  BOOL old=FALSE;for(DWORD j=0;j<previous_count;j++)if(profile_matches(profile,&previous[j])&&same(&current[i].id,&previous[j].id,16))old=TRUE;
  if(!old){fresh=(int)i;new_count++;}
 }
 if(preferred>=0)return preferred;
 /* After deletion, accept a new ESP on this disk, not a leftover ESP from
  * an ambiguous initial layout. Disk GUID/size stay bound throughout. */
 if(new_count)return new_count==1?fresh:-1;
 DWORD initial=0;for(DWORD j=0;j<previous_count;j++)if(profile_matches(profile,&previous[j]))initial++;
 return matches==1&&initial<=1?only:-1;
}
/* EFI\USOS\vista-target.ini on the USOS ESP, written by the micro-Linux disk
 * preparation (tools/vista_disk_prepare.sh): pin that disk and its fresh ESP
 * like the hardware boot profile. The USOS ESP is found through
 * usos-log-root.txt (\\?\GLOBALROOT\Device\HarddiskN\PartitionM\EFI\USOS\Logs\...). */
static WCHAR prepared_record[MAX_PATH];
static BOOL parse_guid(const char *t,GUID *g){
 static const int at[16]={0,2,4,6,9,11,14,16,19,21,24,26,28,30,32,34};BYTE b[16];
 for(int i=0;i<36;i++)if((i==8||i==13||i==18||i==23)?t[i]!='-':!((t[i]>='0'&&t[i]<='9')||(t[i]>='a'&&t[i]<='f')||(t[i]>='A'&&t[i]<='F')))return FALSE;
 for(int i=0;i<16;i++){BYTE v=0;for(int k=0;k<2;k++){char c=t[at[i]+k];v=(BYTE)(v*16+(c<='9'?c-'0':(c|32)-'a'+10));}b[i]=v;}
 g->Data1=((DWORD)b[0]<<24)|((DWORD)b[1]<<16)|((DWORD)b[2]<<8)|b[3];g->Data2=(WORD)((b[4]<<8)|b[5]);g->Data3=(WORD)((b[6]<<8)|b[7]);
 for(int i=0;i<8;i++)g->Data4[i]=b[8+i];return TRUE;
}
static const char *ini_value(const char *text,const char *key){
 unsigned n=lstrlenA(key);
 for(const char *line=text;*line;){
  if(same(line,key,n)&&line[n]=='=')return line+n+1;
  while(*line&&*line!='\n')line++;if(*line)line++;
 }return 0;
}
static BOOL load_prepared_disk(void){
 static char root[MAX_PATH],text[1024];WCHAR file[MAX_PATH];DWORD got=0;
 path(file,base,L"usos-log-root.txt");HANDLE h=CreateFileW(file,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_EXISTING,0,0);
 if(h==INVALID_HANDLE_VALUE)return FALSE;BOOL ok=ReadFile(h,root,MAX_PATH-1,&got,0);CloseHandle(h);if(!ok)return FALSE;root[got]=0;
 char *cut=0;for(char *p=root;*p;p++)if(same(p,"\\EFI\\USOS\\Logs\\",15)){cut=p;break;}
 if(!cut||cut-root>MAX_PATH-40)return FALSE;*cut=0;
 unsigned n=0;for(char *p=root;*p;p++)prepared_record[n++]=(WCHAR)(BYTE)*p;prepared_record[n]=0;
 /* The preparation is opt-in (EFI\USOS\vista-disk-prep.flag, user decision
  * 2026-09-27): without the flag a leftover record is ignored. */
 WCHAR enable[MAX_PATH];lstrcpyW(enable,prepared_record);lstrcatW(enable,L"\\EFI\\USOS\\vista-disk-prep.flag");
 if(GetFileAttributesW(enable)==INVALID_FILE_ATTRIBUTES){prepared_record[0]=0;return FALSE;}
 lstrcatW(prepared_record,L"\\EFI\\USOS\\vista-target.ini");
 h=CreateFileW(prepared_record,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(h==INVALID_HANDLE_VALUE){prepared_record[0]=0;return FALSE;}
 ok=ReadFile(h,text,sizeof(text)-1,&got,0);CloseHandle(h);if(!ok)return FALSE;text[got]=0;
 const char *state=ini_value(text,"state"),*disk=ini_value(text,"disk_guid"),*esp=ini_value(text,"esp_partuuid"),*size=ini_value(text,"disk_size");
 if(!state||!same(state,"prepared",8)||!disk||!esp||!size){logcode("Prepared-disk record present but not in state=prepared; ignored=",ERROR_INVALID_DATA);return FALSE;}
 BootProfile p={0};ULONGLONG bytes=0;
 for(const char *s=size;*s>='0'&&*s<='9';s++)bytes=bytes*10+(ULONGLONG)(*s-'0');
 if(!parse_guid(disk,&p.disk_id)||!parse_guid(esp,&p.esp_id)||!bytes){logcode("Prepared-disk record unreadable=",ERROR_INVALID_DATA);return FALSE;}
 memcpy(p.magic,"VESP0001",8);p.disk_size=bytes;boot_profile=p;pinned_esp=TRUE;
 logcode("USOS prepared the target disk (micro-Linux): fresh ESP pinned; disk size MiB=",(DWORD)(bytes>>20));
 return TRUE;
}
/* Rename the record so the next Vista start prepares a disk again. */
static void retire_prepared_disk(const WCHAR *suffix){
 if(!prepared_record[0])return;WCHAR to[MAX_PATH];lstrcpyW(to,prepared_record);lstrcatW(to,suffix);
 logcode("Prepared-disk record retired=",MoveFileExW(prepared_record,to,MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)?0:GetLastError());
 prepared_record[0]=0;
}
/* ---- Vista without firmware CSM (CSMWrap, legacy MBR install) ---------- */
static DWORD run_capture(const WCHAR *executable,const WCHAR *arguments,const WCHAR *output_name);
static ULONGLONG parse_decimal(const char *s){ULONGLONG v=0;for(;*s>='0'&&*s<='9';s++)v=v*10+(ULONGLONG)(*s-'0');return v;}
/* usos-vista-target.ini (written by tools/vista_csmwrap_target.sh into this
 * WinPE image): the disk signature and the staging partition's extent. */
static BOOL load_csmwrap_target(void){
 static char text[1024];WCHAR file[MAX_PATH];DWORD got=0;
 path(file,base,L"usos-vista-target.ini");HANDLE h=CreateFileW(file,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);
 if(h==INVALID_HANDLE_VALUE){logcode("CSMWrap: usos-vista-target.ini missing=",GetLastError());return FALSE;}
 BOOL ok=ReadFile(h,text,sizeof(text)-1,&got,0);CloseHandle(h);if(!ok)return FALSE;text[got]=0;
 const char *sig=ini_value(text,"disk_signature"),*start=ini_value(text,"staging_start"),*count=ini_value(text,"staging_sectors");
 if(!sig||!start||!count)return FALSE;
 DWORD v=0;for(int i=0;i<8;i++){char c=sig[i];if(c>='0'&&c<='9')v=v*16+(DWORD)(c-'0');else if((c|32)>='a'&&(c|32)<='f')v=v*16+(DWORD)((c|32)-'a'+10);else return FALSE;}
 csm_signature=v;csm_staging_start=parse_decimal(start);csm_staging_sectors=parse_decimal(count);
 if(!csm_signature||!csm_staging_start||!csm_staging_sectors)return FALSE;
 logcode("CSMWrap: target disk signature=",csm_signature);logcode("CSMWrap: staging partition start LBA (low)=",(DWORD)csm_staging_start);
 return TRUE;
}
/* The one internal MBR disk with that signature. */
static BOOL find_csmwrap_disk(void){
 DWORD found=0;
 for(DWORD disk=0;disk<64;disk++){
  HANDLE h=disk_handle(disk);if(h==INVALID_HANDLE_VALUE)continue;
  DWORD got=0;BOOL ok=internal(h)&&DeviceIoControl(h,IOCTL_DISK_GET_DRIVE_LAYOUT_EX,0,0,buffer,sizeof(buffer),&got,0)&&got>=offsetof(DRIVE_LAYOUT_INFORMATION_EX,PartitionEntry);CloseHandle(h);
  if(!ok)continue;DRIVE_LAYOUT_INFORMATION_EX *layout=(void*)buffer;
  if(layout->PartitionStyle==PARTITION_STYLE_MBR&&layout->Mbr.Signature==csm_signature){csm_disk=disk;found++;}
 }
 logcode("CSMWrap: disks with the prepared MBR signature=",found);
 if(found!=1){csm_disk=0xffffffff;return FALSE;}
 logcode("CSMWrap: target physical disk=",csm_disk);return TRUE;
}
static BOOL mbr_io(BYTE sector[512],BOOL write){
 WCHAR name[40]=L"\\\\.\\PhysicalDrive";decimal(name+lstrlenW(name),csm_disk);
 HANDLE h=CreateFileW(name,GENERIC_READ|(write?GENERIC_WRITE:0),FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_EXISTING,write?FILE_FLAG_WRITE_THROUGH:0,0);
 if(h==INVALID_HANDLE_VALUE)return FALSE;DWORD got=0;BOOL ok;
 if(write){ok=WriteFile(h,sector,512,&got,0)&&got==512&&FlushFileBuffers(h);if(ok)DeviceIoControl(h,IOCTL_DISK_UPDATE_PROPERTIES,0,0,0,0,&got,0);}
 else ok=ReadFile(h,sector,512,&got,0)&&got==512;
 CloseHandle(h);
 return ok&&(write||(sector[510]==0x55&&sector[511]==0xAA&&same(sector+440,&csm_signature,4)));
}
static int staging_slot(const BYTE *s){
 for(int i=0;i<4;i++){const BYTE *e=s+446+16*i;DWORD first,count;memcpy(&first,e+8,4);memcpy(&count,e+12,4);
  if(e[4]==0x07&&first==csm_staging_start&&count==csm_staging_sectors)return i;}
 return -1;
}
enum{STAGING_INACTIVE,STAGING_ACTIVE_IF_ALONE,STAGING_REMOVE};
/* The staging partition's MBR entry: clear its active flag before Setup (Vista
 * then makes its own partition the system partition), set it again after a
 * failed Setup when no other partition is active (the next boot of this disk
 * retries), remove it after a good installation (PE10 ran from RAM). Only the
 * matching entry of this disk's sector 0 is touched; read back. */
static BOOL staging_entry(int action){
 BYTE s[512],check[512];if(!mbr_io(s,FALSE)){logcode("CSMWrap: cannot read the target MBR=",GetLastError());return FALSE;}
 int slot=staging_slot(s);if(slot<0){logcode("CSMWrap: staging partition entry not found=",ERROR_NOT_FOUND);return FALSE;}
 BYTE *e=s+446+16*slot;
 if(action==STAGING_INACTIVE){if(e[0]==0){logcode("CSMWrap: staging partition already inactive=",0);return TRUE;}e[0]=0;}
 else if(action==STAGING_ACTIVE_IF_ALONE){for(int i=0;i<4;i++)if(s[446+16*i]==0x80){logcode("CSMWrap: a partition is active; staging left inactive (slot)=",(DWORD)i);return TRUE;}e[0]=0x80;}
 else memset(e,0,16);
 if(!mbr_io(s,TRUE)||!mbr_io(check,FALSE)||!same(s,check,512)){logcode("CSMWrap: MBR write/readback failed=",GetLastError());return FALSE;}
 logcode(action==STAGING_INACTIVE?"CSMWrap: staging partition marked inactive before Setup (slot)=":action==STAGING_REMOVE?"CSMWrap: staging partition entry removed (slot)=":"CSMWrap: staging partition active again for a retry (slot)=",(DWORD)slot);
 return TRUE;
}
/* A user answer (USOS profile or DATA file, usos-unattend.xml, UTF-8) with
 * the KMDF <servicing> block of the servicing answer inserted right after the
 * <unattend ...> tag. Nothing of the user file is logged. */
static WCHAR servicing_cab[MAX_PATH];
static BOOL merge_user_answer(WCHAR *answer){
 static WCHAR xml[2048];WCHAR user[MAX_PATH],merged[MAX_PATH];path(user,base,L"usos-unattend.xml");
 HANDLE f=CreateFileW(user,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(f==INVALID_HANDLE_VALUE)return TRUE;
 LARGE_INTEGER size;DWORD got=0;BOOL ok=GetFileSizeEx(f,&size)&&size.QuadPart>16&&size.QuadPart<=1024*1024;
 char *text=ok?LocalAlloc(LMEM_FIXED,(SIZE_T)size.QuadPart+1):0;
 ok=text&&ReadFile(f,text,(DWORD)size.QuadPart,&got,0)&&got==size.QuadPart;CloseHandle(f);
 if(!ok){logcode("Answer merge: cannot read usos-unattend.xml=",GetLastError());if(text)LocalFree(text);return FALSE;}
 text[got]=0;
 if((BYTE)text[0]==0xFF||(BYTE)text[0]==0xFE||text[1]==0){logcode("Answer merge: only UTF-8 answer files are supported=",ERROR_INVALID_DATA);LocalFree(text);return FALSE;}
 DWORD at=0,insert=0;BOOL has_servicing=FALSE;
 for(DWORD i=0;i+10<got;i++){if(!insert&&same(text+i,"<unattend",9)&&(text[i+9]==' '||text[i+9]=='>')){for(at=i;at<got&&text[at]!='>';at++){}if(at<got)insert=at+1;}
  if(same(text+i,"<servicing",10))has_servicing=TRUE;}
 if(!insert||has_servicing){logcode(has_servicing?"Answer merge: the answer file has its own servicing section=":"Answer merge: no <unattend> element=",ERROR_INVALID_DATA);LocalFree(text);return FALSE;}
 DWORD chars=vista_kmdf_answer(xml,2048,servicing_cab);DWORD from=0,to=0;
 for(DWORD i=0;i+12<chars;i++){if(!from&&same(xml+i,L"<servicing>",11*sizeof(WCHAR)))from=i;if(same(xml+i,L"</servicing>",12*sizeof(WCHAR)))to=i+12;}
 if(!from||to<=from){LocalFree(text);return FALSE;}
 char block[1600];DWORD n=0;for(DWORD i=from;i<to;i++){if(xml[i]>127||n>=sizeof(block)-2){LocalFree(text);return FALSE;}block[n++]=(char)xml[i];}
 path(merged,base,L"vista-answer.xml");
 HANDLE o=CreateFileW(merged,GENERIC_WRITE,FILE_SHARE_READ,0,CREATE_ALWAYS,FILE_FLAG_WRITE_THROUGH,0);DWORD w1=0,w2=0,w3=0;
 ok=o!=INVALID_HANDLE_VALUE&&WriteFile(o,text,insert,&w1,0)&&w1==insert&&WriteFile(o,block,n,&w2,0)&&w2==n&&WriteFile(o,text+insert,got-insert,&w3,0)&&w3==got-insert&&FlushFileBuffers(o);
 if(o!=INVALID_HANDLE_VALUE)CloseHandle(o);LocalFree(text);
 logcode("Answer merge: user answer + KMDF servicing written (bytes)=",ok?w1+w2+w3:0);
 if(ok)lstrcpyW(answer,merged);return ok;
}
/* After Setup: the active partition of the target disk holds Vista's bootmgr
 * and \Boot\BCD. Check its default entry names the new Windows partition
 * (signature + offset in the device element), then set test signing there. */
static BOOL configure_boot_bios(const Target *t,BOOL *system_is_staging){
 static WCHAR store[MAX_PATH],inspect_store[MAX_PATH],file[MAX_PATH],device[80];
 HANDLE h=disk_handle(t->disk);DWORD got=0;BOOL ok=h!=INVALID_HANDLE_VALUE&&DeviceIoControl(h,IOCTL_DISK_GET_DRIVE_LAYOUT_EX,0,0,buffer,sizeof(buffer),&got,0);
 if(h!=INVALID_HANDLE_VALUE)CloseHandle(h);if(!ok)return FALSE;
 DRIVE_LAYOUT_INFORMATION_EX *layout=(void*)buffer;DWORD number=0,actives=0;ULONGLONG offset=0;
 if(layout->PartitionStyle!=PARTITION_STYLE_MBR)return FALSE;
 for(DWORD i=0;i<layout->PartitionCount&&i<64;i++){PARTITION_INFORMATION_EX *p=&layout->PartitionEntry[i];if(p->PartitionNumber&&p->Mbr.BootIndicator){actives++;number=p->PartitionNumber;offset=(ULONGLONG)p->StartingOffset.QuadPart;}}
 logcode("CSMWrap: active partitions after Setup=",actives);if(actives!=1)return FALSE;
 *system_is_staging=offset==csm_staging_start*512;
 logcode("CSMWrap: system partition is the staging partition (1 = yes)=",*system_is_staging);
 lstrcpyW(device,L"\\Device\\Harddisk");decimal(device+lstrlenW(device),t->disk);lstrcatW(device,L"\\Partition");decimal(device+lstrlenW(device),number);
 DWORD letters=GetLogicalDrives();WCHAR alias[4]={0,L':',0,0};
 for(int i=25;i>=3;i--)if(!(letters&(1u<<i))){alias[0]=L'A'+i;break;}
 if(!alias[0]||!DefineDosDeviceW(DDD_RAW_TARGET_PATH|DDD_NO_BROADCAST_SYSTEM,alias,device))return FALSE;
 alias[2]=L'\\';ok=FALSE;
 path(file,alias,L"bootmgr");path(store,alias,L"Boot\\BCD");
 if(GetFileAttributesW(file)==INVALID_FILE_ATTRIBUTES||GetFileAttributesW(store)==INVALID_FILE_ATTRIBUTES){logcode("CSMWrap: bootmgr or Boot\\BCD missing on the system partition=",GetLastError());goto done;}
 /* The store stays open after Setup (loaded as a registry hive: CopyFile gets
  * a sharing violation and bcdedit cannot /export with /store; QEMU
  * 2026-09-27), so read the default entry through PE10's bcdedit /enum: its
  * device and osdevice must be the new Windows partition (partition=<its PE
  * letter>) and the loader the BIOS winload.exe. */
 path(inspect_store,base,L"vista-bcd-enum.txt");DeleteFileW(inspect_store);
 {WCHAR exe[MAX_PATH],args[MAX_PATH+40];GetSystemDirectoryW(exe,MAX_PATH);lstrcatW(exe,L"\\bcdedit.exe");
  lstrcpyW(args,L"/store \"");lstrcatW(args,store);lstrcatW(args,L"\" /enum {default}");
  DWORD code=run_capture(exe,args,L"vista-bcd-enum.txt");logcode("BCDEdit /enum {default} result=",code);if(code)goto done;}
 {static char text[16384];DWORD got=0;HANDLE f=CreateFileW(inspect_store,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);
  if(f==INVALID_HANDLE_VALUE)goto done;BOOL read=ReadFile(f,text,sizeof(text)-1,&got,0);CloseHandle(f);if(!read)goto done;text[got]=0;
  char want[]="partition=C:";want[10]=(char)t->root[0];DWORD partitions=0;BOOL loader=FALSE;
  for(DWORD i=0;i+12<=got;i++){
   if(same(text+i,want,12)&&(text[i+12]=='\r'||text[i+12]=='\n'||text[i+12]==' '))partitions++;
   if(same(text+i,"winload.exe",11))loader=TRUE;
  }
  logcode("BCD default: entries naming the new partition=",partitions);logcode("BCD default: BIOS winload.exe (1 = yes)=",loader);
  if(partitions<2||!loader){logcode("BCD default does not identify the new Vista partition=",1);goto done;}}
 WCHAR args[100];lstrcpyW(args,L"/set {default} testsigning on");
 ok=bcd_command(store,args);
done:
 alias[2]=0;DefineDosDeviceW(DDD_REMOVE_DEFINITION|DDD_NO_BROADCAST_SYSTEM,alias,0);
 return ok;
}
static BOOL load_boot_profile(void){
 BYTE hash[32];unsigned files=0;
 for(;vista_boot_files[files].name;files++){
  path(scratch,base,vista_boot_files[files].name);
  if(!hash_file(scratch,hash)||!same(hash,vista_boot_files[files].sha256,32)){logcode("Boot profile asset hash mismatch=",files);return FALSE;}
 }
 if(!files)return TRUE;
 if(files!=3)return FALSE;
 path(scratch,base,L"vista-target-esp.bin");HANDLE file=CreateFileW(scratch,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);
 if(file==INVALID_HANDLE_VALUE)return FALSE;
 DWORD got=0;LARGE_INTEGER size;BOOL ok=GetFileSizeEx(file,&size)&&size.QuadPart==sizeof(boot_profile)&&ReadFile(file,&boot_profile,sizeof(boot_profile),&got,0)&&got==sizeof(boot_profile);CloseHandle(file);
 if(!ok||!same(boot_profile.magic,"VESP0001",8))return FALSE;
 WCHAR src[MAX_PATH],dir[MAX_PATH],dst[MAX_PATH];path(dir,base,L"vista-tools");
 if(!CreateDirectoryW(dir,0)&&GetLastError()!=ERROR_ALREADY_EXISTS)return FALSE;
 path(src,base,L"vista-bcdedit.bin");path(vista_bcdedit,dir,L"\\bcdedit.exe");
 if(!CopyFileW(src,vista_bcdedit,FALSE)||!vista_file(vista_bcdedit,FALSE))return FALSE;
 lstrcatW(dir,L"\\pl-PL");if(!CreateDirectoryW(dir,0)&&GetLastError()!=ERROR_ALREADY_EXISTS)return FALSE;
 path(src,base,L"vista-bcdedit-mui.bin");path(dst,dir,L"\\bcdedit.exe.mui");if(!CopyFileW(src,dst,FALSE))return FALSE;
 pinned_esp=TRUE;logcode("Boot profile: exact disk GUID + size; replacement EFI allowed=",0);return TRUE;
}
/* Run a tool in a fresh process and APPEND its output (with the command line)
 * to base\output_name, so every attempt stays in the USB log snapshot.
 * Never invoke this installer on the technician OS (entry requires MiniNT). */
static DWORD run_capture(const WCHAR *executable,const WCHAR *arguments,const WCHAR *output_name){
 WCHAR output_path[MAX_PATH];path(output_path,base,output_name);
 SECURITY_ATTRIBUTES security={sizeof(security),0,TRUE};
 HANDLE output=CreateFileW(output_path,FILE_APPEND_DATA|SYNCHRONIZE,FILE_SHARE_READ|FILE_SHARE_WRITE,&security,OPEN_ALWAYS,FILE_FLAG_WRITE_THROUGH,0);
 HANDLE input=CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&security,OPEN_EXISTING,0,0);
 if(output==INVALID_HANDLE_VALUE||input==INVALID_HANDLE_VALUE){if(output!=INVALID_HANDLE_VALUE)CloseHandle(output);if(input!=INVALID_HANDLE_VALUE)CloseHandle(input);return ERROR_OPEN_FAILED;}
 lstrcpyW(command,L"\"");lstrcatW(command,executable);lstrcatW(command,L"\" ");lstrcatW(command,arguments);
 {char line[600];DWORD n=0,written;line[n++]='>';line[n++]=' ';for(const WCHAR *p=command;*p&&n<596;p++)line[n++]=*p<128?(char)*p:'?';line[n++]='\r';line[n++]='\n';WriteFile(output,line,n,&written,0);}
 STARTUPINFOW si={0};PROCESS_INFORMATION pi={0};si.cb=sizeof(si);si.dwFlags=STARTF_USESTDHANDLES;si.hStdInput=input;si.hStdOutput=output;si.hStdError=output;
 DWORD result=ERROR_GEN_FAILURE;
 if(CreateProcessW(executable,command,0,0,TRUE,CREATE_NO_WINDOW,0,base,&si,&pi)){
  WaitForSingleObject(pi.hProcess,INFINITE);GetExitCodeProcess(pi.hProcess,&result);CloseHandle(pi.hThread);CloseHandle(pi.hProcess);
 }else result=GetLastError();
 FlushFileBuffers(output);CloseHandle(output);CloseHandle(input);return result;
}
static DWORD vista_bcd_command(const WCHAR *arguments,const WCHAR *output_name){return run_capture(vista_bcdedit,arguments,output_name);}
/* Vista's own bcdedit.exe (6.0.x) and its MUI files from the selected ISO's
 * boot.wim, unless a hardware boot profile already supplied them. Vista Setup
 * resolves the system partition through Vista's BCD library, which ignores the
 * hint PE10's bcdedit /sysstore sets (GetSystemDiskNTPath 0xc0000451, X470
 * 2026-09-20/21): with only the PE10 hint it may create a second ESP next to
 * an existing one. Single files are extracted with PE10's wimgapi
 * (WIMExtractImagePath): no mount (a DISM mount fails in the wimboot PE10 with
 * error 1), nothing written outside WinPE RAM, the ISO stays read-only. */
typedef HANDLE (WINAPI *WimCreateFileFn)(PCWSTR,DWORD,DWORD,DWORD,DWORD,PDWORD);
typedef BOOL (WINAPI *WimSetTemporaryPathFn)(HANDLE,PCWSTR);
typedef HANDLE (WINAPI *WimLoadImageFn)(HANDLE,DWORD);
typedef BOOL (WINAPI *WimExtractImagePathFn)(HANDLE,PCWSTR,PCWSTR,DWORD);
typedef BOOL (WINAPI *WimCloseHandleFn)(HANDLE);
static BOOL wim_extract(WimExtractImagePathFn extract,HANDLE image,const WCHAR *inner,const WCHAR *destination){
 DeleteFileW(destination);BOOL ok=extract(image,inner,destination,0);
 logcode(ok?"  WIM file extracted=":"  WIM file not extracted=",ok?0:GetLastError());return ok;
}
/* The UI languages listed in <ISO>\sources\lang.ini ([Available UI Languages],
 * "pl-PL = 3"), ASCII, into names[] (at most 8, each at most 15 chars). */
static DWORD iso_languages(const WCHAR *source,WCHAR names[8][16]){
 static WCHAR ini[MAX_PATH];static char text[4096];path(ini,source,L"\\sources\\lang.ini");
 HANDLE f=CreateFileW(ini,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(f==INVALID_HANDLE_VALUE)return 0;
 DWORD got=0;BOOL ok=ReadFile(f,text,sizeof(text)-1,&got,0);CloseHandle(f);if(!ok)return 0;text[got]=0;
 DWORD count=0;BOOL section=FALSE;
 for(char *line=text;*line&&count<8;){
  char *next=line;while(*next&&*next!='\n')next++;char *end=next;if(*next)next++;
  while(end>line&&(end[-1]=='\r'||end[-1]==' '))end--;
  if(line<end&&*line=='[')section=(end-line)==24&&same(line,"[Available UI Languages]",24);
  else if(section&&line<end){
   DWORD n=0;while(line+n<end&&n<15&&line[n]!=' '&&line[n]!='='&&line[n]>' ')n++;
   if(n>=2){for(DWORD i=0;i<n;i++)names[count][i]=(WCHAR)(BYTE)line[i];names[count][n]=0;count++;}
  }
  line=next;
 }
 return count;
}
static BOOL load_vista_bcdedit(const WCHAR *source){
 if(vista_bcdedit[0]){logcode("Vista BCDEdit: from the boot profile=",0);return TRUE;}
 static WCHAR library[MAX_PATH],wim[MAX_PATH],dir[MAX_PATH],temp[MAX_PATH],inner[MAX_PATH],dst[MAX_PATH],languages[9][16];
 UINT n=GetSystemDirectoryW(library,MAX_PATH);if(!n||n>MAX_PATH-16)return FALSE;lstrcatW(library,L"\\wimgapi.dll");
 HMODULE module=LoadLibraryW(library);if(!module){logcode("Vista BCDEdit: wimgapi.dll missing in WinPE=",GetLastError());return FALSE;}
 WimCreateFileFn create=(WimCreateFileFn)GetProcAddress(module,"WIMCreateFile");
 WimSetTemporaryPathFn set_temp=(WimSetTemporaryPathFn)GetProcAddress(module,"WIMSetTemporaryPath");
 WimLoadImageFn load=(WimLoadImageFn)GetProcAddress(module,"WIMLoadImage");
 WimExtractImagePathFn extract=(WimExtractImagePathFn)GetProcAddress(module,"WIMExtractImagePath");
 WimCloseHandleFn close_wim=(WimCloseHandleFn)GetProcAddress(module,"WIMCloseHandle");
 if(!create||!set_temp||!load||!extract||!close_wim){logcode("Vista BCDEdit: wimgapi exports missing=",ERROR_PROC_NOT_FOUND);return FALSE;}
 path(wim,source,L"\\sources\\boot.wim");path(dir,base,L"vista-tools");path(temp,base,L"vista-wimtemp");
 if((!CreateDirectoryW(dir,0)&&GetLastError()!=ERROR_ALREADY_EXISTS)||(!CreateDirectoryW(temp,0)&&GetLastError()!=ERROR_ALREADY_EXISTS))return FALSE;
 DWORD created=0;HANDLE file=create(wim,GENERIC_READ,OPEN_EXISTING,0,0,&created);
 if(!file){logcode("Vista BCDEdit: cannot open the ISO boot.wim=",GetLastError());return FALSE;}
 BOOL ok=FALSE;DWORD copied=0;HANDLE image=0;
 if(set_temp(file,temp)&&(image=load(file,1))!=0){
  path(vista_bcdedit,dir,L"\\bcdedit.exe");
  ok=wim_extract(extract,image,L"\\Windows\\System32\\bcdedit.exe",vista_bcdedit)&&vista_file(vista_bcdedit,FALSE);
  /* The ISO's UI languages, then en-US; a missing language is not fatal as
   * long as one MUI file arrives. */
  DWORD count=iso_languages(source,languages);lstrcpyW(languages[count++],L"en-US");
  for(DWORD i=0;ok&&i<count;i++){
   BOOL duplicate=FALSE;for(DWORD j=0;j<i;j++)if(lstrcmpiW(languages[i],languages[j])==0)duplicate=TRUE;
   if(duplicate)continue;
   path(dst,dir,L"\\");lstrcatW(dst,languages[i]);if(!CreateDirectoryW(dst,0)&&GetLastError()!=ERROR_ALREADY_EXISTS)continue;
   lstrcatW(dst,L"\\bcdedit.exe.mui");
   lstrcpyW(inner,L"\\Windows\\System32\\");lstrcatW(inner,languages[i]);lstrcatW(inner,L"\\bcdedit.exe.mui");
   if(wim_extract(extract,image,inner,dst))copied++;
  }
 }else logcode("Vista BCDEdit: cannot load boot.wim image 1=",GetLastError());
 if(image)close_wim(image);close_wim(file);
 logcode("Vista BCDEdit: bcdedit.exe 6.0 extracted from the ISO boot.wim=",ok?0:ERROR_FILE_NOT_FOUND);
 logcode("Vista BCDEdit: MUI languages extracted=",copied);
 if(!copied)ok=FALSE;
 if(!ok)vista_bcdedit[0]=0;
 return ok;
}
static BOOL verify_vista_system_store(void){
 WCHAR args[MAX_PATH+32],export_path[MAX_PATH];
 path(export_path,base,L"vista-bcd-system.bin");
 if(!DeleteFileW(export_path)&&GetLastError()!=ERROR_FILE_NOT_FOUND)return FALSE;
 lstrcpyW(args,L"/export \"");lstrcatW(args,export_path);lstrcatW(args,L"\"");
 DWORD code=vista_bcd_command(args,L"vista-bcd-export.txt");logcode("Vista BCDEdit system-store export result=",code);if(code)return FALSE;
 HKEY hive=0;LONG error=RegLoadAppKeyW(export_path,&hive,KEY_READ,REG_PROCESS_APPKEY,0);logcode("Read exported Vista system store=",error);if(error)return FALSE;
 BYTE device[512];DWORD size=sizeof(device);BOOL bound=FALSE;
 if(RegGetValueW(hive,L"Objects\\{9dea862c-5cdd-4e70-acc1-f32b344d4795}\\Elements\\11000001",L"Element",RRF_RT_REG_BINARY,0,device,&size)==ERROR_SUCCESS)
  for(DWORD i=0;i+16<=size;i++)if(same(device+i,&selected_esp.id,16))bound=TRUE;
 RegCloseKey(hive);logcode("Vista system BCD bootmgr matches selected ESP=",bound?0:ERROR_INVALID_DATA);
 return bound;
}
/* Point both system-store hints (PE10's bcdedit for WinPE, Vista's bcdedit for
 * Vista Setup's own BCD library) at one internal ESP through a raw DOS alias.
 * The alias is only a symbolic link: it is defined at once, also on a new,
 * still unformatted ESP, and the volume is never opened here (no
 * GetVolumeInformation, no handle, no FAT32 test). The old guard refused a raw
 * new ESP and kept re-mounting and probing it on every notification while
 * Setup was formatting it; Vista Setup then failed with 0x1F at
 * Callback_PrepareSystemVolume (X470 2026-09-26).
 * Unlike the Windows 10/7 guards the alias must stay defined: Vista's hint is
 * bound to it, and removing it right after /sysstore makes Vista's bcdedit
 * /export fail with ERROR_FILE_INVALID ("the volume for a file has been
 * externally altered", QEMU 2026-09-26). It is replaced when another ESP is
 * selected and removed after Setup. */
static WCHAR store_alias[3],store_device[80];
static void release_store_alias(void){
 if(!store_alias[0])return;
 if(!DefineDosDeviceW(DDD_REMOVE_DEFINITION|DDD_EXACT_MATCH_ON_REMOVE|DDD_RAW_TARGET_PATH|DDD_NO_BROADCAST_SYSTEM,store_alias,store_device))logcode("ESP alias removal failed=",GetLastError());
 store_alias[0]=0;
}
static DWORD point_system_store(const Esp *e){
 release_store_alias();
 lstrcpyW(store_device,L"\\Device\\Harddisk");decimal(store_device+lstrlenW(store_device),e->disk);lstrcatW(store_device,L"\\Partition");decimal(store_device+lstrlenW(store_device),e->number);
 DWORD letters=GetLogicalDrives();WCHAR alias[3]={0,L':',0};
 for(int i=25;i>=3;i--)if(!(letters&(1u<<i))){alias[0]=L'A'+i;break;}
 if(!alias[0])return ERROR_NO_MORE_ITEMS;
 if(!DefineDosDeviceW(DDD_RAW_TARGET_PATH|DDD_NO_BROADCAST_SYSTEM,alias,store_device))return GetLastError();
 lstrcpyW(store_alias,alias);
 /* An ESP that existed before Setup started is not Setup's: mount its file
  * system once (volume query) before the BCD hive is loaded from it. Without
  * this the first access mounts FAT under the freshly loaded system store and
  * every later store operation fails with ERROR_FILE_INVALID (QEMU
  * 2026-09-26; the old guard's FAT32 probe had done this implicitly). A new
  * ESP Setup is creating is never touched. */
 BOOL existing=FALSE;for(DWORD i=0;i<original_esp_count;i++)if(original_esps[i].disk==e->disk&&same(&original_esps[i].id,&e->id,16))existing=TRUE;
 if(existing){WCHAR root[4]={alias[0],L':',L'\\',0};DWORD serial=0;logcode("Existing ESP file system mounted before /sysstore=",GetVolumeInformationW(root,0,0,&serial,0,0,0,0)?0:GetLastError());}
 WCHAR args[32]=L"/sysstore ";lstrcatW(args,alias);
 DWORD pe=bcd_command(0,args)?0:ERROR_GEN_FAILURE;
 DWORD vista=vista_bcd_command(args,L"vista-bcd-sysstore.txt");logcode("Vista BCDEdit sysstore result=",vista);
 return pe?pe:vista;
}
/* Every refresh decision is logged; an identical decision in a row (Setup
 * writes its Panther log often) only increments a counter. */
enum{ESP_INVENTORY_FAILED,ESP_WAITING,ESP_UNCHANGED,ESP_POINTED,ESP_STORE_FAILED,ESP_STORE_GAVE_UP};
typedef struct{DWORD kind,disk,number,count,code;GUID id;}Decision;
static Decision last_decision={0xffffffff};
static DWORD repeated_decisions,store_attempts;
static void decide(DWORD kind,const Esp *e,DWORD count,DWORD code){
 static const char *const text[]={
  "ESP refresh: internal disk inventory failed; no target ESP=",
  "ESP refresh: waiting for a unique target ESP (none, or several new)=",
  "ESP refresh: system store already points at this ESP; nothing opened=",
  "ESP refresh: system stores pointed at the ESP (raw alias, volume not opened)=",
  "ESP refresh: /sysstore failed; retried on the next change=",
  "ESP refresh: /sysstore failed 3 times on this ESP; left to the finalizer check="};
 Decision d={kind,e?e->disk:0,e?e->number:0,count,code};if(e)d.id=e->id;
 if(same(&d,&last_decision,sizeof(d))){repeated_decisions++;return;}
 if(repeated_decisions)logcode("ESP refresh: previous decision repeated (times)=",repeated_decisions);
 repeated_decisions=0;last_decision=d;
 logcode(text[kind],code);logcode("  internal ESPs=",count);
 if(e){logcode("  candidate disk=",e->disk);logcode("  candidate partition=",e->number);}
}
static void refresh_esp(void){
 static Esp current[64];DWORD count=0;
 if(!esp_inventory(current,&count)){store_ready=FALSE;have_selected_esp=FALSE;release_store_alias();store_error=ERROR_READ_FAULT;decide(ESP_INVENTORY_FAILED,0,0,ERROR_READ_FAULT);return;}
 int index=(pinned_esp&&profile_disk_count!=1)?-1:
  (pinned_esp?choose_pinned_esp(&boot_profile,original_esps,original_esp_count,current,count):choose_esp(original_esps,original_esp_count,current,count));
 if(index<0){store_ready=FALSE;have_selected_esp=FALSE;release_store_alias();store_error=ERROR_NOT_FOUND;decide(ESP_WAITING,0,count,ERROR_NOT_FOUND);return;}
 Esp *candidate=&current[index];
 BOOL same_esp=have_selected_esp&&selected_esp.disk==candidate->disk&&same(&selected_esp.id,&candidate->id,16);
 if(same_esp&&store_ready){decide(ESP_UNCHANGED,candidate,count,0);return;}
 if(!same_esp)store_attempts=0;
 /* Never retain a hint to a partition that Setup replaced, and never hint
  * the USB ESP (esp_inventory lists internal disks only). */
 selected_esp=*candidate;have_selected_esp=TRUE;store_ready=FALSE;
 if(store_attempts>=3){decide(ESP_STORE_GAVE_UP,candidate,count,store_error);return;}
 store_attempts++;
 DWORD code=point_system_store(candidate);
 if(code){store_error=code;decide(ESP_STORE_FAILED,candidate,count,code);return;}
 /* A freshly formatted ESP has no BCD yet. Setup creates it; validate the
  * resulting store in configure_boot, never demand it before installation. */
 store_ready=TRUE;store_error=0;decide(ESP_POINTED,candidate,count,0);
 logcode("Selected internal ESP disk=",candidate->disk);logcode("Selected internal ESP partition=",candidate->number);
}
static LRESULT CALLBACK device_window(HWND window,UINT message,WPARAM w,LPARAM l){
 if(message==WM_DEVICECHANGE&&(w==DBT_DEVICEARRIVAL||w==DBT_DEVICEREMOVECOMPLETE||w==DBT_DEVNODES_CHANGED))PostMessageW(window,WM_APP,0,0);
 if(message==WM_APP){refresh_esp();return 0;}
 return DefWindowProcW(window,message,w,l);
}
static DWORD run_setup(const WCHAR *executable,WCHAR *line){
 /* CSMWrap (BIOS mode): no ESP to select; Setup finds the system partition
  * itself (the active partition of the boot disk, or the one it installs to). */
 if(csmwrap){
  STARTUPINFOW si={0};PROCESS_INFORMATION pi={0};si.cb=sizeof(si);DWORD result=ERROR_GEN_FAILURE;
  if(CreateProcessW(executable,line,0,0,FALSE,CREATE_NO_WINDOW,0,base,&si,&pi)){
   CloseHandle(pi.hThread);WaitForSingleObject(pi.hProcess,INFINITE);GetExitCodeProcess(pi.hProcess,&result);CloseHandle(pi.hProcess);
  }else logcode("Create Vista Setup process failed=",GetLastError());
  return result;
 }
 if(!esp_inventory(original_esps,&original_esp_count))return ERROR_READ_FAULT;
 logcode("Initial internal ESP count=",original_esp_count);
 /* Before Setup owns anything: read each existing ESP's boot sector from the
  * raw disk (no volume is opened) and remember whether it holds FAT. */
 for(DWORD i=0;i<original_esp_count;i++){
  Esp *e=&original_esps[i];HANDLE h=disk_handle(e->disk);BYTE sector[512];DWORD got=0;LARGE_INTEGER at;at.QuadPart=(LONGLONG)e->offset;
  if(h!=INVALID_HANDLE_VALUE){
   if(SetFilePointerEx(h,at,0,FILE_BEGIN)&&ReadFile(h,sector,512,&got,0)&&got==512&&sector[510]==0x55&&sector[511]==0xAA&&(same(sector+82,"FAT32",5)||same(sector+54,"FAT",3)))e->formatted=TRUE;
   CloseHandle(h);
  }
  logcode("  existing ESP disk=",e->disk);logcode("  existing ESP partition=",e->number);logcode("  existing ESP has a FAT file system (1 = yes)=",e->formatted);
 }
 refresh_esp();
 /* v10: 0 or several internal ESPs before Setup is normal (a blank disk, or a
  * leftover ESP from an earlier failed run; X470 2026-09-27 refused here with
  * 2 ESPs before the user could delete anything). Setup starts; refresh_esp
  * points the hints at the ESP once exactly one new (or one remaining) exists.
  * Only the hardware boot profile keeps its exact-disk gate. */
 if(!store_ready)logcode("No unique internal ESP yet; Setup starts and the ESP is selected when it appears=",store_error?store_error:ERROR_NOT_FOUND);
 if(pinned_esp&&profile_disk_count!=1){
  logcode("Setup not started: the boot profile disk was not found exactly once=",ERROR_NOT_READY);
  retire_prepared_disk(L".stale");
  MessageBoxW(0,USOS_UI_TEXT(VISTA_ESP_FAILED),USOS_UI_TEXT(VISTA_ESP_TITLE),MB_OK|MB_ICONERROR);
  release_store_alias();return ERROR_NOT_READY;
 }
 /* An existing ESP: record whether Vista's BCD library resolves it (bootmgr
  * device of the exported system store = this ESP). Log only: in QEMU the
  * export fails with ERROR_FILE_INVALID even for a store Vista itself made,
  * while it worked on the X470 (v3, 2026-09-21), so it cannot gate Setup. */
 if(store_ready&&have_selected_esp)logcode("Pre-Setup check (log only): Vista resolves the existing ESP=",verify_vista_system_store()?0:ERROR_INVALID_DATA);
 WNDCLASSW wc={0};wc.lpfnWndProc=device_window;wc.hInstance=GetModuleHandleW(0);wc.lpszClassName=L"USOSVistaESP";
 if(!RegisterClassW(&wc)){DWORD error=GetLastError();release_store_alias();return error;}
 HWND window=CreateWindowExW(0,wc.lpszClassName,L"",0,0,0,0,0,0,0,wc.hInstance,0);if(!window){DWORD error=GetLastError();release_store_alias();return error;}
 DEV_BROADCAST_DEVICEINTERFACE_W filter={0};filter.dbcc_size=sizeof(filter);filter.dbcc_devicetype=DBT_DEVTYP_DEVICEINTERFACE;
 HDEVNOTIFY notification=RegisterDeviceNotificationW(window,&filter,DEVICE_NOTIFY_WINDOW_HANDLE|DEVICE_NOTIFY_ALL_INTERFACE_CLASSES);
 WCHAR panther[MAX_PATH];GetWindowsDirectoryW(panther,MAX_PATH);lstrcatW(panther,L"\\Panther");CreateDirectoryW(panther,0);
 HANDLE changes=FindFirstChangeNotificationW(panther,TRUE,FILE_NOTIFY_CHANGE_FILE_NAME|FILE_NOTIFY_CHANGE_LAST_WRITE);
 if(!notification||changes==INVALID_HANDLE_VALUE){if(notification)UnregisterDeviceNotification(notification);if(changes!=INVALID_HANDLE_VALUE)FindCloseChangeNotification(changes);DestroyWindow(window);release_store_alias();return ERROR_NOT_READY;}
 if(pinned_esp)logcode("Install Vista on this physical disk; deleting all its partitions is supported=",profile_disk_number);
 STARTUPINFOW si={0};PROCESS_INFORMATION pi={0};si.cb=sizeof(si);DWORD result=ERROR_GEN_FAILURE;
 if(CreateProcessW(executable,line,0,0,FALSE,CREATE_NO_WINDOW,0,base,&si,&pi)){
  CloseHandle(pi.hThread);HANDLE waits[2]={pi.hProcess,changes};
  for(;;){
   DWORD event=MsgWaitForMultipleObjects(2,waits,FALSE,INFINITE,QS_ALLINPUT);
   if(event==WAIT_OBJECT_0){GetExitCodeProcess(pi.hProcess,&result);break;}
   if(event==WAIT_OBJECT_0+1){if(!FindNextChangeNotification(changes))break;refresh_esp();}
   else if(event==WAIT_OBJECT_0+2){MSG msg;while(PeekMessageW(&msg,0,0,0,PM_REMOVE)){TranslateMessage(&msg);DispatchMessageW(&msg);}}
   else break;
  }
  /* Do not return into finalization while Setup is still running even if a
   * notification handle failed. */
  WaitForSingleObject(pi.hProcess,INFINITE);GetExitCodeProcess(pi.hProcess,&result);CloseHandle(pi.hProcess);
 }else logcode("Create Vista Setup process failed=",GetLastError());
 FindCloseChangeNotification(changes);UnregisterDeviceNotification(notification);DestroyWindow(window);
 /* Consume final partition changes even if Setup exits before notification
  * dispatch. No timed polling, and no stale pre-deletion ESP at finalization. */
 refresh_esp();release_store_alias();
 if(repeated_decisions)logcode("ESP refresh: previous decision repeated (times)=",repeated_decisions);
 return result;
}
static BOOL mkdirs(WCHAR *file){
 for(DWORD i=3;file[i];i++)if(file[i]==L'\\'){
  file[i]=0;BOOL ok=CreateDirectoryW(file,0)||GetLastError()==ERROR_ALREADY_EXISTS;
  DWORD attr=GetFileAttributesW(file);file[i]=L'\\';
  if(!ok||attr==INVALID_FILE_ATTRIBUTES||(attr&FILE_ATTRIBUTE_REPARSE_POINT)||!(attr&FILE_ATTRIBUTE_DIRECTORY))return FALSE;
 }return TRUE;
}
static BOOL copy_payload(const Target *t){
 WCHAR src[MAX_PATH],dst[MAX_PATH];BYTE digest[32];
 path(dst,t->root,L"USOS\\Vista\\kmdf-install-attempted.flag");
 if(GetFileAttributesW(dst)!=INVALID_FILE_ATTRIBUTES){logcode("Old servicing marker exists; format the chosen Windows partition in Setup=",1);return FALSE;}
 for(unsigned i=0;i<sizeof(vista_files)/sizeof(vista_files[0]);i++){
  path(src,base,vista_files[i].source);path(dst,t->root,vista_files[i].target);
  if(!mkdirs(dst)||!CopyFileW(src,dst,FALSE)||!hash_file(dst,digest)||!same(digest,vista_files[i].sha256,32))return FALSE;
  HANDLE f=CreateFileW(dst,GENERIC_WRITE,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(f==INVALID_HANDLE_VALUE)return FALSE;
  BOOL ok=FlushFileBuffers(f);CloseHandle(f);if(!ok)return FALSE;
 }return TRUE;
}
static BOOL prepare_servicing_answer(WCHAR *answer){
 static WCHAR xml[2048],cab[MAX_PATH],source[MAX_PATH];BYTE digest[32];
 unsigned i;for(i=0;i<sizeof(vista_files)/sizeof(vista_files[0]);i++)
  if(lstrcmpiW(vista_files[i].target,L"USOS\\Vista\\Updates\\Windows6.0-KB2864202-x64.cab")==0)break;
 if(i==sizeof(vista_files)/sizeof(vista_files[0]))return FALSE;
 path(source,base,vista_files[i].source);path(cab,base,L"Windows6.0-KB2864202-x64.cab");
 if(!CopyFileW(source,cab,FALSE)||!hash_file(cab,digest)||!same(digest,vista_files[i].sha256,32))return FALSE;
 lstrcpyW(servicing_cab,cab);
 DWORD chars=vista_kmdf_answer(xml,2048,cab);if(!chars)return FALSE;
 path(answer,base,L"vista-servicing.xml");
 HANDLE file=CreateFileW(answer,GENERIC_WRITE,FILE_SHARE_READ,0,CREATE_ALWAYS,FILE_FLAG_WRITE_THROUGH,0);if(file==INVALID_HANDLE_VALUE)return FALSE;
 DWORD written=0;BOOL ok=WriteFile(file,xml,chars*sizeof(WCHAR),&written,0)&&written==chars*sizeof(WCHAR)&&FlushFileBuffers(file);CloseHandle(file);
 logcode("KMDF package supplied to Vista Setup offline servicing=",ok?0:ERROR_WRITE_FAULT);return ok;
}
static BOOL verify_offline_kmdf(const WCHAR *root){
 static const WCHAR *files[]={L"Windows\\System32\\drivers\\Wdf01000.sys",L"Windows\\System32\\drivers\\WdfLdr.sys"};
 static WCHAR file[MAX_PATH];
 for(DWORD i=0;i<2;i++){
  if(lstrlenW(root)+lstrlenW(files[i])>=MAX_PATH)return FALSE;
  path(file,root,files[i]);DWORD unused=0,bytes=GetFileVersionInfoSizeW(file,&unused);VS_FIXEDFILEINFO *v=0;UINT size=0;
  if(!bytes||bytes>sizeof(buffer)||!GetFileVersionInfoW(file,0,bytes,buffer)||!VerQueryValueW(buffer,L"\\",(void**)&v,&size)||size<sizeof(*v))return FALSE;
  logcode(i?"Offline WdfLdr major/minor=":"Offline Wdf01000 major/minor=",v->dwFileVersionMS);
  if(v->dwFileVersionMS!=0x0001000b)return FALSE;
 }
 return TRUE;
}
static BOOL get_string(HKEY hive,const WCHAR *key,const WCHAR *name,WCHAR *value,DWORD chars){DWORD bytes=chars*sizeof(WCHAR);return RegGetValueW(hive,key,name,RRF_RT_REG_SZ|RRF_RT_REG_EXPAND_SZ|RRF_NOEXPAND,0,value,&bytes)==ERROR_SUCCESS;}
static BOOL read_hive(const WCHAR *file,VistaHive *h){
 HANDLE f=CreateFileW(file,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(f==INVALID_HANDLE_VALUE)return FALSE;
 LARGE_INTEGER size;DWORD got;BOOL ok=GetFileSizeEx(f,&size)&&size.QuadPart>=4096&&size.QuadPart<=128*1024*1024;
 BYTE *bytes=ok?LocalAlloc(LMEM_FIXED,(SIZE_T)size.QuadPart):0;
 ok=bytes&&ReadFile(f,bytes,(DWORD)size.QuadPart,&got,0)&&got==size.QuadPart&&vh_open(h,bytes,got);
 CloseHandle(f);if(!ok&&bytes)LocalFree(bytes);return ok;
}
static BOOL arm_target(const Target *t){
 WCHAR file[MAX_PATH],saved[MAX_PATH],runtime[MAX_PATH],programs[MAX_PATH];VistaHive software,system;BOOL ok=FALSE;
 path(file,t->root,L"Windows\\System32\\config\\SOFTWARE");
 if(!read_hive(file,&software)){logcode("Target SOFTWARE is unreadable, dirty or invalid=",ERROR_BADDB);return FALSE;}
 ok=vh_string(&software,"Microsoft\\Windows NT\\CurrentVersion","SystemRoot",runtime,MAX_PATH)&&
    vh_string(&software,"Microsoft\\Windows\\CurrentVersion","ProgramFilesDir",programs,MAX_PATH)&&
    runtime[0]>=L'C'&&runtime[0]<=L'Z'&&lstrcmpiW(runtime+1,L":\\Windows")==0&&programs[0]==runtime[0]&&programs[1]==L':';
 LocalFree(software.p);if(!ok){logcode("Target Windows/ProgramFiles drive mapping disagrees=",1);return FALSE;}ok=FALSE;
 path(file,t->root,L"Windows\\System32\\config\\SYSTEM");path(saved,t->root,L"USOS\\Vista\\SYSTEM.before-usb");
 if(!read_hive(file,&system)){logcode("Target SYSTEM is unreadable, dirty or invalid=",ERROR_BADDB);return FALSE;}
 uint32_t active=0,phase=0,child=0,type=0;
 if(!vh_dword(&system,"Setup","SystemSetupInProgress",&active)||active!=1||
    !vh_dword(&system,"Setup","SetupPhase",&phase)||phase!=4||
    !vh_dword(&system,"Setup\\Status\\ChildCompletion","setup.exe",&child)||child!=0||
    !vh_dword(&system,"Setup","SetupType",&type)||(type!=0&&type!=2)){logcode("Unexpected fresh Setup state; no boot hook changed=",1);logcode("SystemSetupInProgress=",active);logcode("SetupPhase=",phase);logcode("ChildCompletion=",child);goto done;}
 BYTE identity_bytes[24];uint32_t size=0;char name[]="\\DosDevices\\C:";name[12]=(char)runtime[0];
 memcpy(identity_bytes,"DMIO:ID:",8);memcpy(identity_bytes+8,&t->id,16);
 /* MBR (CSMWrap): the value is the disk signature + partition offset. */
 uint32_t want=24;if(csmwrap){memcpy(identity_bytes,&t->id,12);want=12;}
 BYTE *mapping=vh_data(&system,vh_value(&system,"MountedDevices",name),3,&size);
 if(!mapping||size!=want||!same(mapping,identity_bytes,want)){
  logcode("Setup drive letter is not mapped to the identified partition=",1);goto done;
 }
 WCHAR old[MAX_PATH],launch[]=L"D:\\USOS\\oobe.exe";launch[0]=runtime[0];
 if(!vh_string(&system,"Setup","CmdLine",old,MAX_PATH)||lstrcmpiW(old,L"oobe\\windeploy.exe")!=0)goto done;
 if(!vh_set_string(&system,"Setup","CmdLine",launch)||!vh_set_dword(&system,"Setup","SetupType",2))goto done;
 vh_seal(&system);
 BYTE hash[32];if(!hash_file(file,hash)||!same(hash,t->hash,32)||!CopyFileW(file,saved,TRUE))goto done;
 WCHAR temporary[MAX_PATH];path(temporary,t->root,L"Windows\\System32\\config\\SYSTEM.usos-new");
 HANDLE output=CreateFileW(temporary,GENERIC_WRITE,0,0,CREATE_NEW,FILE_FLAG_WRITE_THROUGH,0);DWORD written=0;
 if(output==INVALID_HANDLE_VALUE)goto done;
 ok=WriteFile(output,system.p,system.size,&written,0)&&written==system.size&&FlushFileBuffers(output);CloseHandle(output);
 if(ok)ok=MoveFileExW(temporary,file,MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH);
 if(ok){VistaHive verify;ok=read_hive(file,&verify);if(ok){ok=verify.size==system.size&&same(verify.p,system.p,system.size);LocalFree(verify.p);}}
 if(!ok){CopyFileW(saved,file,FALSE);logcode("SYSTEM write/readback failed; attempted restoration from backup=",1);}
done:
 LocalFree(system.p);
 return ok;
}
/* The Windows 7 Int10 dispatcher publisher (windows7_uefi_publish.h), shared:
 * with usos-int10-dispatcher.flag the target ESP gets win7-wrapper.efi as
 * bootmgfw.efi and bootx64.efi, UefiSeven as win7.efi and the Vista boot
 * manager Setup wrote as win7.original.efi (docs/design/win7-vista-no-csm.md 7).
 * The shims below give the header the names it uses. */
static WCHAR a[MAX_PATH],b[MAX_PATH],chosen[MAX_PATH];
static unsigned len(const WCHAR *p){return (unsigned)lstrlenW(p);}
static void copy(WCHAR *p,const WCHAR *q){lstrcpyW(p,q);}
static int say(const char *p){logcode(p,0);return 1;}
static int same_file(const WCHAR *p,const WCHAR *q){BYTE x[32],y[32];return hash_file(p,x)&&hash_file(q,y)&&same(x,y,32);}
#include "windows7_uefi_publish.h"
static BOOL install_int10_dispatcher(const WCHAR *esp,const WCHAR *loader){
 static WCHAR flag[MAX_PATH],original[MAX_PATH];
 path(flag,base,L"usos-int10-dispatcher.flag");
 if(GetFileAttributesW(flag)==INVALID_FILE_ATTRIBUTES)return TRUE;
 /* The dispatcher only needs the file names; the loader stays the one Setup
  * wrote (6.0.6001/6002, checked by vista_file before). */
 path(original,base,L"win7.original.efi");
 if(!CopyFileW(loader,original,FALSE)||!same_file(loader,original)){logcode("Int10 dispatcher: cannot stage the Vista boot manager=",GetLastError());return FALSE;}
 lstrcpyW(chosen,esp);
 if(publish_loaders()){logcode("Int10 dispatcher: publication failed; the Vista boot manager stays in place=",1);return FALSE;}
 logcode("Int10 dispatcher installed on the target ESP (CSM on: pass-through; CSM off: experimental)=",0);
 return TRUE;
}
/* Optional, after the target is armed for USB: never fails the installation
 * (X470 2026-09-27: a failed publication before arm_target left USB unarmed).
 * On failure the Vista boot manager stays on both entries (right for CSM on). */
static void install_optional_dispatcher(const Target *t){
 static WCHAR flag[MAX_PATH],loader[MAX_PATH];WCHAR alias[4]={0};
 path(flag,base,L"usos-int10-dispatcher.flag");if(GetFileAttributesW(flag)==INVALID_FILE_ATTRIBUTES)return;
 if(!mount_esp(t->disk,alias)){logcode("Int10 dispatcher skipped: target ESP not mounted; the Vista boot manager stays=",ERROR_NOT_FOUND);return;}
 path(loader,alias,L"EFI\\Microsoft\\Boot\\bootmgfw.efi");
 if(!install_int10_dispatcher(alias,loader))logcode("Int10 dispatcher not installed (not fatal); the Vista boot manager stays on both entries=",1);
 unmount_esp(alias);
}
static BOOL configure_boot(const Target *t){
 /* Single-threaded finalizer; keep path buffers off the no-CRT stack. */
 static WCHAR store[MAX_PATH],loader[MAX_PATH],inspect_store[MAX_PATH],fallback[MAX_PATH],backup[MAX_PATH];
 WCHAR alias[4]={0};BOOL ok=FALSE;
 if(!mount_esp(t->disk,alias))return FALSE;
 path(loader,alias,L"EFI\\Microsoft\\Boot\\bootmgfw.efi");path(store,alias,L"EFI\\Microsoft\\Boot\\BCD");
 // Original Vista SP2 media legitimately carries the 6001 EFI loader.
 if(!vista_file(loader,FALSE)){logcode("Setup did not install a Vista EFI loader=",1);goto done;}
 /* Read the store and require its default OS device to contain this GPT
  * partition identity before changing only that entry's test-signing option. */
 // Setup/the Configuration Manager may still hold the live BCD open for
 // writing. CopyFile rejects that sharing mode (ERROR_SHARING_VIOLATION).
 // Export a coherent system-store snapshot through BCD instead of reading
 // the live hive file. Rebind and verify the selected ESP before inspection.
 path(inspect_store,base,L"vista-bcd-inspect.bin");
 WCHAR selection[32]=L"/sysstore ";alias[2]=0;lstrcatW(selection,alias);alias[2]=L'\\';
 if(!bcd_command(0,selection))goto done;
 /* Vista's own bcdedit is always present (boot profile or the ISO's boot.wim):
  * read the store Vista Setup wrote through Vista's BCD library. */
 {
  DWORD code=vista_bcd_command(selection,L"vista-bcd-sysstore.txt");logcode("Finalizer Vista BCDEdit sysstore result=",code);
  if(code||!verify_vista_system_store())goto done;
  path(inspect_store,base,L"vista-bcd-system.bin");
 }
 HKEY bcd=0;LONG load=RegLoadAppKeyW(inspect_store,&bcd,KEY_READ,REG_PROCESS_APPKEY,0);logcode("Read target BCD=",load);if(load!=ERROR_SUCCESS)goto done;
 DWORD size;BYTE element[512];WCHAR object[140],guid[40];
 if(!get_string(bcd,L"Objects\\{9dea862c-5cdd-4e70-acc1-f32b344d4795}\\Elements\\23000003",L"Element",guid,40)||lstrlenW(guid)!=38||guid[0]!=L'{'||guid[37]!=L'}'){RegCloseKey(bcd);goto done;}
 for(unsigned i=1;i<37;i++){
  WCHAR c=guid[i];BOOL valid=(i==9||i==14||i==19||i==24)?c==L'-':((c>=L'0'&&c<=L'9')||(c>=L'a'&&c<=L'f')||(c>=L'A'&&c<=L'F'));
  if(!valid){RegCloseKey(bcd);goto done;}
 }
 lstrcpyW(object,L"Objects\\");lstrcatW(object,guid);lstrcatW(object,L"\\Elements\\21000001");size=sizeof(element);
 BOOL bound=FALSE;if(RegGetValueW(bcd,object,L"Element",RRF_RT_REG_BINARY,0,element,&size)==ERROR_SUCCESS)
  for(DWORD i=0;i+16<=size;i++)if(same(element+i,&t->id,16))bound=TRUE;
 RegCloseKey(bcd);if(!bound){logcode("BCD default does not identify the new Vista partition=",1);goto done;}
 WCHAR args[100];lstrcpyW(args,L"/set ");lstrcatW(args,guid);lstrcatW(args,L" testsigning on");
 if(!bcd_command(store,args))goto done;
 // Publish the target disk's fallback entry as well; never write the USB ESP.
 BYTE expected[32],actual[32];
 path(fallback,alias,L"EFI\\Boot\\bootx64.efi");path(backup,t->root,L"USOS\\Vista\\bootx64.before-vista");
 if(GetFileAttributesW(fallback)!=INVALID_FILE_ATTRIBUTES&&!CopyFileW(fallback,backup,TRUE))goto done;
 if(!mkdirs(fallback)||!hash_file(loader,expected)||!CopyFileW(loader,fallback,FALSE)||!hash_file(fallback,actual)||!same(expected,actual,32))goto done;
 HANDLE output=CreateFileW(fallback,GENERIC_WRITE,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);
 if(output==INVALID_HANDLE_VALUE)goto done;ok=FlushFileBuffers(output);CloseHandle(output);
 // Both entries now hold the Vista boot manager. The optional Int10 dispatcher
 // is published later (install_optional_dispatcher), after the USB arming.
done:unmount_esp(alias);return ok;
}
void entry(void){
 HKEY mini;OSVERSIONINFOW version={sizeof(version)};FIRMWARE_TYPE firmware;
 if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SYSTEM\\CurrentControlSet\\Control\\MiniNT",0,KEY_READ,&mini)!=ERROR_SUCCESS)ExitProcess(2);RegCloseKey(mini);
 typedef LONG (WINAPI *VersionFn)(OSVERSIONINFOW*);
 VersionFn real_version=(VersionFn)GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"RtlGetVersion");
 if(!real_version||real_version(&version)!=0||version.dwMajorVersion!=10||version.dwBuildNumber<10240||version.dwBuildNumber>=22000||!GetFirmwareType(&firmware))ExitProcess(2);
 DWORD n=GetModuleFileNameW(0,base,MAX_PATH);if(!n||n>=MAX_PATH-64)ExitProcess(2);while(n&&base[n-1]!=L'\\')n--;base[n]=0;
 /* UEFI as before; BIOS only for the CSMWrap preparation (its flag is in this image). */
 path(scratch,base,L"usos-vista-csmwrap.flag");csmwrap=GetFileAttributesW(scratch)!=INVALID_FILE_ATTRIBUTES;
 if(firmware!=(csmwrap?FirmwareTypeBios:FirmwareTypeUefi))ExitProcess(2);
 path(scratch,base,L"usos-vista-install.log");log_file=CreateFileW(scratch,GENERIC_WRITE,FILE_SHARE_READ,0,CREATE_ALWAYS,FILE_FLAG_WRITE_THROUGH,0);
 logcode("Vista USB installer v12 / USB armed before the optional dispatcher / disk preparation opt-in / no pre-Setup ESP gate / formatted ESP preferred / Vista bcdedit from the ISO boot.wim / ESP hints without volume access / known firstboot v11 / CSMWrap legacy MBR mode v1=",0);
 logcode("Firmware type (1 = BIOS, 2 = UEFI)=",firmware);
 if(csmwrap)logcode("CSMWrap mode: PE10 booted in BIOS mode from the prepared disk; Vista installs as a legacy MBR system=",0);
 WCHAR source[MAX_PATH];n=GetEnvironmentVariableW(L"USOS_SOURCE",source,MAX_PATH);
 if(n!=2||source[1]!=L':'||source[0]<L'C'||source[0]>L'Z')ExitProcess(2);
 WCHAR setup_path[MAX_PATH];path(setup_path,source,L"\\sources\\setup.exe");
 if(!vista_file(setup_path,TRUE)){logcode("Expected original Vista SP2 x64 Setup=",1);ExitProcess(3);}
 BYTE hash[32];for(unsigned i=0;i<sizeof(vista_files)/sizeof(vista_files[0]);i++){
  path(scratch,base,vista_files[i].source);if(!hash_file(scratch,hash)||!same(hash,vista_files[i].sha256,32)){logcode("Preflight payload hash failed at file=",i);ExitProcess(3);}
 }
 if(csmwrap&&(!load_csmwrap_target()||!find_csmwrap_disk())){logcode("Setup not started: the prepared CSMWrap disk was not found exactly once=",ERROR_NOT_FOUND);ExitProcess(4);}
 if(!privilege(L"SeBackupPrivilege")||!privilege(L"SeRestorePrivilege")||(!csmwrap&&!load_boot_profile())||!inventory(before,&before_count))ExitProcess(4);
 if(!pinned_esp&&!csmwrap)load_prepared_disk();
 /* Vista's own bcdedit serves the UEFI system-store hints only. */
 if(!csmwrap&&!load_vista_bcdedit(source)){
  logcode("Setup not started: Vista's own bcdedit could not be taken from the ISO boot.wim=",ERROR_FILE_NOT_FOUND);
  MessageBoxW(0,USOS_UI_TEXT(VISTA_ESP_FAILED),USOS_UI_TEXT(VISTA_ESP_TITLE),MB_OK|MB_ICONERROR);
  ExitProcess(4);
 }
 static WCHAR servicing_answer[MAX_PATH];if(!prepare_servicing_answer(servicing_answer))ExitProcess(10);
 if(csmwrap&&!merge_user_answer(servicing_answer)){logcode("Setup not started: the answer file could not be merged with the servicing answer=",ERROR_INVALID_DATA);ExitProcess(11);}
 if(csmwrap&&!staging_entry(STAGING_INACTIVE)){logcode("Setup not started: the staging partition could not be marked inactive=",ERROR_WRITE_FAULT);ExitProcess(12);}
 lstrcpyW(command,L"\"");lstrcatW(command,setup_path);lstrcatW(command,L"\" /noreboot /installfrom:\"");lstrcatW(command,source);lstrcatW(command,L"\\sources\\install.wim\"");
 lstrcatW(command,L" /unattend:\"");lstrcatW(command,servicing_answer);lstrcatW(command,L"\"");
 /* refresh_esp uses the command buffer too, so give Setup its own command. */
 static WCHAR setup_command[2048];lstrcpyW(setup_command,command);
 DWORD result=run_setup(setup_path,setup_command);logcode("Vista Setup returned=",result);
 if(result&&csmwrap)staging_entry(STAGING_ACTIVE_IF_ALONE);
 if(result&&result!=ERROR_CANCELLED&&!store_ready)logcode("Setup failed and no unique target ESP was ever selected (delete all partitions of the target disk, or leave exactly one ESP)=",store_error?store_error:ERROR_NOT_FOUND);usos_record_setup_result(result);if(result)ExitProcess(result);
 if(!inventory(after,&after_count))ExitProcess(5);
 Target *target=0;DWORD candidates=0;
 for(DWORD i=0;i<after_count;i++){
  BOOL unchanged=FALSE;for(DWORD j=0;j<before_count;j++)if(same(&after[i].id,&before[j].id,sizeof(GUID))&&same(after[i].hash,before[j].hash,32))unchanged=TRUE;
  if(!unchanged){target=&after[i];candidates++;}
 }
 logcode("Changed internal Vista targets=",candidates);if(candidates!=1)ExitProcess(5);
 logcode("Target physical disk number=",target->disk);logcode("Target PE drive letter (ASCII)=",target->root[0]);
 Target current;if(!identity(target->root,&current)||current.disk!=target->disk||!same(&current.id,&target->id,16))ExitProcess(5);
 if(pinned_esp&&(!store_ready||!have_selected_esp||target->disk!=selected_esp.disk)){logcode("Setup target differs from verified EFI target=",ERROR_INVALID_DATA);ExitProcess(5);}
 if(!verify_offline_kmdf(target->root)){
  logcode("STOP: KMDF 1.11 not applied offline; USB firstboot has NOT been armed=",ERROR_NOT_READY);
  MessageBoxW(0,USOS_UI_TEXT(VISTA_KMDF_FAILED),USOS_UI_TEXT(VISTA_KMDF_TITLE),MB_OK|MB_ICONERROR);
  ExitProcess(10);
 }
 if(!copy_payload(target)){logcode("Copy target USB package failed=",GetLastError());ExitProcess(6);}
 BOOL system_is_staging=FALSE;
 if(csmwrap?!configure_boot_bios(target,&system_is_staging):!configure_boot(target)){logcode("Target BCD preparation failed (see the lines above)=",ERROR_GEN_FAILURE);ExitProcess(7);}
 if(!arm_target(target)){logcode("Arm pre-Setup USB failed=",GetLastError());ExitProcess(8);}
 install_optional_dispatcher(target);
 /* PE10 runs from RAM: the staging partition is not needed any more unless
  * Setup made it the system partition. Not fatal. */
 if(csmwrap&&!system_is_staging&&!staging_entry(STAGING_REMOVE))logcode("CSMWrap: staging partition kept (not fatal)=",1);
 logcode("Vista target ready for first boot with USB v11=",0);
 retire_prepared_disk(L".done");
 CloseHandle(log_file);path(scratch,base,L"usos-vista-install.log");WCHAR target_log[MAX_PATH];path(target_log,target->root,L"USOS\\Vista\\installation-from-usb.log");
 if(!CopyFileW(scratch,target_log,FALSE))ExitProcess(9);
 /* The firmware may list the USOS stick first: say how the disk continues. */
 if(csmwrap)MessageBoxW(0,USOS_UI_TEXT(VISTA_CSMWRAP_DONE),USOS_UI_TEXT(VISTA_CSMWRAP_TITLE),MB_OK|MB_ICONINFORMATION);
 ExitProcess(0);
}
