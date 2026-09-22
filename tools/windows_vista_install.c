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

static WCHAR base[MAX_PATH], scratch[MAX_PATH], command[2048];
static BYTE buffer[65536];
static HANDLE log_file=INVALID_HANDLE_VALUE;
typedef struct { WCHAR root[4]; DWORD disk; GUID id; BYTE hash[32]; } Target;
static Target before[26],after[26];
static DWORD before_count,after_count;
typedef struct { DWORD disk,number; GUID id,disk_id; ULONGLONG disk_size; } Esp;
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
static WCHAR selected_alias[4];
static DWORD selected_serial;
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
 if(ok)ok=DeviceIoControl(h,IOCTL_DISK_GET_PARTITION_INFO_EX,0,0,&p,sizeof(p),&got,0)&&p.PartitionStyle==PARTITION_STYLE_GPT;
 CloseHandle(h);if(!ok)return FALSE;
 h=disk_handle(e.Extents[0].DiskNumber);if(h==INVALID_HANDLE_VALUE)return FALSE;ok=internal(h);CloseHandle(h);
 if(!ok)return FALSE;lstrcpyW(t->root,root);t->disk=e.Extents[0].DiskNumber;t->id=p.Gpt.PartitionId;return TRUE;
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
   if(*count==64)return FALSE;Esp *e=&esps[(*count)++];e->disk=disk;e->number=p->PartitionNumber;e->id=p->Gpt.PartitionId;e->disk_id=layout->Gpt.DiskId;e->disk_size=length.Length.QuadPart;
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
/* Run the Vista tool in a fresh process, retaining the diagnostic output.
 * Never invoke this installer on the technician OS (entry requires MiniNT). */
static DWORD vista_bcd_command(const WCHAR *arguments,const WCHAR *output_name){
 WCHAR output_path[MAX_PATH];path(output_path,base,output_name);
 SECURITY_ATTRIBUTES security={sizeof(security),0,TRUE};
 HANDLE output=CreateFileW(output_path,GENERIC_WRITE,FILE_SHARE_READ,&security,CREATE_ALWAYS,FILE_FLAG_WRITE_THROUGH,0);
 HANDLE input=CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&security,OPEN_EXISTING,0,0);
 if(output==INVALID_HANDLE_VALUE||input==INVALID_HANDLE_VALUE){if(output!=INVALID_HANDLE_VALUE)CloseHandle(output);if(input!=INVALID_HANDLE_VALUE)CloseHandle(input);return ERROR_OPEN_FAILED;}
 STARTUPINFOW si={0};PROCESS_INFORMATION pi={0};si.cb=sizeof(si);si.dwFlags=STARTF_USESTDHANDLES;si.hStdInput=input;si.hStdOutput=output;si.hStdError=output;
 lstrcpyW(command,L"\"");lstrcatW(command,vista_bcdedit);lstrcatW(command,L"\" ");lstrcatW(command,arguments);
 DWORD result=ERROR_GEN_FAILURE;
 if(CreateProcessW(vista_bcdedit,command,0,0,TRUE,CREATE_NO_WINDOW,0,base,&si,&pi)){
  WaitForSingleObject(pi.hProcess,INFINITE);GetExitCodeProcess(pi.hProcess,&result);CloseHandle(pi.hThread);CloseHandle(pi.hProcess);
 }else result=GetLastError();
 FlushFileBuffers(output);CloseHandle(output);CloseHandle(input);return result;
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
static void refresh_esp(void){
 static Esp current[64];DWORD count=0;
 BOOL inventoried=esp_inventory(current,&count);
 int index=!inventoried||(pinned_esp&&profile_disk_count!=1)?-1:
  (pinned_esp?choose_pinned_esp(&boot_profile,original_esps,original_esp_count,current,count):choose_esp(original_esps,original_esp_count,current,count));
 if(index<0){store_ready=FALSE;have_selected_esp=FALSE;unmount_esp(selected_alias);if(store_error!=ERROR_NOT_FOUND)logcode("Waiting for a unique EFI on the selected internal disk=",ERROR_NOT_FOUND);store_error=ERROR_NOT_FOUND;return;}
 Esp *candidate=&current[index];
 if(store_ready&&have_selected_esp&&selected_esp.disk==candidate->disk&&same(&selected_esp.id,&candidate->id,16)){
  DWORD serial=0;if(GetVolumeInformationW(selected_alias,0,0,&serial,0,0,0,0)&&serial==selected_serial)return;
 }
 /* Keep the alias for the complete Setup process lifetime. Never retain a
  * hint to a partition that Setup replaced, and never hint the USB ESP. */
 store_ready=FALSE;unmount_esp(selected_alias);selected_esp=*candidate;have_selected_esp=TRUE;
 if(!mount_esp(candidate->disk,selected_alias)){have_selected_esp=FALSE;return;}
 WCHAR fs[32];
 if(!GetVolumeInformationW(selected_alias,0,0,&selected_serial,0,0,fs,32)||lstrcmpiW(fs,L"FAT32")!=0){unmount_esp(selected_alias);have_selected_esp=FALSE;return;}
 WCHAR args[32]=L"/sysstore ";selected_alias[2]=0;lstrcatW(args,selected_alias);selected_alias[2]=L'\\';
 if(!bcd_command(0,args)){store_error=ERROR_GEN_FAILURE;unmount_esp(selected_alias);return;}
 if(pinned_esp){
  DWORD code=vista_bcd_command(args,L"vista-bcd-sysstore.txt");logcode("Vista BCDEdit sysstore result=",code);
  if(code){store_error=code;return;}
 }
 /* A freshly formatted ESP has no BCD yet. Setup creates it; validate the
  * resulting store in configure_boot, never demand it before installation. */
 store_ready=TRUE;store_error=0;
 logcode("Selected internal ESP disk=",candidate->disk);logcode("Selected internal ESP partition=",candidate->number);
}
static LRESULT CALLBACK device_window(HWND window,UINT message,WPARAM w,LPARAM l){
 if(message==WM_DEVICECHANGE&&(w==DBT_DEVICEARRIVAL||w==DBT_DEVICEREMOVECOMPLETE||w==DBT_DEVNODES_CHANGED))PostMessageW(window,WM_APP,0,0);
 if(message==WM_APP){refresh_esp();return 0;}
 return DefWindowProcW(window,message,w,l);
}
static DWORD run_setup(const WCHAR *executable,WCHAR *line){
 if(!esp_inventory(original_esps,&original_esp_count))return ERROR_READ_FAULT;
 logcode("Initial internal ESP count=",original_esp_count);
 refresh_esp();
 if((pinned_esp&&profile_disk_count!=1)||(!store_ready&&have_selected_esp)||(!pinned_esp&&!store_ready&&original_esp_count>1)){
  logcode("Setup not started: target EFI selection could not be verified=",store_error?store_error:ERROR_NOT_READY);
  MessageBoxW(0,L"Nie mozna potwierdzic partycji startowej Visty. Instalacja nie zostala uruchomiona. Logi BCD zostana zapisane na pendrivie.",L"USOS - Vista UEFI",MB_OK|MB_ICONERROR);
  unmount_esp(selected_alias);return ERROR_NOT_READY;
 }
 WNDCLASSW wc={0};wc.lpfnWndProc=device_window;wc.hInstance=GetModuleHandleW(0);wc.lpszClassName=L"USOSVistaESP";
 if(!RegisterClassW(&wc)){DWORD error=GetLastError();unmount_esp(selected_alias);return error;}
 HWND window=CreateWindowExW(0,wc.lpszClassName,L"",0,0,0,0,0,0,0,wc.hInstance,0);if(!window){DWORD error=GetLastError();unmount_esp(selected_alias);return error;}
 DEV_BROADCAST_DEVICEINTERFACE_W filter={0};filter.dbcc_size=sizeof(filter);filter.dbcc_devicetype=DBT_DEVTYP_DEVICEINTERFACE;
 HDEVNOTIFY notification=RegisterDeviceNotificationW(window,&filter,DEVICE_NOTIFY_WINDOW_HANDLE|DEVICE_NOTIFY_ALL_INTERFACE_CLASSES);
 WCHAR panther[MAX_PATH];GetWindowsDirectoryW(panther,MAX_PATH);lstrcatW(panther,L"\\Panther");CreateDirectoryW(panther,0);
 HANDLE changes=FindFirstChangeNotificationW(panther,TRUE,FILE_NOTIFY_CHANGE_FILE_NAME|FILE_NOTIFY_CHANGE_LAST_WRITE);
 if(!notification||changes==INVALID_HANDLE_VALUE){if(notification)UnregisterDeviceNotification(notification);if(changes!=INVALID_HANDLE_VALUE)FindCloseChangeNotification(changes);DestroyWindow(window);unmount_esp(selected_alias);return ERROR_NOT_READY;}
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
 refresh_esp();unmount_esp(selected_alias);
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
 BYTE *mapping=vh_data(&system,vh_value(&system,"MountedDevices",name),3,&size);
 if(!mapping||size!=24||!same(mapping,identity_bytes,24)){
  logcode("Setup drive letter is not mapped to the identified GPT partition=",1);goto done;
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
 if(pinned_esp){
  DWORD code=vista_bcd_command(selection,L"vista-bcd-sysstore.txt");logcode("Finalizer Vista BCDEdit sysstore result=",code);
  if(code||!verify_vista_system_store())goto done;
  path(inspect_store,base,L"vista-bcd-system.bin");
 }else{
  static WCHAR export_args[MAX_PATH+32];lstrcpyW(export_args,L"/export \"");lstrcatW(export_args,inspect_store);lstrcatW(export_args,L"\"");
  if(!DeleteFileW(inspect_store)&&GetLastError()!=ERROR_FILE_NOT_FOUND)goto done;
  if(!bcd_command(0,export_args))goto done;
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
done:unmount_esp(alias);return ok;
}
void entry(void){
 HKEY mini;OSVERSIONINFOW version={sizeof(version)};FIRMWARE_TYPE firmware;
 if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SYSTEM\\CurrentControlSet\\Control\\MiniNT",0,KEY_READ,&mini)!=ERROR_SUCCESS)ExitProcess(2);RegCloseKey(mini);
 typedef LONG (WINAPI *VersionFn)(OSVERSIONINFOW*);
 VersionFn real_version=(VersionFn)GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"RtlGetVersion");
 if(!real_version||real_version(&version)!=0||version.dwMajorVersion!=10||version.dwBuildNumber<10240||version.dwBuildNumber>=22000||!GetFirmwareType(&firmware)||firmware!=FirmwareTypeUefi)ExitProcess(2);
 DWORD n=GetModuleFileNameW(0,base,MAX_PATH);if(!n||n>=MAX_PATH-64)ExitProcess(2);while(n&&base[n-1]!=L'\\')n--;base[n]=0;
 path(scratch,base,L"usos-vista-install.log");log_file=CreateFileW(scratch,GENERIC_WRITE,FILE_SHARE_READ,0,CREATE_ALWAYS,FILE_FLAG_WRITE_THROUGH,0);
 logcode("Vista USB installer v8 / guarded OOBE recovery / KMDF before reboot / known firstboot v11=",0);
 logcode("Firmware type (2 = UEFI)=",firmware);
 WCHAR source[MAX_PATH];n=GetEnvironmentVariableW(L"USOS_SOURCE",source,MAX_PATH);
 if(n!=2||source[1]!=L':'||source[0]<L'C'||source[0]>L'Z')ExitProcess(2);
 WCHAR setup_path[MAX_PATH];path(setup_path,source,L"\\sources\\setup.exe");
 if(!vista_file(setup_path,TRUE)){logcode("Expected original Vista SP2 x64 Setup=",1);ExitProcess(3);}
 BYTE hash[32];for(unsigned i=0;i<sizeof(vista_files)/sizeof(vista_files[0]);i++){
  path(scratch,base,vista_files[i].source);if(!hash_file(scratch,hash)||!same(hash,vista_files[i].sha256,32)){logcode("Preflight payload hash failed at file=",i);ExitProcess(3);}
 }
 if(!privilege(L"SeBackupPrivilege")||!privilege(L"SeRestorePrivilege")||!load_boot_profile()||!inventory(before,&before_count))ExitProcess(4);
 static WCHAR servicing_answer[MAX_PATH];if(!prepare_servicing_answer(servicing_answer))ExitProcess(10);
 lstrcpyW(command,L"\"");lstrcatW(command,setup_path);lstrcatW(command,L"\" /noreboot /installfrom:\"");lstrcatW(command,source);lstrcatW(command,L"\\sources\\install.wim\"");
 lstrcatW(command,L" /unattend:\"");lstrcatW(command,servicing_answer);lstrcatW(command,L"\"");
 /* refresh_esp uses the command buffer too, so give Setup its own command. */
 static WCHAR setup_command[2048];lstrcpyW(setup_command,command);
 DWORD result=run_setup(setup_path,setup_command);logcode("Vista Setup returned=",result);if(result)ExitProcess(result);
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
  MessageBoxW(0,L"Instalator nie przygotowal KMDF 1.11 wymaganego przez USB. Nie uruchamiaj jeszcze Visty z dysku. Logi instalacji zostana zapisane na pendrivie.",L"USOS - Vista KMDF",MB_OK|MB_ICONERROR);
  ExitProcess(10);
 }
 if(!copy_payload(target)){logcode("Copy target USB package failed=",GetLastError());ExitProcess(6);}
 if(!configure_boot(target)){logcode("Target BCD preparation failed=",GetLastError());ExitProcess(7);}
 if(!arm_target(target)){logcode("Arm pre-Setup USB failed=",GetLastError());ExitProcess(8);}
 logcode("Vista target ready for first boot with USB v11=",0);
 CloseHandle(log_file);path(scratch,base,L"usos-vista-install.log");WCHAR target_log[MAX_PATH];path(target_log,target->root,L"USOS\\Vista\\installation-from-usb.log");
 if(!CopyFileW(scratch,target_log,FALSE))ExitProcess(9);
 ExitProcess(0);
}
