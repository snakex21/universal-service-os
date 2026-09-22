/* WinPE-only, read-only access to WORK on pre-1703 removable USB devices.
 * No CRT dependency: original Vista/Win7 PE does not contain the Universal CRT.
 * Configuration, binaries and redirected logs live beside this executable.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winioctl.h>
#include <stdint.h>

#if defined(__i386__)
/* The freestanding x86 build needs integer division but no C runtime. */
uint64_t __udivdi3(uint64_t a,uint64_t b){uint64_t q=0,r=0;for(int i=63;i>=0;i--){unsigned carry=(unsigned)(r>>63);r=(r<<1)|((a>>i)&1);if(carry||r>=b){r-=b;q|=1ull<<i;}}return q;}
#endif

static BYTE header[4096], backup[4096], entries[65536], other[65536];
static WCHAR base[MAX_PATH], path[MAX_PATH], command[2048];
static BYTE wanted[16];
static unsigned sector;
static HANDLE disk;
static uint64_t disk_size, offset, length;
static int iso_mode;
static uint64_t iso_size;
static WCHAR iso_path[512];
static void output(const char *s) { DWORD n=0,w; while(s[n])n++; WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),s,n,&w,0); }
static void number(uint64_t x) { char s[24];unsigned n=23;s[n]=0;do{s[--n]=(char)('0'+x%10);x/=10;}while(x);output(s+n); }
static int error(const char *s) {output("USOS source: ");output(s);output("\r\n");return 1;}
static int equal(const void *a,const void *b,unsigned n) {const BYTE *x=a,*y=b;while(n--)if(*x++!=*y++)return 0;return 1;}
static uint32_t u32(const BYTE *p) {return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static uint64_t u64(const BYTE *p) {return u32(p)|(uint64_t)u32(p+4)<<32;}
static uint32_t crc(const BYTE *p,unsigned n) {uint32_t c=~0u;while(n--){c^=*p++;for(unsigned i=0;i<8;i++)c=(c>>1)^(0xedb88320u&(0u-(c&1)));}return ~c;}
static unsigned wlen(const WCHAR *s){unsigned n=0;while(s[n])n++;return n;}
static void wcopy(WCHAR *d,const WCHAR *s){while((*d++=*s++));}
static void append(WCHAR *d,const WCHAR *s){wcopy(d+wlen(d),s);}
static void append_num(WCHAR *d,uint64_t x){WCHAR s[24];unsigned n=23;s[n]=0;do{s[--n]=(WCHAR)('0'+x%10);x/=10;}while(x);append(d,s+n);}
static int hex(WCHAR c){if(c>='0'&&c<='9')return c-'0';if(c>='a'&&c<='f')return c-'a'+10;if(c>='A'&&c<='F')return c-'A'+10;return -1;}
static int guid(const WCHAR *s){
 BYTE b[16];unsigned n=0;
 if(wlen(s)!=36)return 0;
 for(unsigned i=0;i<36;){if(i==8||i==13||i==18||i==23){if(s[i++]!='-')return 0;continue;}int a=hex(s[i++]),c=hex(s[i++]);if(a<0||c<0)return 0;b[n++]=(BYTE)(a*16+c);}
 const BYTE order[16]={3,2,1,0,5,4,7,6,8,9,10,11,12,13,14,15};
 for(unsigned i=0;i<16;i++)wanted[i]=b[order[i]];
 return 1;
}
static int read_at(uint64_t pos,void *dst,DWORD size){
 if(pos>disk_size||size>disk_size-pos)return 0;
 LARGE_INTEGER p;p.QuadPart=(LONGLONG)pos;DWORD got=0;
 return SetFilePointerEx(disk,p,0,FILE_BEGIN)&&ReadFile(disk,dst,size,&got,0)&&got==size;
}
static int valid_header(BYTE *p,uint64_t at,uint64_t alt){
 if(!equal(p,"EFI PART",8)||u32(p+8)!=0x10000)return 0;
 unsigned size=u32(p+12);if(size<92||size>sector||u32(p+20)!=0)return 0;
 uint32_t saved=u32(p+16);p[16]=p[17]=p[18]=p[19]=0;
 if(crc(p,size)!=saved)return 0;
 return u64(p+24)==at&&u64(p+32)==alt;
}
/* Validate both GPT copies, their complete entry arrays and the selected NTFS
 * range. All arithmetic is bounded before reads; never infer a disk number. */
static int inspect(void){
 const BYTE basic[16]={0xa2,0xa0,0xd0,0xeb,0xe5,0xb9,0x33,0x44,0x87,0xc0,0x68,0xb6,0xb7,0x26,0x99,0xc7};
 if((sector!=512&&sector!=4096)||disk_size>0x7fffffffffffffffull||disk_size%sector||disk_size<sector*68ull)return 0;
 uint64_t last=disk_size/sector-1;
 if(!read_at(sector,header,sector)||!valid_header(header,1,last))return 0;
 if(!read_at(last*sector,backup,sector)||!valid_header(backup,last,1))return 0;
 if(!equal(header+40,backup+40,32)||!equal(header+80,backup+80,12))return 0;
 uint64_t first=u64(header+40),end=u64(header+48);
 unsigned count=u32(header+80),stride=u32(header+84);
 if(!count||count>512||stride<128||stride>512||stride%128||count>sizeof(entries)/stride)return 0;
 unsigned bytes=count*stride,rounded=(bytes+sector-1)/sector*sector;
 uint64_t table=u64(header+72),btable=u64(backup+72),table_sectors=rounded/sector;
 if(table<2||table>last-table_sectors||first<table+table_sectors||first>end||end>=btable||btable>last-table_sectors)return 0;
 if(!read_at(table*sector,entries,rounded)||!read_at(btable*sector,other,rounded))return 0;
 if(crc(entries,bytes)!=u32(header+88)||!equal(entries,other,bytes))return 0;
 unsigned found=0,index=0;
 for(unsigned i=0;i<count;i++)if(equal(entries+i*stride+16,wanted,16)){found++;index=i;}
 if(found!=1)return 0;
 BYTE *p=entries+index*stride;
 uint64_t start=u64(p+32),finish=u64(p+40);
 if(!equal(p,basic,16)||start<first||finish>end||start>finish)return 0;
 for(unsigned i=0;i<count;i++)if(i!=index){
  BYTE *q=entries+i*stride;unsigned used=0;for(unsigned j=0;j<16;j++)used|=q[j];
  if(used&&u64(q+32)<=finish&&u64(q+40)>=start)return 0;
 }
 offset=start*sector;length=(finish-start+1)*sector;
 if(!read_at(offset,other,sector)||!equal(other+3,"NTFS    ",8)||other[510]!=0x55||other[511]!=0xaa)return 0;
 if(((unsigned)other[11]|(unsigned)other[12]<<8)!=sector||!u64(other+40)||u64(other+40)>length/sector)return 0;
 return 1;
}
static int parse_config(const BYTE *b,unsigned n){
 if(n>=33&&equal(b,"USOSISO1",8)){
  if(n>32+sizeof(iso_path)/sizeof(iso_path[0])||b[n-1]!=0||u64(b+24)<32768)return 0;
  unsigned nonzero=0;for(unsigned i=0;i<16;i++){wanted[i]=b[i+8];nonzero|=wanted[i];}if(!nonzero)return 0;
  unsigned component=0;
  for(unsigned i=32;i<n-1;i++){
   BYTE c=b[i];if(c<32||c>126||c=='/'||c==':'||c=='"'||c=='*'||c=='?'||c=='<'||c=='>'||c=='|')return 0;
   if(c=='\\'){
    if(!component||(component==1&&b[i-1]=='.')||(component==2&&b[i-2]=='.'&&b[i-1]=='.'))return 0;
    component=0;
   }else component++;
   iso_path[i-32]=c;
  }
  if(!component||(component==1&&b[n-2]=='.')||(component==2&&b[n-3]=='.'&&b[n-2]=='.'))return 0;
  iso_path[n-33]=0;iso_size=u64(b+24);iso_mode=1;return 1;
 }
 if(n<50||n>=128||!equal(b,"work_partuuid=",14))return 0;
 WCHAR s[37];for(unsigned i=0;i<36;i++)s[i]=b[i+14];s[36]=0;
 for(unsigned i=50;i<n;i++)if(b[i]!='\r'&&b[i]!='\n')return 0;
 return guid(s);
}
static int source_config(void){
 wcopy(path,base);append(path,L"usos-source.ini");
 HANDLE h=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(h==INVALID_HANDLE_VALUE)return 0;
 BYTE b[1024];DWORD n=0;BOOL ok=ReadFile(h,b,sizeof(b),&n,0);CloseHandle(h);
 return ok&&n<sizeof(b)&&parse_config(b,n);
}
static int start_driver(void){
 wcopy(path,base);append(path,L"imdisk.sys");
 SC_HANDLE scm=OpenSCManagerW(0,0,SC_MANAGER_CREATE_SERVICE);if(!scm)return error("cannot open WinPE service manager");
 SC_HANDLE svc=CreateServiceW(scm,L"ImDisk",L"USOS temporary source reader",SERVICE_START|DELETE,SERVICE_KERNEL_DRIVER,SERVICE_DEMAND_START,SERVICE_ERROR_NORMAL,path,0,0,0,0,0);
 if(!svc){CloseServiceHandle(scm);return error("driver service already exists or could not be created");}
 BOOL ok=StartServiceW(svc,0,0);DWORD e=GetLastError();
 /* This registration is temporary in the WinPE RAM registry. No host or
  * installed OS service/configuration is created. */
 DeleteService(svc);CloseServiceHandle(svc);CloseServiceHandle(scm);
 if(!ok){output("Driver error ");number(e);output("\r\n");return 1;}return 0;
}
static int mapper(void){
 STARTUPINFOW si;PROCESS_INFORMATION pi;BYTE *z=(BYTE*)&si;for(unsigned i=0;i<sizeof(si);i++)z[i]=0;si.cb=sizeof(si);
 if(!CreateProcessW(path,command,0,0,TRUE,0,0,base,&si,&pi))return error("cannot start read-only source mapper");
 DWORD wait=WaitForSingleObject(pi.hProcess,120000),code=1;
 if(wait==WAIT_OBJECT_0)GetExitCodeProcess(pi.hProcess,&code);
 CloseHandle(pi.hThread);CloseHandle(pi.hProcess);
 if(wait!=WAIT_OBJECT_0||code)return error("read-only source mapping failed");
 return 0;
}
static WCHAR free_letter(void){
 WCHAR device[3]={0,':',0};DWORD used=GetLogicalDrives();
 for(WCHAR c='S';c<='Z';c++)if(c!='X'&&!(used&(1u<<(c-'A')))){
  device[0]=c;
  if(!QueryDosDeviceW(device,path,MAX_PATH)&&GetLastError()==ERROR_FILE_NOT_FOUND)return c;
 }
 return 0;
}
static void command_letter(WCHAR letter){unsigned n=wlen(command);command[n]=letter;command[n+1]=':';command[n+2]=0;}
static int map_source(unsigned index,WCHAR letter){
 if(start_driver())return 1;
 wcopy(path,base);append(path,L"imdisk.exe");
 command[0]=0;append(command,L"\"");append(command,path);append(command,L"\" -a -t file -o ro -f \\\\.\\PhysicalDrive");append_num(command,index);
 append(command,L" -b ");append_num(command,offset);append(command,L" -s ");append_num(command,length);
 append(command,L" -m ");command_letter(letter);
 if(mapper())return 1;
 if(!iso_mode){output("WORK mounted read-only; verify ownership before Setup.\r\n");return 0;}
 WCHAR image[520];image[0]=letter;image[1]=':';image[2]='\\';image[3]=0;append(image,iso_path);
 HANDLE h=CreateFileW(image,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);
 if(h==INVALID_HANDLE_VALUE)return error("selected ISO could not be opened on DATA");
 LARGE_INTEGER size;int ok=GetFileSizeEx(h,&size)&&(uint64_t)size.QuadPart==iso_size;CloseHandle(h);
 if(!ok)return error("selected ISO size changed; return to the USOS menu");
 WCHAR cd=free_letter();if(!cd)return error("no free letter for the selected ISO");
 wcopy(path,base);append(path,L"imdisk.exe");
 command[0]=0;append(command,L"\"");append(command,path);append(command,L"\" -a -t file -o ro,cd -f \"");append(command,image);append(command,L"\" -m ");command_letter(cd);
 if(mapper())return 1;
 wcopy(path,base);append(path,L"usos-iso-drive.txt");
 h=CreateFileW(path,GENERIC_WRITE,FILE_SHARE_READ,0,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
 if(h==INVALID_HANDLE_VALUE)return error("cannot save source letter beside helper");
 char result[4]={(char)cd,':','\r','\n'};DWORD written=0;ok=WriteFile(h,result,4,&written,0)&&written==4;CloseHandle(h);
 if(!ok)return error("cannot save source letter");
 output("SELECTED ISO MOUNTED READ-ONLY; STARTING ORIGINAL SETUP\r\n");return 0;
}
static WCHAR argbuf[2048];
static int arguments(WCHAR **args){
 const WCHAR *s=GetCommandLineW();unsigned n=0,at=0;
 while(*s){while(*s==' '||*s=='\t')s++;if(!*s)break;if(n==4)return 0;args[n++]=argbuf+at;int quote=0;
  while(*s&&(quote||(*s!=' '&&*s!='\t'))){if(*s=='"'){quote=!quote;s++;continue;}if(at>=2046)return 0;argbuf[at++]=*s++;}if(quote)return 0;argbuf[at++]=0;
 }return n;
}
static int same(const WCHAR *a,const WCHAR *b){while(*a&&*a==*b){a++;b++;}return *a==*b;}
/* Only the ESP on the already GPT-validated source disk may receive logs.
 * Query the actual Windows partition mapping and verify its GUID and range. */
static int log_root(unsigned index){
 const BYTE esp[16]={0x28,0x73,0x2a,0xc1,0x1f,0xf8,0xd2,0x11,0xba,0x4b,0,0xa0,0xc9,0x3e,0xc9,0x3b};
 wcopy(path,L"\\\\.\\PhysicalDrive");append_num(path,index);
 disk=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_EXISTING,0,0);
 if(disk==INVALID_HANDLE_VALUE)return error("cannot reopen source for logging identity");
 int valid=inspect();CloseHandle(disk);if(!valid)return error("source identity changed before logging");
 unsigned count=u32(header+80),stride=u32(header+84),found=0;BYTE identity[16];uint64_t start=0,size=0;
 for(unsigned i=0;i<count;i++)if(equal(entries+i*stride,esp,16)){
  BYTE *p=entries+i*stride;uint64_t first=u64(p+32),last=u64(p+40);
  if(first<u64(header+40)||last>u64(header+48)||first>last)return error("invalid log ESP range");
  for(unsigned j=0;j<16;j++)identity[j]=p[16+j];start=first*sector;size=(last-first+1)*sector;found++;
 }
 if(found!=1)return error("logging requires one ESP on the source disk");
 WCHAR volume[MAX_PATH];found=0;
 for(unsigned i=1;i<=128;i++){
  wcopy(path,L"\\\\?\\GLOBALROOT\\Device\\Harddisk");append_num(path,index);append(path,L"\\Partition");append_num(path,i);
  HANDLE h=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_EXISTING,0,0);if(h==INVALID_HANDLE_VALUE)continue;
  PARTITION_INFORMATION_EX part;DWORD bytes=0;
  int ok=DeviceIoControl(h,IOCTL_DISK_GET_PARTITION_INFO_EX,0,0,&part,sizeof(part),&bytes,0);CloseHandle(h);
  if(ok&&bytes>=sizeof(part)&&part.PartitionStyle==PARTITION_STYLE_GPT&&equal(&part.Gpt.PartitionId,identity,16)&&equal(&part.Gpt.PartitionType,esp,16)&&
     (uint64_t)part.StartingOffset.QuadPart==start&&(uint64_t)part.PartitionLength.QuadPart==size){wcopy(volume,path);found++;}
 }
 if(found!=1)return error("cannot resolve verified source ESP volume");
 append(volume,L"\\EFI\\USOS");if(GetFileAttributesW(volume)==INVALID_FILE_ATTRIBUTES)return error("source ESP lacks USOS directory");
 append(volume,L"\\Logs");if(!CreateDirectoryW(volume,0)&&GetLastError()!=ERROR_ALREADY_EXISTS)return error("cannot create USB log directory");
 SYSTEMTIME time;GetSystemTime(&time);
 append(volume,L"\\WinSetup-");append_num(volume,time.wYear);append(volume,L"-");append_num(volume,time.wMonth);append(volume,L"-");append_num(volume,time.wDay);
 append(volume,L"-");append_num(volume,time.wHour);append(volume,L"-");append_num(volume,time.wMinute);append(volume,L"-");append_num(volume,time.wSecond);
 append(volume,L"-");append_num(volume,GetCurrentProcessId());
 if(!CreateDirectoryW(volume,0))return error("cannot create unique USB log session");
 for(unsigned i=0;volume[i];i++){char ch[2]={(char)volume[i],0};output(ch);}output("\r\n");return 0;
}
static int run(void){
 WCHAR *args[4];int argc=arguments(args);
 if(argc==3&&same(args[1],L"--inspect-config")){
  if(args[2][0]=='\\')return error("invalid fixture path");
  HANDLE h=CreateFileW(args[2],GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(h==INVALID_HANDLE_VALUE)return error("cannot read fixture");
  BYTE b[1024];DWORD n=0;int ok=ReadFile(h,b,sizeof(b),&n,0)&&n<sizeof(b)&&parse_config(b,n);CloseHandle(h);
  if(!ok)return error("configuration rejected");output("PASS configuration\r\n");return 0;
 }
 /* Offline parser validation never loads a driver or opens devices for write. */
 if(argc==4&&same(args[1],L"--inspect")){
  if(args[2][0]=='\\'||!guid(args[3]))return error("invalid offline fixture arguments");
  disk=CreateFileW(args[2],GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(disk==INVALID_HANDLE_VALUE)return error("cannot read fixture");
  LARGE_INTEGER size;int ok=GetFileSizeEx(disk,&size);disk_size=ok?(uint64_t)size.QuadPart:0;sector=512;ok=ok&&inspect();CloseHandle(disk);
  if(!ok)return error("fixture rejected");output("PASS offset=");number(offset);output(" length=");number(length);output("\r\n");return 0;
 }
 int identify_only=argc==2&&same(args[1],L"--source-disk");
 int logs_only=argc==2&&same(args[1],L"--log-root");
 if(argc!=1&&!identify_only&&!logs_only)return error("unexpected arguments");
 HKEY key;if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SYSTEM\\CurrentControlSet\\Control\\MiniNT",0,KEY_READ,&key)!=ERROR_SUCCESS)return error("mounting is restricted to WinPE");RegCloseKey(key);
 unsigned n=GetModuleFileNameW(0,base,MAX_PATH);if(!n||n>=MAX_PATH-32)return error("invalid executable path");while(n&&base[n-1]!='\\')n--;base[n]=0;
 if(!n||!source_config())return error("missing or invalid source identity");
 unsigned found=0,selected=0;uint64_t selected_offset=0,selected_length=0;
 for(unsigned i=0;i<64;i++){
  wcopy(path,L"\\\\.\\PhysicalDrive");append_num(path,i);
  disk=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_EXISTING,0,0);if(disk==INVALID_HANDLE_VALUE)continue;
  STORAGE_PROPERTY_QUERY query;BYTE *z=(BYTE*)&query;for(unsigned j=0;j<sizeof(query);j++)z[j]=0;query.PropertyId=StorageDeviceProperty;query.QueryType=PropertyStandardQuery;
  DWORD got=0;DISK_GEOMETRY geo;GET_LENGTH_INFORMATION size;
  int ok=DeviceIoControl(disk,IOCTL_STORAGE_QUERY_PROPERTY,&query,sizeof(query),other,sizeof(other),&got,0)&&got>=sizeof(STORAGE_DEVICE_DESCRIPTOR)&&(iso_mode||((STORAGE_DEVICE_DESCRIPTOR*)other)->BusType==BusTypeUsb);
  ok=ok&&DeviceIoControl(disk,IOCTL_DISK_GET_DRIVE_GEOMETRY,0,0,&geo,sizeof(geo),&got,0)&&DeviceIoControl(disk,IOCTL_DISK_GET_LENGTH_INFO,0,0,&size,sizeof(size),&got,0);
  if(ok){sector=geo.BytesPerSector;disk_size=(uint64_t)size.Length.QuadPart;if(inspect()){found++;selected=i;selected_offset=offset;selected_length=length;}}
  CloseHandle(disk);
 }
 if(found!=1)return error(found?"ambiguous source identity; stopped":"expected source partition not found");
 /* Resolve the same guarded GPT identity without mapping a volume. Windows
  * Setup's answer file can then reject this physical disk as its target. */
 if(identify_only){number(selected);output("\r\n");return 0;}
 if(logs_only){
  wcopy(path,L"\\\\.\\PhysicalDrive");append_num(path,selected);
  disk=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_EXISTING,0,0);
  DISK_GEOMETRY geo;GET_LENGTH_INFORMATION bytes;DWORD got=0;
  int ok=disk!=INVALID_HANDLE_VALUE&&DeviceIoControl(disk,IOCTL_DISK_GET_DRIVE_GEOMETRY,0,0,&geo,sizeof(geo),&got,0)&&DeviceIoControl(disk,IOCTL_DISK_GET_LENGTH_INFO,0,0,&bytes,sizeof(bytes),&got,0);
  if(disk!=INVALID_HANDLE_VALUE)CloseHandle(disk);if(!ok)return error("cannot read logging source geometry");
  sector=geo.BytesPerSector;disk_size=(uint64_t)bytes.Length.QuadPart;return log_root(selected);
 }
 offset=selected_offset;length=selected_length;
 WCHAR letter=free_letter();
 if(!letter)return error("no free drive letter");
 return map_source(selected,letter);
}
void entry(void){ExitProcess(run());}
