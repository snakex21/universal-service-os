/* Owned NT31 VM fixture configurator. Required OS service configuration only;
 * all application output stays beside this EXE. Never edits other services. */
#include <windows.h>
void *__cdecl memcpy(void *d,const void *s,unsigned int n){volatile BYTE *to=d;const volatile BYTE *from=s;while(n--)*to++=*from++;return d;}
static HANDLE logFile=INVALID_HANDLE_VALUE;
static DWORD length(const char *s){DWORD n=0;while(s[n])n++;return n;}
static int same(const char *a,const char *b){char x,y;do{x=*a++;y=*b++;if(x>='a'&&x<='z')x-=32;if(y>='a'&&y<='z')y-=32;if(x!=y)return 0;}while(x);return 1;}
static int starts(const char *a,const char *b){char x,y;while(*b){x=*a++;y=*b++;if(x>='a'&&x<='z')x-=32;if(y>='a'&&y<='z')y-=32;if(x!=y)return 0;}return 1;}
static void text(const char *s){DWORD n;if(logFile!=INVALID_HANDLE_VALUE)WriteFile(logFile,s,length(s),&n,NULL);}
static void number(DWORD v){char b[9];int i;for(i=0;i<8;i++)b[i]="0123456789ABCDEF"[(v>>(28-i*4))&15];b[8]=0;text(b);}
static void row(const char *s,DWORD v){text(s);text("=");number(v);text("\r\n");}
static LONG dword(HKEY h,const char *name,DWORD value){LONG r;DWORD read=0,kind=0,size=4;r=RegSetValueExA(h,name,0,REG_DWORD,(const BYTE *)&value,4);if(!r){r=RegQueryValueExA(h,name,NULL,&kind,(BYTE *)&read,&size);if(!r&&(kind!=REG_DWORD||size!=4||read!=value))r=ERROR_INVALID_DATA;}row(name,r);return r;}
static int existing(HKEY root,const char *name,HKEY *h){return RegOpenKeyExA(root,name,0,KEY_READ|KEY_WRITE,h)==ERROR_SUCCESS;}
void __cdecl entry(void)
{
    char path[512],marker[512],data[128],name[256],image[256];DWORD n,i,read,kind,bytes,v,instances=0,roots=0;HKEY services=NULL,driver=NULL,adapter=NULL,parameters=NULL;HANDLE f;LONG r;int configure=0;
    n=GetModuleFileNameA(NULL,path,sizeof(path));if(!n||n>=sizeof(path))ExitProcess(2);
    while(n && path[n-1]!='\\')n--;if(!n)ExitProcess(2);
    for(i=0;i<n;i++)marker[i]=path[i];for(i=0;"CFG31.LOG"[i];i++)path[n+i]="CFG31.LOG"[i];path[n+i]=0;
    logFile=CreateFileA(path,GENERIC_WRITE,FILE_SHARE_READ,NULL,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
    text("NT31 owned fixture configuration\r\n");v=GetVersion();row("GetVersion",v);
    if((v&255)!=3 || (((v>>8)&255)!=1 && ((v>>8)&255)!=10) || (v&0x80000000)){text("REFUSED_OS\r\n");goto refused;}
    for(i=0;"NET31.ON"[i];i++)marker[n+i]="NET31.ON"[i];marker[n+i]=0;
    f=CreateFileA(marker,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
    if(f==INVALID_HANDLE_VALUE){text("REFUSED_MARKER\r\n");goto refused;}
    read=0;ReadFile(f,data,sizeof(data)-1,&read,NULL);CloseHandle(f);data[read]=0;
    if(!same(data,"r24-nt31-intel-fullmac\r\n")){text("REFUSED_MARKER_CONTENT\r\n");goto refused;}
    if(!existing(HKEY_LOCAL_MACHINE,"SYSTEM\\CurrentControlSet\\Services",&services))goto refused;
    for(i=0;i<4096;i++){
        bytes=sizeof(name);r=RegEnumKeyExA(services,i,name,&bytes,NULL,NULL,NULL,NULL);
        if(r==ERROR_NO_MORE_ITEMS)break;if(r!=ERROR_SUCCESS)goto refused;
        if(!starts(name,"USOSNET31"))continue;
        if(same(name,"USOSNET31"))roots++;else if(same(name,"USOSNET311"))instances++;else{ text("REFUSED_OTHER_OWN_INSTANCE\r\n");goto refused;}
    }
    row("own_driver_count",roots);row("own_adapter_count",instances);
    if(i==4096 || roots!=1 || instances!=1){text("REFUSED_INSTANCE_SHAPE\r\n");goto refused;}
    if(!existing(services,"USOSNET31",&driver) || !existing(services,"USOSNET311",&adapter) || !existing(adapter,"Parameters",&parameters))goto refused;
    bytes=sizeof(image);kind=0;r=RegQueryValueExA(driver,"ImagePath",NULL,&kind,(BYTE *)image,&bytes);
    if(r || (kind!=REG_SZ&&kind!=REG_EXPAND_SZ) || !bytes || bytes>=sizeof(image) || image[bytes-1]!=0 ||
      (!same(image,"\\SystemRoot\\System32\\drivers\\USNET31.SYS")&&!same(image,"%SystemRoot%\\System32\\drivers\\USNET31.SYS"))){text("REFUSED_IMAGEPATH\r\n");goto refused;}
    path[n]=0;for(i=0;"USNET31.SYS"[i];i++)path[n+i]="USNET31.SYS"[i];path[n+i]=0;
    f=CreateFileA(path,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
    if(f==INVALID_HANDLE_VALUE){text("REFUSED_OWN_SOURCE_ABSENT\r\n");goto refused;}CloseHandle(f);
    { const char *cmd=GetCommandLineA();DWORD z=length(cmd);configure=z>=10 && same(cmd+z-10,"/configure"); }
    if(!configure){text("INSPECT_ONLY_READY\r\n");goto done;}
    /* NCPA created exactly this adapter. Set only its original bus fields and
     * the owned full-MAC's explicit BDF/debug parameters; no stack guesses. */
    if(dword(parameters,"BusType",5) || dword(parameters,"BusNumber",0) ||
       dword(parameters,"PciBus",0) || dword(parameters,"PciDevice",5) ||
       dword(parameters,"PciFunction",0) || dword(parameters,"DebugPort",233))goto refused;
    r=RegFlushKey(parameters);row("RegFlushKey",r);if(r)goto refused;text("CONFIGURED_REBOOT_REQUIRED\r\n");
done:
    if(parameters)RegCloseKey(parameters);if(adapter)RegCloseKey(adapter);if(driver)RegCloseKey(driver);if(services)RegCloseKey(services);
    if(logFile!=INVALID_HANDLE_VALUE)CloseHandle(logFile);ExitProcess(0);
refused:
    text("CONFIGURATION_REFUSED\r\n");if(parameters)RegCloseKey(parameters);if(adapter)RegCloseKey(adapter);if(driver)RegCloseKey(driver);if(services)RegCloseKey(services);
    if(logFile!=INVALID_HANDLE_VALUE)CloseHandle(logFile);ExitProcess(3);
}
