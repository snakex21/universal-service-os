/* WinPE-only snapshots on the source ESP selected by usos-source --log-root.
 * The watcher blocks on filesystem notifications or launcher exit: no polling.
 * All writes stay in the explicitly created USB session directory.
 *
 * --previous-install <USOS disk>: before Setup, look for an unfinished or
 * aborted Windows installation on every other volume (State.ini not at
 * IMAGE_STATE_COMPLETE, or a leftover $WINDOWS.~BT) and copy its diagnostics
 * into <session>\previous-install\<letter>\. Diagnostic only: target files
 * are opened for reading, nothing on those volumes is created or changed; the
 * copy is capped (the stick's ESP is small). */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winioctl.h>
void *memcpy(void *out,const void *in,size_t size){volatile BYTE *d=out;const BYTE *s=in;while(size--)*d++=*s++;return out;}
static WCHAR base[MAX_PATH],root[MAX_PATH],src[MAX_PATH],dst[MAX_PATH];
static BYTE data[65536],events[65536];
static unsigned length(const WCHAR *s){unsigned n=0;while(s[n])n++;return n;}
static void copy(WCHAR *d,const WCHAR *s){while((*d++=*s++));}
static void append(WCHAR *d,const WCHAR *s){copy(d+length(d),s);}
static int equal(const WCHAR *a,const WCHAR *b){while(*a&&*a==*b){a++;b++;}return *a==*b;}
static int contains(const WCHAR *s,const WCHAR *part){for(;*s;s++){unsigned i=0;while(part[i]&&s[i]==part[i])i++;if(!part[i])return 1;}return 0;}
static void zero(void *p,unsigned n){BYTE *b=p;while(n--)*b++=0;}
static int initialize(void){
 HKEY key;if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SYSTEM\\CurrentControlSet\\Control\\MiniNT",0,KEY_READ,&key)!=ERROR_SUCCESS)return 0;RegCloseKey(key);
 DWORD n=GetModuleFileNameW(0,base,MAX_PATH);if(!n||n>=MAX_PATH-40)return 0;while(n&&base[n-1]!='\\')n--;base[n]=0;
 copy(src,base);append(src,L"usos-log-root.txt");HANDLE file=CreateFileW(src,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_EXISTING,0,0);if(file==INVALID_HANDLE_VALUE)return 0;
 DWORD got=0;int ok=ReadFile(file,data,MAX_PATH,&got,0);CloseHandle(file);if(!ok||got>=MAX_PATH)return 0;
 n=0;while(n<got&&data[n]!='\r'&&data[n]!='\n'){if(data[n]<32||data[n]>126)return 0;root[n]=data[n];n++;}root[n]=0;
 if(n<60||n>MAX_PATH-80||!contains(root,L"\\EFI\\USOS\\Logs\\WinSetup-")||contains(root,L".."))return 0;
 const WCHAR *prefix=L"\\\\?\\GLOBALROOT\\Device\\Harddisk";for(unsigned i=0;prefix[i];i++)if(root[i]!=prefix[i])return 0;
 return GetFileAttributesW(root)!=INVALID_FILE_ATTRIBUTES;
}
/* Each snapshot is written beside the old one and then renamed over it: a
 * copy cut short (reboot or power-off while the watcher rewrites the set) no
 * longer leaves a truncated or 0-byte log, and an empty source never replaces
 * a snapshot that already has content. */
static WCHAR fresh[MAX_PATH];
static void save(const WCHAR *from,const WCHAR *name){
 if(length(root)+length(name)+8>=MAX_PATH)return;
 HANDLE in=CreateFileW(from,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,0,OPEN_EXISTING,0,0);if(in==INVALID_HANDLE_VALUE)return;
 LARGE_INTEGER size;if(!GetFileSizeEx(in,&size)||size.QuadPart<0){CloseHandle(in);return;}
 copy(dst,root);append(dst,L"\\");append(dst,name);
 /* Bound each snapshot and keep the newest diagnostics for very large logs. */
 if(size.QuadPart>16*1024*1024){LARGE_INTEGER at;at.QuadPart=size.QuadPart-16*1024*1024;SetFilePointerEx(in,at,0,FILE_BEGIN);append(dst,L".tail");size.QuadPart=16*1024*1024;}
 if(!size.QuadPart){WIN32_FILE_ATTRIBUTE_DATA old;if(GetFileAttributesExW(dst,GetFileExInfoStandard,&old)&&(old.nFileSizeLow||old.nFileSizeHigh)){CloseHandle(in);return;}}
 copy(fresh,dst);append(fresh,L".new");
 HANDLE out=CreateFileW(fresh,GENERIC_WRITE,FILE_SHARE_READ,0,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
 if(out!=INVALID_HANDLE_VALUE){DWORD got,written;LONGLONG left=size.QuadPart;int ok=1;
  while(left>0){DWORD want=left>sizeof(data)?sizeof(data):(DWORD)left;if(!ReadFile(in,data,want,&got,0)||!got){ok=left==size.QuadPart?0:ok;break;}if(!WriteFile(out,data,got,&written,0)||got!=written){ok=0;break;}left-=got;}
  ok=FlushFileBuffers(out)&&ok;CloseHandle(out);
  if(!ok||!MoveFileExW(fresh,dst,MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))DeleteFileW(fresh);
 }CloseHandle(in);
}
/* Capped copy into dir\name for the previous-install report. Text logs keep
 * their newest part when too large; binary files (evtx, dmp) are copied whole
 * or skipped. Returns the bytes written (0 = not copied). */
#define PREVIOUS_FILE_LIMIT (8u*1024u*1024u)
#define PREVIOUS_TOTAL_LIMIT (32u*1024u*1024u)
static DWORD previous_budget=PREVIOUS_TOTAL_LIMIT;
static HANDLE previous_summary=INVALID_HANDLE_VALUE;
static void ascii(HANDLE out,const char *text){DWORD n=0,w;while(text[n])n++;if(out!=INVALID_HANDLE_VALUE)WriteFile(out,text,n,&w,0);}
static void asciiw(HANDLE out,const WCHAR *text){char b[MAX_PATH];unsigned i=0;for(;text[i]&&i<MAX_PATH-1;i++)b[i]=text[i]<128?(char)text[i]:'?';b[i]=0;ascii(out,b);}
static void decimal(HANDLE out,DWORD value){char b[16];int i=15;b[i]=0;do{b[--i]=(char)('0'+value%10);value/=10;}while(value&&i);ascii(out,b+i);}
static void note(const char *what,const WCHAR *from,DWORD bytes){ascii(previous_summary,what);ascii(previous_summary," ");asciiw(previous_summary,from);if(bytes){ascii(previous_summary," bytes=");decimal(previous_summary,bytes);}ascii(previous_summary,"\r\n");}
static void save_previous(const WCHAR *dir,const WCHAR *from,const WCHAR *name,int text){
 if(length(dir)+length(name)+8>=MAX_PATH)return;
 HANDLE in=CreateFileW(from,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,0,OPEN_EXISTING,FILE_FLAG_SEQUENTIAL_SCAN,0);if(in==INVALID_HANDLE_VALUE)return;
 LARGE_INTEGER size;if(!GetFileSizeEx(in,&size)||size.QuadPart<0){CloseHandle(in);return;}
 LONGLONG want=size.QuadPart;int tail=0;
 if(want>PREVIOUS_FILE_LIMIT){if(!text){CloseHandle(in);note("skipped (larger than 8 MiB)",from,0);return;}want=PREVIOUS_FILE_LIMIT;tail=1;}
 if(want>previous_budget){CloseHandle(in);note("skipped (copy budget used up)",from,0);return;}
 if(tail){LARGE_INTEGER at;at.QuadPart=size.QuadPart-want;SetFilePointerEx(in,at,0,FILE_BEGIN);}
 copy(dst,dir);append(dst,L"\\");append(dst,name);if(tail)append(dst,L".tail");
 HANDLE out=CreateFileW(dst,GENERIC_WRITE,FILE_SHARE_READ,0,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
 DWORD total=0;
 if(out!=INVALID_HANDLE_VALUE){DWORD got,written;LONGLONG left=want;
  while(left>0){DWORD chunk=left>sizeof(data)?sizeof(data):(DWORD)left;if(!ReadFile(in,data,chunk,&got,0)||!got)break;if(!WriteFile(out,data,got,&written,0)||got!=written)break;left-=got;total+=got;}
  FlushFileBuffers(out);CloseHandle(out);
 }
 CloseHandle(in);previous_budget-=total;note(tail?"copied (newest 8 MiB)":"copied",from,total);
}
/* Every file of dir_path (one level, no sub-folders) as <prefix><name>. */
static void save_previous_folder(const WCHAR *dir,const WCHAR *drive,const WCHAR *folder,const WCHAR *prefix,int text){
 static WCHAR pattern[MAX_PATH],from[MAX_PATH],name[MAX_PATH];static WIN32_FIND_DATAW found;copy(pattern,drive);append(pattern,folder);append(pattern,L"\\*");
 HANDLE find=FindFirstFileW(pattern,&found);if(find==INVALID_HANDLE_VALUE)return;
 do{if(found.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)continue;if(length(found.cFileName)+length(prefix)+2>=64)continue;
  copy(from,drive);append(from,folder);append(from,L"\\");append(from,found.cFileName);copy(name,prefix);append(name,found.cFileName);save_previous(dir,from,name,text);
 }while(FindNextFileW(find,&found));
 FindClose(find);
}
static int volume_disk(const WCHAR *volume,DWORD *disk){
 WCHAR path[MAX_PATH];copy(path,volume);unsigned n=length(path);if(n&&path[n-1]=='\\')path[n-1]=0;
 HANDLE h=CreateFileW(path,0,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_EXISTING,0,0);if(h==INVALID_HANDLE_VALUE)return 0;
 union{VOLUME_DISK_EXTENTS e;BYTE raw[sizeof(VOLUME_DISK_EXTENTS)+8*sizeof(DISK_EXTENT)];}extents;DWORD got=0;
 BOOL ok=DeviceIoControl(h,IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS,0,0,&extents,sizeof(extents),&got,0);CloseHandle(h);
 if(!ok||!extents.e.NumberOfDiskExtents)return 0;*disk=extents.e.Extents[0].DiskNumber;return 1;
}
static int file_contains(const WCHAR *path,const char *needle,int *exists){
 *exists=0;HANDLE in=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,0,OPEN_EXISTING,0,0);if(in==INVALID_HANDLE_VALUE)return 0;
 *exists=1;DWORD got=0;ReadFile(in,data,sizeof(data)-2,&got,0);CloseHandle(in);
 unsigned n=0;while(needle[n])n++;
 for(DWORD i=0;i+n<=got;i++){unsigned j=0;while(j<n&&data[i+j]==(BYTE)needle[j])j++;if(j==n)return 1;}
 for(DWORD i=0;i+2*n<=got;i++){unsigned j=0;while(j<n&&data[i+2*j]==(BYTE)needle[j]&&data[i+2*j+1]==0)j++;if(j==n)return 1;}
 return 0;
}
static DWORD parse_disk(const WCHAR *command,int *ok){
 static const WCHAR flag[]=L"--previous-install";const WCHAR *at=command;*ok=0;
 for(;*at;at++){unsigned k=0;while(flag[k]&&at[k]==flag[k])k++;if(!flag[k]){at+=k;break;}}
 while(*at==' ')at++;DWORD value=0;
 for(;*at>='0'&&*at<='9';at++){value=value*10+(DWORD)(*at-'0');*ok=1;}
 return value;
}
/* One volume root ("D:\\" or "\\\\?\\Volume{...}\\"): 1 when it holds an
 * unfinished install (its diagnostics are then copied under
 * previous-install\\<label>). */
static int scan_volume(const WCHAR *drive,const WCHAR *label,HANDLE out){
 static WCHAR state[MAX_PATH],bt[MAX_PATH];copy(state,drive);append(state,L"Windows\\Setup\\State\\State.ini");copy(bt,drive);append(bt,L"$WINDOWS.~BT");
 int state_exists;int complete=file_contains(state,"IMAGE_STATE_COMPLETE",&state_exists);
 DWORD bt_attr=GetFileAttributesW(bt);int bt_left=bt_attr!=INVALID_FILE_ATTRIBUTES&&(bt_attr&FILE_ATTRIBUTE_DIRECTORY);
 if(!(state_exists&&!complete)&&!bt_left)return 0;
 static WCHAR dir[MAX_PATH];copy(dir,root);append(dir,L"\\previous-install");CreateDirectoryW(dir,0);
 WCHAR sub[16];copy(sub,label);append(dir,L"\\");append(dir,sub);CreateDirectoryW(dir,0);
 static WCHAR summary[MAX_PATH];copy(summary,dir);append(summary,L"\\summary.txt");
 previous_summary=CreateFileW(summary,GENERIC_WRITE,FILE_SHARE_READ,0,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
 ascii(previous_summary,"USOS: unfinished or aborted Windows installation on ");asciiw(previous_summary,drive);ascii(previous_summary,"\r\n");
 ascii(previous_summary,state_exists?(complete?"State.ini: IMAGE_STATE_COMPLETE\r\n":"State.ini: not IMAGE_STATE_COMPLETE\r\n"):"State.ini: missing\r\n");
 ascii(previous_summary,bt_left?"$WINDOWS.~BT: present\r\n":"$WINDOWS.~BT: absent\r\n");
 static WCHAR from[MAX_PATH];
 static const WCHAR *texts[][2]={{L"Windows\\Panther\\setupact.log",L"panther-setupact.log"},{L"Windows\\Panther\\setuperr.log",L"panther-setuperr.log"},
  {L"Windows\\Setup\\State\\State.ini",L"State.ini"},{L"$WINDOWS.~BT\\Sources\\Panther\\setupact.log",L"bt-panther-setupact.log"},
  {L"$WINDOWS.~BT\\Sources\\Panther\\setuperr.log",L"bt-panther-setuperr.log"}};
 for(unsigned j=0;j<sizeof(texts)/sizeof(texts[0]);j++){copy(from,drive);append(from,texts[j][0]);save_previous(dir,from,texts[j][1],1);}
 save_previous_folder(dir,drive,L"Windows\\Panther\\UnattendGC",L"unattendgc-",1);
 static const WCHAR *binaries[][2]={{L"Windows\\System32\\winevt\\Logs\\System.evtx",L"System.evtx"},{L"Windows\\System32\\winevt\\Logs\\Setup.evtx",L"Setup.evtx"}};
 for(unsigned j=0;j<2;j++){copy(from,drive);append(from,binaries[j][0]);save_previous(dir,from,binaries[j][1],0);}
 save_previous_folder(dir,drive,L"Windows\\Minidump",L"minidump-",0);
 ascii(previous_summary,"(read-only copy; nothing on this volume was changed)\r\n");
 if(previous_summary!=INVALID_HANDLE_VALUE){FlushFileBuffers(previous_summary);CloseHandle(previous_summary);}previous_summary=INVALID_HANDLE_VALUE;
 ascii(out,"[USOS] WARNING: unfinished or aborted Windows installation found on ");asciiw(out,drive);
 ascii(out,state_exists&&!complete?" (State.ini not IMAGE_STATE_COMPLETE":" (State.ini complete or missing");ascii(out,bt_left?", $WINDOWS.~BT present)":")");
 ascii(out,"; its logs were copied to the USB log folder, previous-install\\");asciiw(out,sub);ascii(out,"\r\n");
 return 1;
}
/* Every mounted volume, lettered or not (a target partition may have no drive
 * letter in WinPE): skip WinPE's own X: and every volume of the USOS disk. */
static int previous_install(const WCHAR *command){
 int ok;DWORD usos_disk=parse_disk(command,&ok);if(!ok)return 2;
 WCHAR windows[MAX_PATH];if(GetWindowsDirectoryW(windows,MAX_PATH)<3)return 2;
 WCHAR system_root[4]={windows[0],':','\\',0},system_volume[MAX_PATH];static WCHAR volume[MAX_PATH],names[MAX_PATH];
 if(!GetVolumeNameForVolumeMountPointW(system_root,system_volume,MAX_PATH))system_volume[0]=0;
 HANDLE out=GetStdHandle(STD_OUTPUT_HANDLE);int found_any=0;unsigned unlettered=0;
 HANDLE find=FindFirstVolumeW(volume,MAX_PATH);
 if(find==INVALID_HANDLE_VALUE){ascii(out,"[USOS] previous-install: no volumes listed\r\n");return 0;}
 do{
  if(system_volume[0]&&equal(volume,system_volume))continue;
  UINT type=GetDriveTypeW(volume);if(type!=DRIVE_FIXED&&type!=DRIVE_REMOVABLE)continue;
  DWORD got=0;WCHAR label[16];
  if(GetVolumePathNamesForVolumeNameW(volume,names,MAX_PATH,&got)&&names[0]&&names[1]==':'){label[0]=names[0];label[1]=0;}
  else{copy(label,L"volume-");WCHAR number[3]={(WCHAR)('0'+(unlettered+1)/10%10),(WCHAR)('0'+(unlettered+1)%10),0};append(label,number);unlettered++;}
  DWORD disk;if(!volume_disk(volume,&disk)){ascii(out,"[USOS] previous-install: ");asciiw(out,label);ascii(out," skipped (no disk number)\r\n");continue;}
  if(disk==usos_disk)continue;
  ascii(out,"[USOS] previous-install: checking ");asciiw(out,label);ascii(out," on disk ");decimal(out,disk);ascii(out,"\r\n");
  if(scan_volume(volume,label,out))found_any=1;
 }while(FindNextVolumeW(find,volume,MAX_PATH));
 FindVolumeClose(find);
 if(!found_any)ascii(out,"[USOS] No unfinished Windows installation found on the other disks.\r\n");
 return 0;
}
static void local(const WCHAR *file,const WCHAR *name){copy(src,base);append(src,file);save(src,name);}
/* Setup's Panther logs wherever they appear on the WinPE drive: Vista Setup
 * run from the ISO under PE10 does not use X:\Windows\Panther. The watcher
 * records each setupact/setuperr path it sees (relative to X:\). */
static WCHAR panther_seen[8][160];
static unsigned panther_count;
static void remember_panther(const WCHAR *lower_name,const FILE_NOTIFY_INFORMATION *item){
 if(!contains(lower_name,L"panther\\")||(!contains(lower_name,L"setupact.log")&&!contains(lower_name,L"setuperr.log")))return;
 unsigned chars=item->FileNameLength/sizeof(WCHAR);if(chars>=160)return;
 WCHAR name[160];for(unsigned i=0;i<chars;i++)name[i]=item->FileName[i];name[chars]=0;
 for(unsigned i=0;i<panther_count;i++)if(equal(panther_seen[i],name))return;
 if(panther_count<8)copy(panther_seen[panther_count++],name);
}
static void save_panther_seen(void){
 WCHAR windows[MAX_PATH];if(GetWindowsDirectoryW(windows,MAX_PATH)<3)return;
 for(unsigned i=0;i<panther_count;i++){
  static WCHAR name[200];copy(name,L"x-");unsigned n=2;
  for(const WCHAR *p=panther_seen[i];*p&&n<190;p++)name[n++]=(*p==L'\\'||*p==L':'||*p==L'$'||*p==L'~')?L'_':*p;
  name[n]=0;copy(src,L"X:\\");src[0]=windows[0];append(src,panther_seen[i]);save(src,name);
 }
}
static void snapshot(void){
 local(L"usos-startup.log",L"usos-startup.log");
 local(L"usos-vista-install.log",L"vista-install.log");
 local(L"vista-bcd-sysstore.txt",L"vista-bcd-sysstore.txt");
 local(L"vista-bcd-export.txt",L"vista-bcd-export.txt");
 local(L"vista-bcd-system.bin",L"vista-bcd-system.bin");
 local(L"vista-servicing.xml",L"vista-servicing.xml");
 local(L"usos-vista-dism.log",L"vista-dism.log");
 save_panther_seen();
 local(L"usos-build.txt",L"build.txt");
 local(L"usos-source.ini",L"source-identity.bin");
 local(L"usos-source\\source.log",L"source-mount.log");
 local(L"usos-source\\source-disk.txt",L"source-disk.txt");
 /* Copy only our generated manual-install answer. User answers stay in RAM. */
 copy(src,base);append(src,L"usos-unattend.xml");
 if(GetFileAttributesW(src)==INVALID_FILE_ATTRIBUTES)local(L"usos-driver-unattend.xml",L"generated-answer.xml");
 WCHAR windows[MAX_PATH];DWORD n=GetWindowsDirectoryW(windows,MAX_PATH);if(n<3||n>MAX_PATH-60)return;
 copy(src,windows);append(src,L"\\Panther\\setupact.log");save(src,L"pe-panther-setupact.log");
 copy(src,windows);append(src,L"\\Panther\\setuperr.log");save(src,L"pe-panther-setuperr.log");
 copy(src,windows);append(src,L"\\INF\\setupapi.dev.log");save(src,L"setupapi.dev.log");
 copy(src,windows);append(src,L"\\Logs\\DISM\\dism.log");save(src,L"dism.log");
 WCHAR drive[4]={windows[0],':','\\',0};
 copy(src,drive);append(src,L"$WINDOWS.~BT\\Sources\\Panther\\setupact.log");save(src,L"bt-panther-setupact.log");
 copy(src,drive);append(src,L"$WINDOWS.~BT\\Sources\\Panther\\setuperr.log");save(src,L"bt-panther-setuperr.log");
 copy(src,drive);append(src,L"sources\\Panther\\setupact.log");save(src,L"sources-panther-setupact.log");
 copy(src,drive);append(src,L"sources\\Panther\\setuperr.log");save(src,L"sources-panther-setuperr.log");
}
/* Setup moves Panther off X: after selecting/formatting the destination.
 * Export these logs at process completion, not on every RAM-log notification. */
static void target_snapshots(void){
 WCHAR windows[MAX_PATH];if(GetWindowsDirectoryW(windows,MAX_PATH)<3)return;
 DWORD drives=GetLogicalDrives();
 /* Windows 10/11 native UEFI: Setup's own Panther logs on the target
  * ($WINDOWS.~BT), like the Vista/7 paths; nothing else, the ESP is small. */
 copy(src,base);append(src,L"usos-modern-uefi.flag");
 if(GetFileAttributesW(src)!=INVALID_FILE_ATTRIBUTES){
  for(unsigned i=2;i<26;i++)if((drives&(1u<<i))&&L'A'+i!=windows[0]){
   WCHAR drive[4]={L'A'+i,':','\\',0};if(GetDriveTypeW(drive)!=DRIVE_FIXED)continue;
   WCHAR name[64]=L"target-C";name[7]=drive[0];append(name,L"-bt-setupact.log");copy(src,drive);append(src,L"$WINDOWS.~BT\\Sources\\Panther\\setupact.log");save(src,name);
   copy(name,L"target-C");name[7]=drive[0];append(name,L"-bt-setuperr.log");copy(src,drive);append(src,L"$WINDOWS.~BT\\Sources\\Panther\\setuperr.log");save(src,name);
  }
  return;
 }
 copy(src,base);append(src,L"usos-modern-vista.flag");if(GetFileAttributesW(src)==INVALID_FILE_ATTRIBUTES)return;
 for(unsigned i=2;i<26;i++)if((drives&(1u<<i))&&L'A'+i!=windows[0]){
  WCHAR drive[4]={L'A'+i,':','\\',0};if(GetDriveTypeW(drive)!=DRIVE_FIXED)continue;
  static const WCHAR *paths[]={L"$WINDOWS.~BT\\Sources\\Panther\\setupact.log",L"$WINDOWS.~BT\\Sources\\Panther\\setuperr.log",L"Windows\\Panther\\setupact.log",L"Windows\\Panther\\setuperr.log",L"Windows\\Logs\\CBS\\CBS.log"};
  static const WCHAR *names[]={L"-bt-setupact.log",L"-bt-setuperr.log",L"-windows-setupact.log",L"-windows-setuperr.log",L"-cbs.log"};
  for(unsigned j=0;j<5;j++){WCHAR name[64]=L"target-C";name[7]=drive[0];append(name,names[j]);copy(src,drive);append(src,paths[j]);save(src,name);}
 }
 /* Vista Setup writes its Panther log only to <target>\$WINDOWS.~BT (seen in
  * QEMU 2026-09-26: nothing on X:), and the target of a failed run may have no
  * drive letter in WinPE: also every unlettered volume, as target-vol-N-*. */
 static WCHAR volume[MAX_PATH],names_found[MAX_PATH];unsigned unlettered=0;
 HANDLE find=FindFirstVolumeW(volume,MAX_PATH);if(find==INVALID_HANDLE_VALUE)return;
 do{
  DWORD got=0;if(GetVolumePathNamesForVolumeNameW(volume,names_found,MAX_PATH,&got)&&names_found[0])continue;
  if(GetDriveTypeW(volume)!=DRIVE_FIXED)continue;
  unlettered++;
  for(unsigned j=0;j<2;j++){
   static const WCHAR *bt[]={L"$WINDOWS.~BT\\Sources\\Panther\\setupact.log",L"$WINDOWS.~BT\\Sources\\Panther\\setuperr.log"};
   WCHAR name[64]=L"target-vol-";WCHAR n[3]={(WCHAR)(L'0'+unlettered/10%10),(WCHAR)(L'0'+unlettered%10),0};append(name,n);append(name,j?L"-bt-setuperr.log":L"-bt-setupact.log");
   copy(src,volume);append(src,bt[j]);save(src,name);
  }
 }while(FindNextVolumeW(find,volume,MAX_PATH));
 FindVolumeClose(find);
}
static DWORD launcher(void){WCHAR value[16];DWORD n=GetEnvironmentVariableW(L"USOS_LAUNCHER_PID",value,16),pid=0;if(!n||n>=16)return 0;
 for(unsigned i=0;i<n;i++){if(value[i]<'0'||value[i]>'9'||pid>429496729)return 0;pid=pid*10+value[i]-'0';}return pid;
}
static void watch(HANDLE parent,HANDLE mutex){
 WCHAR windows[MAX_PATH];if(GetWindowsDirectoryW(windows,MAX_PATH)<3)return;WCHAR drive[4]={windows[0],':','\\',0};
 HANDLE directory=CreateFileW(drive,FILE_LIST_DIRECTORY,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,0,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OVERLAPPED,0);
 if(directory==INVALID_HANDLE_VALUE)return;
 HANDLE change=CreateEventW(0,TRUE,FALSE,0);if(!change){CloseHandle(directory);return;}
 HANDLE waiters[2]={parent,change};OVERLAPPED pending;zero(&pending,sizeof(pending));pending.hEvent=change;
 for(;;){
  ResetEvent(change);
  if(!ReadDirectoryChangesW(directory,events,sizeof(events),TRUE,FILE_NOTIFY_CHANGE_LAST_WRITE|FILE_NOTIFY_CHANGE_FILE_NAME,0,&pending,0))break;
  DWORD result=WaitForMultipleObjects(2,waiters,FALSE,INFINITE);
  if(result!=WAIT_OBJECT_0+1){CancelIo(directory);WaitForSingleObject(change,INFINITE);break;}
  DWORD bytes=0;if(!GetOverlappedResult(directory,&pending,&bytes,FALSE))break;
  int relevant=bytes==0;
  for(DWORD offset=0;offset<bytes;){FILE_NOTIFY_INFORMATION *item=(void*)(events+offset);WCHAR name[512];unsigned chars=item->FileNameLength/sizeof(WCHAR);
   if(chars<512){for(unsigned i=0;i<chars;i++){WCHAR c=item->FileName[i];name[i]=c>='A'&&c<='Z'?c+32:c;}name[chars]=0;
    if(contains(name,L"panther")||contains(name,L"setupapi.dev.log")||contains(name,L"dism.log")||contains(name,L"usos-startup.log")||contains(name,L"usos-vista-install.log"))relevant=1;
    remember_panther(name,item);
   }
   if(!item->NextEntryOffset)break;offset+=item->NextEntryOffset;
  }
  if(relevant&&WaitForSingleObject(mutex,INFINITE)==WAIT_OBJECT_0){snapshot();ReleaseMutex(mutex);}
 }
 CloseHandle(change);CloseHandle(directory);
}
void entry(void){
 if(!initialize())ExitProcess(1);
 const WCHAR *arguments=GetCommandLineW();
 if(contains(arguments,L"--previous-install"))ExitProcess((UINT)previous_install(arguments));
 DWORD pid=launcher();if(!pid)ExitProcess(1);
 WCHAR value[16],mutex_name[80];GetEnvironmentVariableW(L"USOS_LAUNCHER_PID",value,16);copy(mutex_name,L"Local\\USOSSetupLog-");append(mutex_name,value);
 HANDLE mutex=CreateMutexW(0,FALSE,mutex_name);if(!mutex)ExitProcess(1);
 if(WaitForSingleObject(mutex,INFINITE)==WAIT_OBJECT_0){snapshot();ReleaseMutex(mutex);}
 const WCHAR *command=GetCommandLineW();
 if(contains(command,L"--watch")){HANDLE parent=OpenProcess(SYNCHRONIZE,FALSE,pid);if(parent){watch(parent,mutex);CloseHandle(parent);}}
 if(WaitForSingleObject(mutex,INFINITE)==WAIT_OBJECT_0){snapshot();target_snapshots();ReleaseMutex(mutex);}
 CloseHandle(mutex);ExitProcess(0);
}
