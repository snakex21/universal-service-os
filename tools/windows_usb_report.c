/* Read-only inventory: detect real xHCI device state without vendor/board rules. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <cfgmgr32.h>
void *memset(void *p,int value,size_t count){volatile BYTE *b=p;while(count--)*b++=(BYTE)value;return p;}
static void say(const char *s){DWORD n=0,w;while(s[n])n++;WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),s,n,&w,0);}
static void number(ULONG value){char digits[11];unsigned n=0;do{digits[n++]=(char)('0'+value%10);value/=10;}while(value);while(n){char ch[2]={digits[--n],0};say(ch);}}
static void text(const WCHAR *s){static char buffer[4096];int n=WideCharToMultiByte(CP_UTF8,0,s,-1,buffer,sizeof(buffer),0,0);if(n>0)say(buffer);}
static int contains(const WCHAR *text,const WCHAR *part){
 for(;*text;text++){unsigned i=0;for(;part[i];i++){WCHAR a=text[i],b=part[i];if(a>='a'&&a<='z')a-=32;if(b>='a'&&b<='z')b-=32;if(!a||a!=b)break;}if(!part[i])return 1;}return 0;
}
void entry(void){
 HKEY key;if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SYSTEM\\CurrentControlSet\\Control\\MiniNT",0,KEY_READ,&key)!=ERROR_SUCCESS)ExitProcess(2);RegCloseKey(key);
 WCHAR file[MAX_PATH];unsigned n=GetSystemDirectoryW(file,MAX_PATH);const WCHAR *tail=L"\\drivers\\USBXHCI.SYS";
 if(n&&n<MAX_PATH-32){unsigned i=0;while((file[n+i]=tail[i]))i++;say(GetFileAttributesW(file)!=INVALID_FILE_ATTRIBUTES?"WinPE: USBXHCI.SYS present; device status below determines usability.\r\n":"WinPE: USBXHCI.SYS absent; third-party packages may provide support.\r\n");}
 HDEVINFO set=SetupDiGetClassDevsW(0,L"PCI",0,DIGCF_PRESENT|DIGCF_ALLCLASSES);if(set==INVALID_HANDLE_VALUE)ExitProcess(2);
 unsigned found=0,missing=0;SP_DEVINFO_DATA device;device.cbSize=sizeof(device);
 for(DWORD i=0;SetupDiEnumDeviceInfo(set,i,&device);i++){
  static WCHAR ids[4096];memset(ids,0,sizeof(ids));DWORD type=0,bytes=0;
  if(!SetupDiGetDeviceRegistryPropertyW(set,&device,SPDRP_COMPATIBLEIDS,&type,(BYTE*)ids,sizeof(ids)-sizeof(WCHAR),&bytes)||type!=REG_MULTI_SZ)continue;
  int xhci=0;for(WCHAR *s=ids;*s;){if(contains(s,L"CC_0C0330"))xhci=1;while(*s)s++;s++;}
  if(!xhci)continue;found++;
  static WCHAR id[512],service[512];memset(id,0,sizeof(id));memset(service,0,sizeof(service));SetupDiGetDeviceInstanceIdW(set,&device,id,512,0);
  SetupDiGetDeviceRegistryPropertyW(set,&device,SPDRP_SERVICE,0,(BYTE*)service,sizeof(service)-sizeof(WCHAR),0);
  ULONG status=0,problem=0;int started=CM_Get_DevNode_Status(&status,&problem,device.DevInst,0)==CR_SUCCESS&&(status&DN_STARTED)&&!(status&DN_HAS_PROBLEM);
  say(started?"USB3 READY: ":"USB3 NOT STARTED: ");text(id);say(" service=");text(service);say(" problem=");number(problem);say("\r\n");if(!started)missing++;
 }
 SetupDiDestroyDeviceInfoList(set);
 if(!found)say("No PCI xHCI controller detected; other USB controller types are unaffected.\r\n");
 say("This report describes the running installer, not the drivers inside install.wim/install.esd.\r\n");
 ExitProcess(missing?3:0);
}
