/* USOS LAN first desktop step, GPL-3.0-or-later.
 * No CRT, console, network traffic, restart or waiting. All private data live
 * beside this executable. The requested Favorites and OS settings are the
 * only writes outside that directory. NDIS/IRQ configuration is untouched.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <cpuid.h>
int memcmp(const void *,const void *,size_t);

void *memset(void *p,int v,size_t n){volatile BYTE *b=p;while(n--)*b++=(BYTE)v;return p;}
void *memcpy(void *d,const void *s,size_t n){volatile BYTE *a=d;const BYTE *b=s;while(n--)*a++=*b++;return d;}
static char dir[MAX_PATH],ini[MAX_PATH],path[MAX_PATH],home[201],system_id[8];
static HANDLE log_handle=INVALID_HANDLE_VALUE;
static unsigned failures;
static DWORD len(const char *s){DWORD n=0;while(s[n])n++;return n;}
static int eq(const char *a,const char *b){return lstrcmpiA(a,b)==0;}
static void copy(char *d,const char *s){lstrcpynA(d,s,MAX_PATH);}
static void cat(char *d,const char *s){if(len(d)+len(s)<MAX_PATH)lstrcatA(d,s);else failures++;}
static void local(char *d,const char *name){copy(d,dir);cat(d,name);}
static void log_line(const char *s){DWORD w;WriteFile(log_handle,s,len(s),&w,0);WriteFile(log_handle,"\r\n",2,&w,0);FlushFileBuffers(log_handle);}
static void result(const char *name,LONG r){if(r!=ERROR_SUCCESS){failures++;log_line(name);}}
static int query(HKEY root,const char *key,const char *name,char *out,DWORD cap){HKEY k;DWORD n=cap-1,t;LONG r;
  if(RegOpenKeyExA(root,key,0,KEY_QUERY_VALUE,&k))return 0;
  r=RegQueryValueExA(k,name,0,&t,(BYTE*)out,&n);RegCloseKey(k);
  if(r||n>=cap||(t!=REG_SZ&&t!=REG_EXPAND_SZ))return 0;out[n]=0;return out[0]!=0;}
static void set(HKEY root,const char *key,const char *name,DWORD type,const void *data,DWORD size){HKEY k;DWORD disp;LONG r;
  r=RegCreateKeyExA(root,key,0,0,0,KEY_SET_VALUE,0,&k,&disp);
  if(!r){r=RegSetValueExA(k,name,0,type,data,size);RegCloseKey(k);}result("registry write failed; retained for retry",r);}
static const char *internet="Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
static const char *wizard="Software\\Microsoft\\Internet Connection Wizard";
static const char *main_key="Software\\Microsoft\\Internet Explorer\\Main";
static const char *run="Software\\Microsoft\\Windows\\CurrentVersion\\Run";
static void ie(HKEY root){DWORD zero=0,one=1;
  set(root,internet,"EnableAutodial",REG_DWORD,&zero,4);
  set(root,internet,"NoNetAutodial",REG_DWORD,&one,4);
  set(root,internet,"ProxyEnable",REG_DWORD,&zero,4);
  set(root,internet,"GlobalUserOffline",REG_DWORD,&zero,4);
  set(root,wizard,"Completed",REG_BINARY,&one,4);
  set(root,main_key,"Start Page",REG_SZ,home,len(home)+1);}
static int favorite(const char *folder){char file[MAX_PATH];HANDLE f;DWORD wrote;
  static const char data[]="[InternetShortcut]\r\nURL=http://68k.news\r\n";
  copy(file,folder);if(GetFileAttributesA(file)==INVALID_FILE_ATTRIBUTES&&!CreateDirectoryA(file,0))return 0;
  cat(file,"\\68k news.URL");
  /* Preserve an existing user-owned favorite, including a changed URL. */
  f=CreateFileA(file,GENERIC_WRITE,FILE_SHARE_READ,0,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,0);
  if(f==INVALID_HANDLE_VALUE)return GetLastError()==ERROR_FILE_EXISTS;
  if(!WriteFile(f,data,sizeof(data)-1,&wrote,0)||wrote!=sizeof(data)-1){CloseHandle(f);return 0;}
  FlushFileBuffers(f);CloseHandle(f);return 1;}
static int user_favorite(HKEY root){char folder[MAX_PATH],expanded[MAX_PATH];
  if(!query(root,"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Shell Folders","Favorites",folder,sizeof(folder)))return 0;
  if(!ExpandEnvironmentStringsA(folder,expanded,sizeof(expanded)))return 0;
  return favorite(expanded);}

#ifdef USOS_LAN_NT
/* Same Default User lookup as the existing usos-reg tool, using ANSI APIs
 * supported by NT4. Do not confuse HKU\.DEFAULT with the profile template. */
static void default_user(void){char base[MAX_PATH],name[MAX_PATH],hive[MAX_PATH],expanded[MAX_PATH],fav[MAX_PATH];
  HKEY k=0;HANDLE token;TOKEN_PRIVILEGES tp;LUID id;LONG r;DWORD n;
  const char *profile="SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\ProfileList";
  if(query(HKEY_LOCAL_MACHINE,profile,"ProfilesDirectory",base,sizeof(base))){
    if(!query(HKEY_LOCAL_MACHINE,profile,"DefaultUserProfile",name,sizeof(name)))copy(name,"Default User");
    cat(base,"\\");cat(base,name);
  }else copy(base,"%SystemRoot%\\Profiles\\Default User");
  n=ExpandEnvironmentStringsA(base,expanded,sizeof(expanded));if(!n||n>sizeof(expanded)){failures++;return;}
  copy(hive,expanded);cat(hive,"\\NTUSER.DAT");
  if(OpenProcessToken(GetCurrentProcess(),TOKEN_ADJUST_PRIVILEGES|TOKEN_QUERY,&token)){
    tp.PrivilegeCount=1;tp.Privileges[0].Attributes=SE_PRIVILEGE_ENABLED;
    if(LookupPrivilegeValueA(0,"SeRestorePrivilege",&id)){tp.Privileges[0].Luid=id;AdjustTokenPrivileges(token,FALSE,&tp,0,0,0);}
    if(LookupPrivilegeValueA(0,"SeBackupPrivilege",&id)){tp.Privileges[0].Luid=id;AdjustTokenPrivileges(token,FALSE,&tp,0,0,0);}
    CloseHandle(token);
  }
  r=RegLoadKeyA(HKEY_USERS,"USOSLAN_DEFAULT",hive);
  if(r){result("Default User hive unavailable; retry at next hardware logon",r);return;}
  r=RegOpenKeyExA(HKEY_USERS,"USOSLAN_DEFAULT",0,KEY_ALL_ACCESS,&k);
  if(!r){
    ie(k);
    if(query(k,"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders","Favorites",fav,sizeof(fav))&&
       !memcmp(fav,"%USERPROFILE%",13)){
      copy(base,expanded);cat(base,fav+13);if(!favorite(base))failures++;
    }else if(!user_favorite(k)){failures++;log_line("Default User Favorites path unavailable; no guessed localized path written");}
    RegCloseKey(k);
  }else result("Default User open failed",r);
  result("Default User hive unload failed",RegUnLoadKeyA(HKEY_USERS,"USOSLAN_DEFAULT"));
}
#else
/* SetupAPI is resolved at runtime: Win95 without setupapi.dll still starts.
 * Remove precisely the ME inbox Dial-Up Adapter, never a physical NIC/modem.
 * DIF_REMOVE uses the device's own class installer and requests no restart. */
static void remove_me_dialup(void){HMODULE dll;HDEVINFO devices;SP_DEVINFO_DATA device;SP_DEVINSTALL_PARAMS_A params;DWORD index,type,needed;char ids[1024],*id;int found=0;
  HDEVINFO (WINAPI *get)(const GUID*,PCSTR,HWND,DWORD);
  BOOL (WINAPI *enumerate)(HDEVINFO,DWORD,PSP_DEVINFO_DATA);
  BOOL (WINAPI *property)(HDEVINFO,PSP_DEVINFO_DATA,DWORD,PDWORD,PBYTE,DWORD,PDWORD);
  BOOL (WINAPI *getparams)(HDEVINFO,PSP_DEVINFO_DATA,PSP_DEVINSTALL_PARAMS_A);
  BOOL (WINAPI *setparams)(HDEVINFO,PSP_DEVINFO_DATA,PSP_DEVINSTALL_PARAMS_A);
  BOOL (WINAPI *call)(DI_FUNCTION,HDEVINFO,PSP_DEVINFO_DATA);
  BOOL (WINAPI *destroy)(HDEVINFO);
  if(!eq(system_id,"ME"))return;
  dll=LoadLibraryA("setupapi.dll");if(!dll){failures++;log_line("ME Dial-Up removal: setupapi unavailable");return;}
#define LOAD(var,name) var=(void*)GetProcAddress(dll,name);if(!var){failures++;FreeLibrary(dll);return;}
  LOAD(get,"SetupDiGetClassDevsA");LOAD(enumerate,"SetupDiEnumDeviceInfo");LOAD(property,"SetupDiGetDeviceRegistryPropertyA");
  LOAD(getparams,"SetupDiGetDeviceInstallParamsA");LOAD(setparams,"SetupDiSetDeviceInstallParamsA");LOAD(call,"SetupDiCallClassInstaller");LOAD(destroy,"SetupDiDestroyDeviceInfoList");
#undef LOAD
  devices=get(0,0,0,DIGCF_ALLCLASSES);if(devices==INVALID_HANDLE_VALUE){failures++;FreeLibrary(dll);return;}
  for(index=0;;index++){
    memset(&device,0,sizeof(device));device.cbSize=sizeof(device);
    if(!enumerate(devices,index,&device)){if(GetLastError()!=ERROR_NO_MORE_ITEMS)failures++;break;}
    memset(ids,0,sizeof(ids));
    if(!property(devices,&device,SPDRP_HARDWAREID,&type,(BYTE*)ids,sizeof(ids)-2,&needed))continue;
    if(type!=REG_MULTI_SZ)continue;
    for(id=ids;*id;id+=len(id)+1)if(eq(id,"*PNP8387"))break;
    if(!*id)continue;
    found++;
    memset(&params,0,sizeof(params));params.cbSize=sizeof(params);
    if(!getparams(devices,&device,&params)){failures++;continue;}
    params.Flags|=DI_QUIETINSTALL;
    if(!setparams(devices,&device,&params)||!call(DIF_REMOVE,devices,&device)){failures++;log_line("ME Dial-Up remove failed; retry next desktop");continue;}
    log_line("ME Dial-Up Adapter removed (*PNP8387); no restart requested by USOS");
    if(getparams(devices,&device,&params)&&(params.Flags&(DI_NEEDREBOOT|DI_NEEDRESTART)))log_line("ME class installer reports restart pending; left to normal shutdown");
  }
  if(!found)log_line("ME Dial-Up Adapter absent");destroy(devices);FreeLibrary(dll);
}
static void transports(void){HKEY k;DWORD index,n;char name[32],key[MAX_PATH],value[MAX_PATH];int count=0;
  const char *base="System\\CurrentControlSet\\Services\\Class\\NetTrans";
  if(RegOpenKeyExA(HKEY_LOCAL_MACHINE,base,0,KEY_ENUMERATE_SUB_KEYS,&k)){
    log_line("TCP/IP NetTrans not enumerated; Setup binding needs hardware verification");return;}
  for(index=0;;index++){
    n=sizeof(name);if(RegEnumKeyExA(k,index,name,&n,0,0,0,0))break;
    copy(key,base);cat(key,"\\");cat(key,name);cat(key,"\\Ndi");
    if(!query(HKEY_LOCAL_MACHINE,key,"DeviceID",value,sizeof(value))||!eq(value,"MSTCP"))continue;
    count++;copy(key,base);cat(key,"\\");cat(key,name);log_line(key);
    if(query(HKEY_LOCAL_MACHINE,key,"IPAddress",value,sizeof(value)))log_line(value);
    if(query(HKEY_LOCAL_MACHINE,key,"IPMask",value,sizeof(value)))log_line(value);
  }
  RegCloseKey(k);if(!count)log_line("TCP/IP unbound/absent in NetTrans: no LAN connectivity asserted");
}
#endif

static int vm(void){unsigned a,b,c,d;__cpuid(1,a,b,c,d);if(c&0x80000000u)return 1;
  __cpuid(0x40000000u,a,b,c,d);return a>=0x40000000u&&a<=0x4000ffffu;}
static int desktop(void){HMODULE u=LoadLibraryA("user32.dll");HWND(WINAPI *find)(LPCSTR,LPCSTR);int ok=0;
  if(!u)return 0;find=(void*)GetProcAddress(u,"FindWindowA");if(find)ok=find("Shell_TrayWnd",0)!=0;FreeLibrary(u);return ok;}
int memcmp(const void *a,const void *b,size_t n){const BYTE *x=a,*y=b;while(n--){if(*x!=*y)return *x-*y;x++;y++;}return 0;}
static int read_config(void){static char raw[4097];char *line,*end;HANDLE f;DWORD n;int seen=0;
  f=CreateFileA(ini,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(f==INVALID_HANDLE_VALUE)return 0;
  if(!ReadFile(f,raw,sizeof(raw)-1,&n,0)||n==sizeof(raw)-1){CloseHandle(f);return 0;}CloseHandle(f);raw[n]=0;
  copy(home,"about:blank");system_id[0]=0;
  for(line=raw;*line;line=end){char *v,*p;end=line;while(*end&&*end!='\n')end++;if(*end)*end++=0;
    p=line;while(*p){if(*p=='\r'&&p[1]==0){*p=0;break;}if((BYTE)*p<32||(BYTE)*p>126||*p=='"'||*p=='\\'||*p=='|')return 0;p++;}
    v=line;while(*v&&*v!='=')v++;if(!*v)return 0;*v++=0;
    if(eq(line,"network")){if(seen++||!eq(v,"on"))return 0;}
    if(eq(line,"system")){if(len(v)>=sizeof(system_id))return 0;lstrcpyA(system_id,v);}
    if(eq(line,"home_page")){if(len(v)>200)return 0;lstrcpyA(home,v);}
  }
  if(!seen)return 0;
  if(lstrcmpA(home,"about:blank")&&memcmp(home,"http://",7)&&memcmp(home,"https://",8))return 0;
#ifdef USOS_LAN_NT
  return eq(system_id,"NT4")||eq(system_id,"W2K");
#else
  return eq(system_id,"95")||eq(system_id,"98")||eq(system_id,"98SE")||eq(system_id,"ME");
#endif
}
void entry(void){DWORD n,zero=0;char *p;HKEY k;
  n=GetModuleFileNameA(0,dir,sizeof(dir));if(!n||n>=sizeof(dir))ExitProcess(1);
  p=dir+n;while(p>dir&&p[-1]!='\\')p--;*p=0;
  local(ini,"NETCFG.INI");if(!read_config())ExitProcess(1);
#ifdef USOS_LAN_NT
  local(path,"NETSETUP.TXT");
#else
  local(path,"LOGS");CreateDirectoryA(path,0);local(path,"LOGS\\NETSETUP.TXT");
#endif
  log_handle=CreateFileA(path,GENERIC_WRITE,FILE_SHARE_READ,0,OPEN_ALWAYS,0,0);if(log_handle==INVALID_HANDLE_VALUE)ExitProcess(1);
  SetFilePointer(log_handle,0,0,FILE_END);
  if(vm()||!desktop()){log_line("LAN deferred: VM or Setup without Explorer desktop; Run retained");CloseHandle(log_handle);ExitProcess(0);}
  log_line("LAN first hardware desktop; no DHCP wait, ping or automatic restart");
  ie(HKEY_CURRENT_USER);set(HKEY_LOCAL_MACHINE,internet,"EnableAutodial",REG_DWORD,&zero,4);
  if(!user_favorite(HKEY_CURRENT_USER)){failures++;log_line("Favorites path/write unavailable; retry next logon");}
#ifdef USOS_LAN_NT
  default_user();
  if(eq(system_id,"NT4")){DWORD disabled=4;set(HKEY_LOCAL_MACHINE,"SYSTEM\\CurrentControlSet\\Services\\LanmanServer","Start",REG_DWORD,&disabled,4);}
#else
  set(HKEY_LOCAL_MACHINE,"System\\CurrentControlSet\\Services\\VxD\\MSTCP","EnableDNS",REG_SZ,"1",2);
  remove_me_dialup();
  transports();
#endif
  if(failures)log_line("LAN incomplete; see NETSETUP and retry at next desktop");
  else{
    log_line("LAN defaults applied: IE LAN, autodial/proxy/offline off, ICW completed, 68k.news Favorite");
    log_line("TCP/IP requested by Setup; connectivity and DHCP lease not asserted");
    if(!RegOpenKeyExA(HKEY_LOCAL_MACHINE,run,0,KEY_SET_VALUE,&k)){RegDeleteValueA(k,"USOSLan");RegCloseKey(k);}
  }
  CloseHandle(log_handle);ExitProcess(failures?2:0);
}
