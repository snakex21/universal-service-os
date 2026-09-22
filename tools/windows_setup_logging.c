/* WinPE-only snapshots on the source ESP selected by usos-source --log-root.
 * The watcher blocks on filesystem notifications or launcher exit: no polling.
 * All writes stay in the explicitly created USB session directory. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
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
static void save(const WCHAR *from,const WCHAR *name){
 if(length(root)+length(name)+2>=MAX_PATH)return;
 HANDLE in=CreateFileW(from,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,0,OPEN_EXISTING,0,0);if(in==INVALID_HANDLE_VALUE)return;
 LARGE_INTEGER size;if(!GetFileSizeEx(in,&size)||size.QuadPart<0){CloseHandle(in);return;}
 copy(dst,root);append(dst,L"\\");append(dst,name);
 /* Bound each snapshot and keep the newest diagnostics for very large logs. */
 if(size.QuadPart>16*1024*1024){LARGE_INTEGER at;at.QuadPart=size.QuadPart-16*1024*1024;SetFilePointerEx(in,at,0,FILE_BEGIN);append(dst,L".tail");size.QuadPart=16*1024*1024;}
 HANDLE out=CreateFileW(dst,GENERIC_WRITE,FILE_SHARE_READ,0,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
 if(out!=INVALID_HANDLE_VALUE){DWORD got,written;LONGLONG left=size.QuadPart;
  while(left>0){DWORD want=left>sizeof(data)?sizeof(data):(DWORD)left;if(!ReadFile(in,data,want,&got,0)||!got)break;if(!WriteFile(out,data,got,&written,0)||got!=written)break;left-=got;}
  FlushFileBuffers(out);CloseHandle(out);
 }CloseHandle(in);
}
static void local(const WCHAR *file,const WCHAR *name){copy(src,base);append(src,file);save(src,name);}
static void snapshot(void){
 local(L"usos-startup.log",L"usos-startup.log");
 local(L"usos-vista-install.log",L"vista-install.log");
 local(L"vista-bcd-sysstore.txt",L"vista-bcd-sysstore.txt");
 local(L"vista-bcd-export.txt",L"vista-bcd-export.txt");
 local(L"vista-bcd-system.bin",L"vista-bcd-system.bin");
 local(L"vista-servicing.xml",L"vista-servicing.xml");
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
 copy(src,base);append(src,L"usos-modern-vista.flag");if(GetFileAttributesW(src)==INVALID_FILE_ATTRIBUTES)return;
 WCHAR windows[MAX_PATH];if(GetWindowsDirectoryW(windows,MAX_PATH)<3)return;
 DWORD drives=GetLogicalDrives();
 for(unsigned i=2;i<26;i++)if((drives&(1u<<i))&&L'A'+i!=windows[0]){
  WCHAR drive[4]={L'A'+i,':','\\',0};if(GetDriveTypeW(drive)!=DRIVE_FIXED)continue;
  static const WCHAR *paths[]={L"$WINDOWS.~BT\\Sources\\Panther\\setupact.log",L"$WINDOWS.~BT\\Sources\\Panther\\setuperr.log",L"Windows\\Panther\\setupact.log",L"Windows\\Panther\\setuperr.log",L"Windows\\Logs\\CBS\\CBS.log"};
  static const WCHAR *names[]={L"-bt-setupact.log",L"-bt-setuperr.log",L"-windows-setupact.log",L"-windows-setuperr.log",L"-cbs.log"};
  for(unsigned j=0;j<5;j++){WCHAR name[64]=L"target-C";name[7]=drive[0];append(name,names[j]);copy(src,drive);append(src,paths[j]);save(src,name);}
 }
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
    if(contains(name,L"panther")||contains(name,L"setupapi.dev.log")||contains(name,L"dism.log")||contains(name,L"usos-startup.log"))relevant=1;
   }
   if(!item->NextEntryOffset)break;offset+=item->NextEntryOffset;
  }
  if(relevant&&WaitForSingleObject(mutex,INFINITE)==WAIT_OBJECT_0){snapshot();ReleaseMutex(mutex);}
 }
 CloseHandle(change);CloseHandle(directory);
}
void entry(void){
 if(!initialize())ExitProcess(1);
 DWORD pid=launcher();if(!pid)ExitProcess(1);
 WCHAR value[16],mutex_name[80];GetEnvironmentVariableW(L"USOS_LAUNCHER_PID",value,16);copy(mutex_name,L"Local\\USOSSetupLog-");append(mutex_name,value);
 HANDLE mutex=CreateMutexW(0,FALSE,mutex_name);if(!mutex)ExitProcess(1);
 if(WaitForSingleObject(mutex,INFINITE)==WAIT_OBJECT_0){snapshot();ReleaseMutex(mutex);}
 const WCHAR *command=GetCommandLineW();
 if(contains(command,L"--watch")){HANDLE parent=OpenProcess(SYNCHRONIZE,FALSE,pid);if(parent){watch(parent,mutex);CloseHandle(parent);}}
 if(WaitForSingleObject(mutex,INFINITE)==WAIT_OBJECT_0){snapshot();target_snapshots();ReleaseMutex(mutex);}
 CloseHandle(mutex);ExitProcess(0);
}
