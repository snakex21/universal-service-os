/* Vista SP2 USB setup. Run before windeploy on the target OS.
 * Driver files and persistent diagnostics live beside this executable.
 */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0600
#include <windows.h>
#include <setupapi.h>
#include <newdev.h>
#include <cfgmgr32.h>
#include <wincrypt.h>
#ifdef USOS_VISTA_LOCAL_SIGNATURE
#include "vista_local_certs.h"
#define USOS_VISTA_INF L"Drivers\\LocalTestVista\\USBXHCI.inf"
#else
#include "vista_community_certs.h"
#define USOS_VISTA_INF L"Drivers\\GenericVista\\USBXHCI.inf"
#endif
static WCHAR base[MAX_PATH], host[MAX_PATH], hub[MAX_PATH];
static HANDLE log_file=INVALID_HANDLE_VALUE;
static DWORD first_error;
static WCHAR cpu_hardware_id[MAX_DEVICE_ID_LEN];
static DWORD ready_controllers, ready_mouse, ready_keyboard;
static void log_code(const char *message,DWORD code);
static void preserve_setup_logs(void){
 static WCHAR source[MAX_PATH],target[MAX_PATH];
 SetupCloseLog();
 const WCHAR *names[2]={L"setupapi.dev.log",L"setupapi.app.log"};
 for(unsigned i=0;i<2;i++){
  GetWindowsDirectoryW(source,MAX_PATH);lstrcatW(source,L"\\inf\\");lstrcatW(source,names[i]);
  lstrcpyW(target,base);lstrcatW(target,names[i]);
  BOOL copied=CopyFileW(source,target,FALSE);log_code("SetupAPI log snapshot=",copied?0:GetLastError());
  if(copied){
   HANDLE snapshot=CreateFileW(target,GENERIC_WRITE,FILE_SHARE_READ,0,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
   if(snapshot!=INVALID_HANDLE_VALUE){log_code("Flush SetupAPI snapshot=",FlushFileBuffers(snapshot)?0:GetLastError());CloseHandle(snapshot);}
   else log_code("Open snapshot for flush=",GetLastError());
  }
 }
}
static BOOL trust_community_certificates(void){
 /* The build pins either the original community chain or an explicitly local
  * self-signed test certificate. Never promote vendor leafs into root CAs. */
 BOOL ok=TRUE;
 for(unsigned i=0;i<sizeof(community_certs)/sizeof(community_certs[0]);i++){
  PCCERT_CONTEXT cert=CertCreateCertificateContext(X509_ASN_ENCODING|PKCS_7_ASN_ENCODING,community_certs[i].data,community_certs[i].length);
  if(!cert){first_error=GetLastError();log_code("Read community certificate=",first_error);return FALSE;}
  /* Use an explicit machine registry handle. Verify persistence independently
   * of the CryptoAPI store's in-memory readback; flush before starting a new
   * process that will open the logical system stores used by SetupAPI. */
  WCHAR keypath[180];HKEY key=0;
  lstrcpyW(keypath,L"SOFTWARE\\Microsoft\\SystemCertificates\\");lstrcatW(keypath,community_certs[i].store);
  LONG reg=RegCreateKeyExW(HKEY_LOCAL_MACHINE,keypath,0,0,REG_OPTION_NON_VOLATILE,KEY_ALL_ACCESS|KEY_WOW64_64KEY,0,&key,0);
  HCERTSTORE store=reg==ERROR_SUCCESS?CertOpenStore(CERT_STORE_PROV_REG,0,0,0,key):0;
  DWORD error=0;
  if(!store)error=reg!=ERROR_SUCCESS?(DWORD)reg:GetLastError();
  else {
   if(!CertAddCertificateContextToStore(store,cert,CERT_STORE_ADD_REPLACE_EXISTING,0))error=GetLastError();
   if(!error){
    PCCERT_CONTEXT found=CertFindCertificateInStore(store,X509_ASN_ENCODING|PKCS_7_ASN_ENCODING,0,CERT_FIND_EXISTING,cert,0);
    if(!found)error=GetLastError();else CertFreeCertificateContext(found);
   }
   if(!CertCloseStore(store,0)&&!error)error=GetLastError();
  }
  if(!error){
   BYTE sha1[20];DWORD bytes=sizeof(sha1);WCHAR certkey[80];lstrcpyW(certkey,L"Certificates\\");
   if(!CertGetCertificateContextProperty(cert,CERT_SHA1_HASH_PROP_ID,sha1,&bytes))error=GetLastError();
   else if(bytes!=20)error=ERROR_INVALID_DATA;
   else {
    unsigned at=lstrlenW(certkey);
    for(unsigned n=0;n<20;n++){certkey[at++]=L"0123456789ABCDEF"[sha1[n]>>4];certkey[at++]=L"0123456789ABCDEF"[sha1[n]&15];}certkey[at]=0;
    HKEY persisted=0;reg=RegOpenKeyExW(key,certkey,0,KEY_READ|KEY_WOW64_64KEY,&persisted);
    if(reg!=ERROR_SUCCESS)error=reg;
    else {
     static BYTE blob[16384];DWORD type=0,size=sizeof(blob);
     reg=RegQueryValueExW(persisted,L"Blob",0,&type,blob,&size);
     BOOL match=FALSE;
     if(reg==ERROR_SUCCESS&&type==REG_BINARY&&size>=cert->cbCertEncoded){
      for(DWORD n=0;n<=size-cert->cbCertEncoded;n++){
       DWORD j=0;while(j<cert->cbCertEncoded&&blob[n+j]==cert->pbCertEncoded[j])j++;
       if(j==cert->cbCertEncoded){match=TRUE;break;}
      }
     }
     if(!match)error=reg!=ERROR_SUCCESS?(DWORD)reg:ERROR_INVALID_DATA;
     RegCloseKey(persisted);
    }
   }
  }
  if(key){reg=RegFlushKey(key);if(!error&&reg!=ERROR_SUCCESS)error=reg;RegCloseKey(key);}
  log_code("Community certificate index=",i);log_code("Certificate install result=",error);
  if(error){if(!first_error)first_error=error;ok=FALSE;}
  CertFreeCertificateContext(cert);
 }
 return ok;
}
static BOOL verify_logical_certificates(void){
 BOOL ok=TRUE;
 for(unsigned i=0;i<sizeof(community_certs)/sizeof(community_certs[0]);i++){
  PCCERT_CONTEXT cert=CertCreateCertificateContext(X509_ASN_ENCODING|PKCS_7_ASN_ENCODING,community_certs[i].data,community_certs[i].length);
  DWORD error=cert?0:GetLastError();
  HCERTSTORE store=cert?CertOpenStore(CERT_STORE_PROV_SYSTEM_W,0,0,CERT_SYSTEM_STORE_LOCAL_MACHINE|CERT_STORE_READONLY_FLAG,community_certs[i].store):0;
  if(cert&&!store)error=GetLastError();
  if(store){
   PCCERT_CONTEXT found=CertFindCertificateInStore(store,X509_ASN_ENCODING|PKCS_7_ASN_ENCODING,0,CERT_FIND_EXISTING,cert,0);
   if(!found)error=GetLastError();else CertFreeCertificateContext(found);
   CertCloseStore(store,0);
  }
  if(cert)CertFreeCertificateContext(cert);
  log_code("Logical machine certificate index=",i);log_code("Logical store readback=",error);
  if(error){if(!first_error)first_error=error;ok=FALSE;}
 }
 return ok;
}
static WCHAR chipset_hardware_id[MAX_DEVICE_ID_LEN];
static BOOL prefix_id(const WCHAR *id,const WCHAR *prefix){
 while(*prefix){
  WCHAR a=*id++,b=*prefix++;
  if(a>=L'a'&&a<=L'z')a-=L'a'-L'A';
  if(b>=L'a'&&b<=L'z')b-=L'a'-L'A';
  if(a!=b)return FALSE;
 }return *id==0||*id==L'&';
}
/* Volatile stores keep this no-CRT executable independent of memset. */
static void clear_struct(void *object,SIZE_T size){
 volatile BYTE *bytes=(volatile BYTE*)object;while(size--)*bytes++=0;
}
static void log_code(const char *message,DWORD code){
 char hex[13]="0x00000000\r\n";DWORD n;
 for(unsigned i=0;i<8;i++)hex[9-i]="0123456789abcdef"[(code>>(i*4))&15];
 WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),message,lstrlenA(message),&n,0);WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),hex,12,&n,0);
 if(log_file!=INVALID_HANDLE_VALUE){
  BOOL a=WriteFile(log_file,message,lstrlenA(message),&n,0);
  BOOL b=WriteFile(log_file,hex,12,&n,0);
  if(!a||!b||!FlushFileBuffers(log_file)){
   static const char failed[]="USOS: writing diagnostic log failed.\r\n";
   WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),failed,sizeof(failed)-1,&n,0);
  }
 }
}
static BOOL path(WCHAR *out,const WCHAR *suffix){
 if(lstrlenW(base)+lstrlenW(suffix)>=MAX_PATH)return FALSE;
 lstrcpyW(out,base);lstrcatW(out,suffix);return TRUE;
}
static BOOL stage(const WCHAR *inf,const char *label){
 log_code("Beginning stage at uptime(ms)=",GetTickCount());log_code(label,ERROR_IO_PENDING);
 BOOL ok=SetupCopyOEMInfW(inf,0,SPOST_PATH,0,0,0,0,0);
 DWORD error=ok?0:GetLastError();log_code(label,error);if(!ok&&!first_error)first_error=error;return ok;
}
static BOOL install_direct(HDEVINFO devices,SP_DEVINFO_DATA *dev,const WCHAR *inf,BOOL *restart){
 SP_DEVINSTALL_PARAMS_W params;BOOL built=FALSE,ok=FALSE;
 clear_struct(&params,sizeof(params));params.cbSize=sizeof(params);
 static WCHAR instance[MAX_DEVICE_ID_LEN];static char text[800];DWORD written;
 if(SetupDiGetDeviceInstanceIdW(devices,dev,instance,MAX_DEVICE_ID_LEN,0)){
  int n=WideCharToMultiByte(CP_UTF8,0,instance,-1,text,sizeof(text)-2,0,0);
  if(n>0){text[n-1]='\r';text[n]='\n';WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),text,n+1,&written,0);
   if(log_file!=INVALID_HANDLE_VALUE){WriteFile(log_file,text,n+1,&written,0);FlushFileBuffers(log_file);}}
 }
 const char *step="Get device install parameters=";
 if(!SetupDiGetDeviceInstallParamsW(devices,dev,&params))goto done;
 params.Flags|=DI_QUIETINSTALL;
 params.FlagsEx&=~DI_FLAGSEX_SETFAILEDINSTALL;
 params.FlagsEx|=DI_FLAGSEX_ALLOWEXCLUDEDDRVS;
 if(inf){params.Flags|=DI_ENUMSINGLEINF;lstrcpyW(params.DriverPath,inf);}
 else {params.Flags&=~DI_ENUMSINGLEINF;params.DriverPath[0]=0;}
 step="Set device install parameters=";
 if(!SetupDiSetDeviceInstallParamsW(devices,dev,&params))goto done;
 step="Build compatible driver list=";
 if(!SetupDiBuildDriverInfoList(devices,dev,SPDIT_COMPATDRIVER))goto done;
 built=TRUE;step="Select compatible driver=";
 if(!SetupDiCallClassInstaller(DIF_SELECTBESTCOMPATDRV,devices,dev))goto done;
 /* Never allow a NULL-driver install to masquerade as success. */
 SP_DRVINFO_DATA_W selected;clear_struct(&selected,sizeof(selected));selected.cbSize=sizeof(selected);
 step="Read selected compatible driver=";
 if(!SetupDiGetSelectedDriverW(devices,dev,&selected))goto done;
 step="Register driver coinstallers=";
 if(!SetupDiCallClassInstaller(DIF_REGISTER_COINSTALLERS,devices,dev))goto done;
 step="Install device interfaces=";
 if(!SetupDiCallClassInstaller(DIF_INSTALLINTERFACES,devices,dev))goto done;
 step="Direct DIF_INSTALLDEVICE=";
 if(!SetupDiCallClassInstaller(DIF_INSTALLDEVICE,devices,dev))goto done;
 ok=TRUE;log_code(step,0);
 if(SetupDiGetDeviceInstallParamsW(devices,dev,&params)){
  log_code("Device installation flags=",params.Flags);
  if(params.Flags&(DI_NEEDREBOOT|DI_NEEDRESTART))*restart=TRUE;
 }
done:
 if(!ok){DWORD error=GetLastError();if(!error)error=ERROR_GEN_FAILURE;log_code(step,error);if(!first_error)first_error=error;}
 if(built)SetupDiDestroyDriverInfoList(devices,dev,SPDIT_COMPATDRIVER);
 return ok;
}
static BOOL target_controller(HDEVINFO devices,SP_DEVINFO_DATA *dev){
 static WCHAR ids[4096];DWORD type;
 if(!SetupDiGetDeviceRegistryPropertyW(devices,dev,SPDRP_HARDWAREID,&type,(BYTE*)ids,sizeof(ids),0))return FALSE;
 for(WCHAR *id=ids;*id;id+=lstrlenW(id)+1)
  if(prefix_id(id,L"PCI\\VEN_1022&DEV_43D0")||prefix_id(id,L"PCI\\VEN_1022&DEV_149C"))return TRUE;
 return FALSE;
}
static BOOL target_descendant(DEVINST node,const DEVINST *controllers,DWORD count){
 for(unsigned depth=0;depth<24;depth++){
  DEVINST parent;if(CM_Get_Parent(&parent,node,0)!=CR_SUCCESS)return FALSE;
  for(DWORD i=0;i<count;i++)if(parent==controllers[i])return TRUE;
  if(parent==node)return FALSE;node=parent;
 }return FALSE;
}
/* Only hubs and input/composite devices below the two identified AMD hosts.
 * 1 uses the pinned USB3 INF; 2 selects a compatible installed/inbox driver. */
static unsigned input_child_kind(HDEVINFO devices,SP_DEVINFO_DATA *dev){
 static WCHAR ids[4096];DWORD type;BOOL input=FALSE;
 for(unsigned p=0;p<2;p++){
  if(!SetupDiGetDeviceRegistryPropertyW(devices,dev,p?SPDRP_COMPATIBLEIDS:SPDRP_HARDWAREID,&type,(BYTE*)ids,sizeof(ids),0))continue;
  for(WCHAR *id=ids;*id;id+=lstrlenW(id)+1){
   if(lstrcmpiW(id,L"USB\\ROOT_HUB30")==0||lstrcmpiW(id,L"USB\\USB30_HUB")==0||lstrcmpiW(id,L"USB\\USB20_HUB")==0)return 1;
   if(prefix_id(id,L"USB\\Class_03")||lstrcmpiW(id,L"USB\\COMPOSITE")==0||
      (id[0]==L'H'&&id[1]==L'I'&&id[2]==L'D'&&id[3]==L'\\'))input=TRUE;
  }
 }return input?2:0;
}
static BOOL install_usb_tree(BOOL *restart){
 HDEVINFO devices=SetupDiGetClassDevsW(0,0,0,DIGCF_ALLCLASSES|DIGCF_PRESENT);
 if(devices==INVALID_HANDLE_VALUE){first_error=GetLastError();return FALSE;}
 DEVINST controllers[8];DWORD count=0,attempts=0;BOOL ok=TRUE;
 SP_DEVINFO_DATA dev={sizeof(dev)};
 for(DWORD i=0;SetupDiEnumDeviceInfo(devices,i,&dev);i++)
  if(target_controller(devices,&dev)&&count<8)controllers[count++]=dev.DevInst;
 for(DWORD i=0;SetupDiEnumDeviceInfo(devices,i,&dev);i++){
  BOOL controller=target_controller(devices,&dev);
  unsigned kind=controller?1:(target_descendant(dev.DevInst,controllers,count)?input_child_kind(devices,&dev):0);
  if(!kind)continue;
  ULONG status=0,problem=0;
  CONFIGRET cr=CM_Get_DevNode_Status(&status,&problem,dev.DevInst,0);
  log_code("USB/input node status=",status);log_code("USB/input node problem=",problem);
  if(cr!=CR_SUCCESS){log_code("USB/input node query failed=",cr);continue;}
  if(!problem&&(status&DN_STARTED))continue;
  /* A load/start error after installation is evidence to inspect, not a reason
   * to reinstall the same package repeatedly. */
  if(problem!=CM_PROB_FAILED_INSTALL&&problem!=CM_PROB_NOT_CONFIGURED)continue;
  attempts++;if(!install_direct(devices,&dev,kind==1?host:0,restart)){ok=FALSE;break;}
 }
 log_code("Direct device installations attempted=",attempts);
 SetupDiDestroyDeviceInfoList(devices);return ok;
}
static void report_devices(void){
 ready_controllers=ready_mouse=ready_keyboard=0;
 HDEVINFO devices=SetupDiGetClassDevsW(0,0,0,DIGCF_ALLCLASSES|DIGCF_PRESENT);
 if(devices==INVALID_HANDLE_VALUE){log_code("Enumerate devices=",GetLastError());return;}
 SP_DEVINFO_DATA dev={sizeof(dev)};static WCHAR ids[4096];
 for(DWORD i=0;SetupDiEnumDeviceInfo(devices,i,&dev);i++){
  DWORD type=0;
  if(!SetupDiGetDeviceRegistryPropertyW(devices,&dev,SPDRP_HARDWAREID,&type,(BYTE*)ids,sizeof(ids),0))continue;
  BOOL chipset=FALSE,cpu=FALSE,hubdev=FALSE;
  for(WCHAR *id=ids;*id;id+=lstrlenW(id)+1){
   if(prefix_id(id,L"PCI\\VEN_1022&DEV_43D0")){
    chipset=TRUE;
    if(!chipset_hardware_id[0]&&lstrlenW(id)<MAX_DEVICE_ID_LEN)lstrcpyW(chipset_hardware_id,id);
   }
   if(prefix_id(id,L"PCI\\VEN_1022&DEV_149C")){
    cpu=TRUE;
    if(!cpu_hardware_id[0]&&lstrlenW(id)<MAX_DEVICE_ID_LEN)lstrcpyW(cpu_hardware_id,id);
   }
   if(lstrcmpiW(id,L"USB\\AMDROOT_HUB31&VID1022&PID43D0&VER0001000000050003")==0)hubdev=TRUE;
  }
  if(prefix_id(ids,L"HID\\VID_" ) || (ids[0]==L'H'&&ids[1]==L'I'&&ids[2]==L'D'&&ids[3]==L'\\')){
   static WCHAR device_class[80];ULONG status=0,problem=0;
   if(SetupDiGetDeviceRegistryPropertyW(devices,&dev,SPDRP_CLASS,&type,(BYTE*)device_class,sizeof(device_class),0)&&
      CM_Get_DevNode_Status(&status,&problem,dev.DevInst,0)==CR_SUCCESS&&!problem&&(status&DN_STARTED)){
    if(lstrcmpiW(device_class,L"Mouse")==0)ready_mouse++;
    if(lstrcmpiW(device_class,L"Keyboard")==0)ready_keyboard++;
   }
  }
  /* PCI short IDs can be in CompatibleIDs rather than HardwareID. */
  if(!chipset&&!cpu&&!hubdev){
   if(!SetupDiGetDeviceRegistryPropertyW(devices,&dev,SPDRP_COMPATIBLEIDS,&type,(BYTE*)ids,sizeof(ids),0))continue;
   for(WCHAR *id=ids;*id;id+=lstrlenW(id)+1){
    if(lstrcmpiW(id,L"PCI\\VEN_1022&DEV_43D0")==0)chipset=TRUE;
    if(lstrcmpiW(id,L"PCI\\VEN_1022&DEV_149C")==0)cpu=TRUE;
   }
  }
  if(chipset||cpu||hubdev){ULONG status=0,problem=0;CONFIGRET cr=CM_Get_DevNode_Status(&status,&problem,dev.DevInst,0);
   log_code(chipset?"43D0 status=":cpu?"149C status=":"AMD hub status=",status);
   log_code("Device problem code=",problem);log_code("Device query result=",cr);
   if((chipset||cpu)&&cr==CR_SUCCESS&&!problem&&(status&DN_STARTED))ready_controllers++;
  }
 }
 SetupDiDestroyDeviceInfoList(devices);
 log_code("Started USB controllers=",ready_controllers);
 log_code("Started HID mice=",ready_mouse);log_code("Started HID keyboards=",ready_keyboard);
}
static void scan(void){DEVINST root;CONFIGRET cr=CM_Locate_DevNodeW(&root,0,CM_LOCATE_DEVNODE_NORMAL);if(cr==CR_SUCCESS)cr=CM_Reenumerate_DevNode(root,CM_REENUMERATE_SYNCHRONOUS);log_code("PnP rescan=",cr);}
void entry(void){
 static OSVERSIONINFOW version={sizeof(version)};
 if(!GetVersionExW(&version)||version.dwMajorVersion!=6||version.dwMinorVersion!=0||version.dwBuildNumber!=6002)ExitProcess(2);
 DWORD length=GetModuleFileNameW(0,base,MAX_PATH);if(!length||length>=MAX_PATH)ExitProcess(3);
 while(length&&base[length-1]!=L'\\')length--;base[length]=0;
 static WCHAR logfile[MAX_PATH];
 if(!path(logfile,L"firstboot-usb.log")||!path(host,USOS_VISTA_INF))ExitProcess(3);
 log_file=CreateFileW(logfile,GENERIC_WRITE,FILE_SHARE_READ,0,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_WRITE_THROUGH,0);
 if(log_file!=INVALID_HANDLE_VALUE)SetFilePointer(log_file,0,0,FILE_END);
 #ifdef USOS_VISTA_LOCAL_SIGNATURE
 log_code("V10 LOCAL TEST CATALOG - distinct CA and publisher=",0);
 #endif
 #ifdef USOS_CERT_PREPARE_ONLY
 log_code("Vista USB v8 persist machine trust before SetupAPI, build=",version.dwBuildNumber);
 BOOL trusted=trust_community_certificates();CloseHandle(log_file);ExitProcess(trusted?0:first_error);
 #else
 log_code("V11 direct pre-Setup USB device installation=",0);
 log_code("Vista pre-Setup USB v8 fresh-process trust readback, build=",version.dwBuildNumber);
 if(!verify_logical_certificates()){CloseHandle(log_file);ExitProcess(first_error);}
 log_code("Open SetupAPI diagnostic log=",SetupOpenLog(FALSE)?0:GetLastError());
 log_code("Previous SetupAPI non-interactive flag=",SetupSetNonInteractiveMode(TRUE));
 log_code("Current SetupAPI non-interactive flag=",SetupGetNonInteractiveMode());
 report_devices();
 BOOL restart=FALSE;
 if(stage(host,"Stage community USB3=")){
  /* Newdev deferred these installs as "too early" while Setup waited for USB.
   * Use the DIF installation sequence, then discover hubs and HID children. */
  for(unsigned attempt=0;attempt<8;attempt++){
   if(!install_usb_tree(&restart))break;
   scan();
   report_devices();
   if((ready_controllers&&ready_mouse&&ready_keyboard)||restart)break;
   Sleep(500);
  }
 }
 report_devices();log_code("Firstboot finished; first error=",first_error);log_code("Reboot requested=",restart);
 preserve_setup_logs();
 CloseHandle(log_file);
 /* A copied INF is not proof that input devices started. */
 ExitProcess(ready_controllers&&ready_mouse&&ready_keyboard?0:
             (first_error?first_error:(restart?ERROR_SUCCESS_REBOOT_REQUIRED:ERROR_NOT_READY)));
 #endif
}
