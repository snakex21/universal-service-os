/* USOS LAN first desktop step, GPL-3.0-or-later.
 * No CRT, console or restart. NT4 can launch the own silent network evidence
 * logger once after applying defaults. Desktop readiness is bounded
 * and event-driven. Private data live beside this executable. Favorites,
 * verified ICW shortcuts and the requested OS settings are the
 * only writes outside that directory. NDIS/IRQ configuration is untouched.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <shlobj.h>
#include <objidl.h>
#include <cpuid.h>
#include "lan_state.h"
#include "legacy_desktop_wait.h"
int memcmp(const void *,const void *,size_t);

void *memset(void *p,int v,size_t n){volatile BYTE *b=p;while(n--)*b++=(BYTE)v;return p;}
void *memcpy(void *d,const void *s,size_t n){volatile BYTE *a=d;const BYTE *b=s;while(n--)*a++=*b++;return d;}
static char dir[MAX_PATH],ini[MAX_PATH],path[MAX_PATH],home[201],system_id[8];
static HANDLE log_handle=INVALID_HANDLE_VALUE;
static unsigned failures;
static int setup_mode;
static UsosLanState state;
static DWORD len(const char *s){DWORD n=0;while(s[n])n++;return n;}
static int eq(const char *a,const char *b){return lstrcmpiA(a,b)==0;}
static void copy(char *d,const char *s){lstrcpynA(d,s,MAX_PATH);}
static void cat(char *d,const char *s){if(len(d)+len(s)<MAX_PATH)lstrcatA(d,s);else failures++;}
static void local(char *d,const char *name){copy(d,dir);cat(d,name);}
static void digits(char *p,DWORD n,unsigned width){while(width){p[--width]=(char)('0'+n%10);n/=10;}}
static void log_line(const char *s){DWORD w;SYSTEMTIME now;char stamp[31]="0000-00-00 00:00:00 [try 0] ";
  GetLocalTime(&now);digits(stamp,now.wYear,4);digits(stamp+5,now.wMonth,2);digits(stamp+8,now.wDay,2);
  digits(stamp+11,now.wHour,2);digits(stamp+14,now.wMinute,2);digits(stamp+17,now.wSecond,2);stamp[25]=(char)('0'+state.tries);
  WriteFile(log_handle,stamp,len(stamp),&w,0);WriteFile(log_handle,s,len(s),&w,0);WriteFile(log_handle,"\r\n",2,&w,0);FlushFileBuffers(log_handle);}
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
/* Internet Explorer 3 (Windows 95 OSR2) cannot open about:blank ("cannot
   find"); its own Local Page is a plain file and it writes local pages as
   file://C:\path (SHDOCVW.DLL 4.70 "file://%c:%s"). On 95 the default page
   is the small START.HTM the install writes beside this helper. After an
   original IE5/6 upgrade, preserve the requested about:blank instead.
   Use the installed product Version, not SHDOCVW's 4.70 file version. */
#ifndef USOS_LAN_NT
static int installed_ie5plus(void){char version[80];unsigned i=0,part=0,major=0;
  if(!query(HKEY_LOCAL_MACHINE,"Software\\Microsoft\\Internet Explorer","Version",version,sizeof version))return 0;
  if(version[0]!='5'&&version[0]!='6')return 0;
  major=(unsigned)(version[i++]-'0');
  if(version[i++]!='.')return 0;
  for(;version[i];i++){
    if(version[i]>='0'&&version[i]<='9'){part++;continue;}
    if(version[i]!='.'||!part)return 0;part=0;
  }
  return major>=5&&part!=0;
}
#endif
static const char *start_page(void){
#ifndef USOS_LAN_NT
  static char page[MAX_PATH+8];
  if(eq(system_id,"95")&&!lstrcmpA(home,"about:blank")&&!installed_ie5plus()){local(path,"START.HTM");
    if(GetFileAttributesA(path)!=INVALID_FILE_ATTRIBUTES&&len(path)<MAX_PATH){lstrcpyA(page,"file://");lstrcatA(page,path);return page;}}
#endif
  return home;}
static void ie(HKEY root){DWORD zero=0,one=1;const char *page=start_page();
  set(root,internet,"EnableAutodial",REG_DWORD,&zero,4);
  set(root,internet,"NoNetAutodial",REG_DWORD,&one,4);
  set(root,internet,"ProxyEnable",REG_DWORD,&zero,4);
  set(root,internet,"GlobalUserOffline",REG_DWORD,&zero,4);
  set(root,wizard,"Completed",REG_BINARY,&one,4);
  set(root,main_key,"Start Page",REG_SZ,page,len(page)+1);
  set(root,main_key,"First Home Page",REG_SZ,page,len(page)+1);
  set(root,main_key,"RunOnceHasShown",REG_DWORD,&one,4);set(root,main_key,"RunOnceComplete",REG_DWORD,&one,4);}
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
  const char *shell="Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Shell Folders";
  if(!query(root,shell,"Favorites",folder,sizeof(folder))){
#ifndef USOS_LAN_NT
    /* Original950 without IE has no Favorites value yet. Only the explicit
     * source950 setup handoff may establish the OS default before Explorer;
     * existing user paths and every ordinary desktop run stay unchanged. */
    DWORD n;
    if(!setup_mode||root!=HKEY_CURRENT_USER)return 0;
    n=GetWindowsDirectoryA(folder,sizeof folder);if(!n||n>sizeof(folder)-12)return 0;
    lstrcatA(folder,"\\Favorites");if(!favorite(folder))return 0;
    set(root,shell,"Favorites",REG_SZ,folder,len(folder)+1);
    log_line("LAN setup: initialized missing source950 OS Favorites folder");return failures==0;
#else
    return 0;
#endif
  }
  if(!ExpandEnvironmentStringsA(folder,expanded,sizeof(expanded)))return 0;
  return favorite(expanded);}

/* Resolve the actual link target through the OS Shell Link interface. A
 * localized label or a mention of ICW in a description is never a match. */
static int icw_target(const char *target){const char *p=target,*base=target;while(*p){if(*p=='\\'||*p=='/')base=p+1;p++;}return eq(base,"ICWCONN1.EXE");}
static void desktop_links(HKEY root,const char *value,HRESULT(WINAPI *create)(REFCLSID,LPUNKNOWN,DWORD,REFIID,LPVOID *)) {
  static const GUID clsid={0x00021401,0,0,{0xc0,0,0,0,0,0,0,0x46}};
  static const GUID link_id={0x000214ee,0,0,{0xc0,0,0,0,0,0,0,0x46}};
  static const GUID persist_id={0x0000010b,0,0,{0xc0,0,0,0,0,0,0,0x46}};
  char folder[MAX_PATH],expanded[MAX_PATH],file[MAX_PATH],target[MAX_PATH];WCHAR wide[MAX_PATH];
  WIN32_FIND_DATAA item;HANDLE search;DWORD n;IShellLinkA *link;IPersistFile *persist;HRESULT r;int remove;
  if(!query(root,"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Shell Folders",value,folder,sizeof folder))return;
  n=ExpandEnvironmentStringsA(folder,expanded,sizeof expanded);if(!n||n>sizeof expanded){failures++;return;}
  copy(file,expanded);cat(file,"\\*.LNK");search=FindFirstFileA(file,&item);
  if(search==INVALID_HANDLE_VALUE){if(GetLastError()!=ERROR_FILE_NOT_FOUND&&GetLastError()!=ERROR_PATH_NOT_FOUND)failures++;return;}
  do {
    n=len(item.cFileName);if((item.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)||n<4||!eq(item.cFileName+n-4,".LNK"))continue;
    copy(file,expanded);cat(file,"\\");cat(file,item.cFileName);link=0;persist=0;remove=0;
    r=create(&clsid,0,1,&link_id,(void**)&link);if(FAILED(r)||!link){failures++;break;}
    r=link->lpVtbl->QueryInterface(link,&persist_id,(void**)&persist);
    if(SUCCEEDED(r)&&persist&&MultiByteToWideChar(CP_ACP,0,file,-1,wide,MAX_PATH)) {
      r=persist->lpVtbl->Load(persist,wide,STGM_READ);
      target[0]=0;if(SUCCEEDED(r)&&SUCCEEDED(link->lpVtbl->GetPath(link,target,sizeof target,0,0)))remove=icw_target(target);
    }
    if(persist)persist->lpVtbl->Release(persist);link->lpVtbl->Release(link);
    if(remove){if(DeleteFileA(file)){log_line("ICW shortcut removed by verified target");log_line(file);}else{failures++;log_line("ICW shortcut removal failed");}}
  }while(FindNextFileA(search,&item));
  FindClose(search);
}
static void shortcuts(void) {
  HMODULE ole=LoadLibraryA("ole32.dll");HRESULT r;
  HRESULT(WINAPI *initialize)(LPVOID);void(WINAPI *uninitialize)(void);
  HRESULT(WINAPI *create)(REFCLSID,LPUNKNOWN,DWORD,REFIID,LPVOID *);
  if(!ole){failures++;log_line("ICW shortcut cleanup: COM unavailable");return;}
  initialize=(void*)GetProcAddress(ole,"CoInitialize");uninitialize=(void*)GetProcAddress(ole,"CoUninitialize");
  create=(void*)GetProcAddress(ole,"CoCreateInstance");
  if(!initialize||!uninitialize||!create){failures++;FreeLibrary(ole);return;}
  r=initialize(0);if(FAILED(r)){failures++;FreeLibrary(ole);return;}
  desktop_links(HKEY_CURRENT_USER,"Desktop",create);
  /* Me puts its "Connect to the Internet" link on the common desktop
   * (HKLM Shell Folders "Common Desktop" = C:\WINDOWS\All Users\Pulpit on a
   * Polish Me, X470 2026-10-20); 95/98 without that value: nothing to do. */
  desktop_links(HKEY_LOCAL_MACHINE,"Common Desktop",create);
  uninitialize();FreeLibrary(ole);
}

#ifdef USOS_LAN_NT
/* Same Default User lookup as the existing usos-reg tool, using ANSI APIs
 * supported by NT4. Do not confuse HKU\.DEFAULT with the profile template. */
static void default_user(int browser){char base[MAX_PATH],name[MAX_PATH],hive[MAX_PATH],expanded[MAX_PATH],fav[MAX_PATH];
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
    if(browser)ie(k);
    else if(query(k,"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders","Favorites",fav,sizeof(fav))&&
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
/* DHCP lease evidence, log only. 95's VDHCP keeps a lease in
 * VxD\DHCP\DhcpInfoNN "DhcpInfo" (X470 95 RTM run with a lease, 2026-10-26:
 * DhcpInfo00, address at +4, mask at +8, server at +12, network order);
 * the run without one (2026-10-27) had no DhcpInfoNN key. NetTrans
 * IPAddress 0.0.0.0 is only the "obtain automatically" setting. */
static void ip_text(char *out,const BYTE *p){unsigned i,k=0,n,v;char d[3];
  for(i=0;i<4;i++){v=p[i];n=0;do{d[n++]=(char)('0'+v%10);v/=10;}while(v);while(n)out[k++]=d[--n];if(i<3)out[k++]='.';}
  out[k]=0;}
static void dhcp_lease(const char *when){HKEY k;char key[80],line[MAX_PATH],ip[16];BYTE data[64];DWORD n,type;unsigned i,found=0;LONG r;
  for(i=0;i<8;i++){
    lstrcpyA(key,"System\\CurrentControlSet\\Services\\VxD\\DHCP\\DhcpInfo00");key[len(key)-1]=(char)('0'+i);
    if(RegOpenKeyExA(HKEY_LOCAL_MACHINE,key,0,KEY_QUERY_VALUE,&k))continue;
    n=sizeof data;r=RegQueryValueExA(k,"DhcpInfo",0,&type,data,&n);RegCloseKey(k);
    found++;copy(line,"DHCP ");cat(line,when);cat(line,": ");cat(line,key+len(key)-10);
    if(r||n<16){cat(line," without a readable DhcpInfo value");log_line(line);continue;}
    ip_text(ip,data+4);cat(line," ip=");cat(line,ip);
    ip_text(ip,data+8);cat(line," mask=");cat(line,ip);
    ip_text(ip,data+12);cat(line," server=");cat(line,ip);
    if(!(data[4]|data[5]|data[6]|data[7]))cat(line," (no address)");
    log_line(line);
  }
  if(!found){copy(line,"DHCP ");cat(line,when);cat(line,": no lease (no VxD\\DHCP\\DhcpInfoNN)");log_line(line);}
}
/* 950 only: NETDI wrote NETBEUI$ / nwlink$ into PROTOCOL.INI for the
 * defaults NETCLEAN (tools/w9x_reg95.sh) removes from the registry; setupx
 * cannot delete an INI section. Only once no NetTrans instance has that
 * DeviceID any more. WritePrivateProfileStringA is resolved at run time (the
 * static imports stay the verified NT4 RTM list). An absent section or file
 * is nothing to do. */
static int win950(void){OSVERSIONINFOA v={0};v.dwOSVersionInfoSize=sizeof v;
  return GetVersionExA(&v)&&v.dwPlatformId==VER_PLATFORM_WIN32_WINDOWS&&v.dwMajorVersion==4&&v.dwMinorVersion==0&&(v.dwBuildNumber&0xffff)==950;}
static int ini_has_section(const char *text,const char *name){const char *p=text,*a,*b;
  for(;*p;p++){if(p!=text&&p[-1]!='\n')continue;if(*p!='[')continue;
    for(a=p+1,b=name;*a&&*b;a++,b++){char x=*a,y=*b;if(x>='A'&&x<='Z')x+='a'-'A';if(y>='A'&&y<='Z')y+='a'-'A';if(x!=y)break;}
    if(!*b&&*a==']')return 1;}
  return 0;}
static void protocol_ini(const char *section,int installed){static char text[16385];char file[MAX_PATH],line[MAX_PATH];HANDLE f;DWORD n=0;HMODULE k32;
  BOOL(WINAPI *write)(LPCSTR,LPCSTR,LPCSTR,LPCSTR);
  n=GetWindowsDirectoryA(file,sizeof file);if(!n||n>sizeof(file)-14)return;lstrcatA(file,"\\PROTOCOL.INI");
  f=CreateFileA(file,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(f==INVALID_HANDLE_VALUE)return;
  n=0;if(!ReadFile(f,text,sizeof(text)-1,&n,0))n=0;CloseHandle(f);text[n]=0;
  if(!ini_has_section(text,section))return;
  copy(line,"PROTOCOL.INI [");cat(line,section);
  if(installed){cat(line,"] kept: its protocol is still in NetTrans");log_line(line);return;}
  k32=LoadLibraryA("kernel32.dll");write=k32?(void*)GetProcAddress(k32,"WritePrivateProfileStringA"):0;
  if(write&&write(section,0,0,file)){write(0,0,0,file);cat(line,"] removed (950 default, not installed)");}
  else cat(line,"] removal failed (log only; the section is unused)");
  if(k32)FreeLibrary(k32);log_line(line);}
static void transports(void){HKEY k;DWORD index,n;char name[32],key[MAX_PATH],value[MAX_PATH];int count=0,nwlink=0,netbeui=0;
  const char *base="System\\CurrentControlSet\\Services\\Class\\NetTrans";
  if(RegOpenKeyExA(HKEY_LOCAL_MACHINE,base,0,KEY_ENUMERATE_SUB_KEYS,&k)){
    log_line("TCP/IP NetTrans not enumerated; Setup binding needs hardware verification");dhcp_lease("now");return;}
  for(index=0;;index++){
    n=sizeof(name);if(RegEnumKeyExA(k,index,name,&n,0,0,0,0))break;
    copy(key,base);cat(key,"\\");cat(key,name);cat(key,"\\Ndi");
    if(!query(HKEY_LOCAL_MACHINE,key,"DeviceID",value,sizeof(value)))continue;
    if(eq(value,"NWLINK"))nwlink++;if(eq(value,"NETBEUI"))netbeui++;
    if(!eq(value,"MSTCP"))continue;
    count++;copy(key,base);cat(key,"\\");cat(key,name);log_line(key);
    if(query(HKEY_LOCAL_MACHINE,key,"IPAddress",value,sizeof(value)))log_line(value);
    if(query(HKEY_LOCAL_MACHINE,key,"IPMask",value,sizeof(value)))log_line(value);
  }
  RegCloseKey(k);if(!count)log_line("TCP/IP unbound/absent in NetTrans: no LAN connectivity asserted");
  dhcp_lease("now");
  if(eq(system_id,"95")&&win950()){protocol_ini("nwlink$",nwlink);protocol_ini("NETBEUI$",netbeui);}
}
/* "/dhcplater": the copy a /refresh run starts. It never blocks the caller
 * (the 950 first-desktop coordinator waits for /refresh): it sleeps 30 s,
 * then appends the lease state to NETSETUP.TXT, nothing else. */
#define USOS_DHCP_LATER_DELAY 30000
static int dhcp_later_requested(void){const char *p=GetCommandLineA();
  while(*p){if(*p==' '&&len(p)>=11&&p[1]=='/'&&!memcmp(p+2,"dhcplater",9)&&(p[11]==0||p[11]==' '))return 1;p++;}return 0;}
static void dhcp_later_spawn(void){char exe[MAX_PATH],cmd[MAX_PATH+16];STARTUPINFOA si;PROCESS_INFORMATION pi;DWORD n;
  n=GetModuleFileNameA(0,exe,sizeof exe);if(!n||n>=sizeof exe)return;
  lstrcpyA(cmd,"\"");lstrcatA(cmd,exe);lstrcatA(cmd,"\" /dhcplater");
  memset(&si,0,sizeof si);si.cb=sizeof si;
  if(CreateProcessA(exe,cmd,0,0,FALSE,0,0,dir,&si,&pi)){CloseHandle(pi.hThread);CloseHandle(pi.hProcess);
    log_line("DHCP lease recheck in 30 s started (log only, nothing waits for it)");}
  else log_line("DHCP lease recheck could not start (log only)");}
static void dhcp_later(void){unsigned i;
  Sleep(USOS_DHCP_LATER_DELAY);
  /* The /refresh run may still hold NETSETUP.TXT (shared for reading only). */
  local(path,"LOGS\\NETSETUP.TXT");
  for(i=0;i<20;i++){log_handle=CreateFileA(path,GENERIC_WRITE,FILE_SHARE_READ,0,OPEN_ALWAYS,0,0);
    if(log_handle!=INVALID_HANDLE_VALUE)break;Sleep(1000);}
  if(log_handle==INVALID_HANDLE_VALUE)ExitProcess(1);
  SetFilePointer(log_handle,0,0,FILE_END);dhcp_lease("30 s after refresh");CloseHandle(log_handle);ExitProcess(0);}
#endif

static int vm(void){unsigned a,b,c,d;__cpuid(1,a,b,c,d);if(c&0x80000000u)return 1;
  __cpuid(0x40000000u,a,b,c,d);return a>=0x40000000u&&a<=0x4000ffffu;}
#ifndef USOS_LAN_NT
/* Native QEMU is also a VM. Only source950 may pass this boundary, after
 * the phase1 postprocessor wrote its own marker and original GUI Setup
 * removed RunOnce\Setup. A marker alone does not certify final Setup or
 * filesystem verification. The caller must also wait for the desktop.
 * The nested first-stage Setup has no postprocessor marker and defers.
 */
/* usosfb.c coordinated_build / display_ready: 950 (RTM / OSR1) and the OSR2
 * family (1111, 1212..1216). 950 binds VESALATE.BAT late (VLATE.OK); OSR2
 * stages no VESALATE: VESA95.BAT had its one attempt (OK or BAD), or none. */
static int coordinated95_build(DWORD build){build&=0xffff;
  return build==950||build==1111||build==1212||build==1214||build==1216;}
static int present95(const char *name){local(path,name);return GetFileAttributesA(path)!=INVALID_FILE_ATTRIBUTES;}
static int display95_ready(void){
  if(present95("VESALATE.BAT"))return present95("VLATE.OK");
  return present95("VESA95.OK")||present95("VESA95.BAD")||!present95("VESA95.BAT");}
static int native95_handoff(void){char raw[96];DWORD n,i;HANDLE f;HKEY setup;LONG status;OSVERSIONINFOA version={0};
  version.dwOSVersionInfoSize=sizeof version;
  if(!eq(system_id,"95")||!GetVersionExA(&version)||version.dwPlatformId!=VER_PLATFORM_WIN32_WINDOWS||
     version.dwMajorVersion!=4||version.dwMinorVersion!=0||!coordinated95_build(version.dwBuildNumber))return 0;
  local(path,"PHASE1.OK");f=CreateFileA(path,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);
  if(f==INVALID_HANDLE_VALUE)return 0;
  n=0;status=GetFileSize(f,0)<sizeof(raw)&&ReadFile(f,raw,sizeof(raw),&n,0);CloseHandle(f);
  if(!status)return 0;
  /* Native phase 1 (tools/w9x_950_post.sh, COMMAND.COM "ECHO phase1=native> PHASE1.OK")
   * writes exactly "phase1=native\r\n", native OSR2 "phase1=native-osr2\r\n";
   * QEMU phase 1 writes "phase1=qemu elapsed=N\r\n". */
  if((n!=15||memcmp(raw,"phase1=native\r\n",15))&&(n!=20||memcmp(raw,"phase1=native-osr2\r\n",20))){
    if(n<23||memcmp(raw,"phase1=qemu elapsed=",20))return 0;
    i=20;while(i<n&&raw[i]>='0'&&raw[i]<='9')i++;
    if(i==20||i+2!=n||raw[i]!='\r'||raw[i+1]!='\n')return 0;}
  status=RegOpenKeyExA(HKEY_LOCAL_MACHINE,"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce\\Setup",0,KEY_READ,&setup);
  if(status==ERROR_SUCCESS){RegCloseKey(setup);return 0;}
  return status==ERROR_FILE_NOT_FOUND;
}
#endif
static int desktop(void){HMODULE u=LoadLibraryA("user32.dll");HWND(WINAPI *find)(LPCSTR,LPCSTR);int ok=0;
  if(!u)return 0;find=(void*)GetProcAddress(u,"FindWindowA");if(find)ok=find("Shell_TrayWnd",0)!=0;FreeLibrary(u);return ok;}
int memcmp(const void *a,const void *b,size_t n){const BYTE *x=a,*y=b;while(n--){if(*x!=*y)return *x-*y;x++;y++;}return 0;}
#ifndef USOS_LAN_NT
static int native_config(void){
  static char raw[65537];char *line,*end;char data[512];DWORD n,w;int enabled=0;HANDLE f;OSVERSIONINFOA version={0};
  local(path,"MSBATCH.INF");f=CreateFileA(path,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);
  if(f==INVALID_HANDLE_VALUE)return 0;
  if(!ReadFile(f,raw,sizeof(raw)-1,&n,0)||n>=sizeof(raw)-1){CloseHandle(f);return 0;}CloseHandle(f);raw[n]=0;
  lstrcpyA(home,"about:blank");
  for(line=raw;*line;line=end){end=line;while(*end&&*end!='\n')end++;if(*end)*end++=0;n=len(line);if(n&&line[n-1]=='\r')line[n-1]=0;
    if(n>=14&&!memcmp(line,";USOS-NETWORK=",14)){if(!eq(line+14,"on"))return 0;enabled++;}
    if(n>=11&&!memcmp(line,";USOS-HOME=",11)){if(len(line+11)>200)return 0;lstrcpyA(home,line+11);}
  }
  if(enabled!=1)return 0;
  version.dwOSVersionInfoSize=sizeof version;
  if(!GetVersionExA(&version)||version.dwPlatformId!=VER_PLATFORM_WIN32_WINDOWS||version.dwMajorVersion!=4||
     (version.dwMinorVersion!=0&&version.dwMinorVersion!=10&&version.dwMinorVersion!=90))return 0;
  /* GetVersion's high word cannot distinguish 98 FE from SE on Win9x. */
  lstrcpyA(system_id,version.dwMinorVersion==90?"ME":version.dwMinorVersion==0?"95":(version.dwBuildNumber&0xffff)>=2222?"98SE":"98");
  lstrcpyA(data,"system=");lstrcatA(data,system_id);lstrcatA(data,"\r\nnetwork=on\r\nhome_page=");lstrcatA(data,home);lstrcatA(data,"\r\ndriver=dos-native-not-staged\r\n");
  f=CreateFileA(ini,GENERIC_WRITE,0,0,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,0);if(f==INVALID_HANDLE_VALUE)return 0;
  n=len(data);w=0;enabled=WriteFile(f,data,n,&w,0)&&w==n&&FlushFileBuffers(f);CloseHandle(f);
  if(enabled)log_line("DOS-native NETCFG created from selected MSBATCH metadata");return enabled;
}
#endif
static int read_config(void){static char raw[4097];char *line,*end;HANDLE f;DWORD n;int seen=0;
  if(GetFileAttributesA(ini)==INVALID_FILE_ATTRIBUTES){
#ifndef USOS_LAN_NT
    if(!native_config())return 0;
#else
    return 0;
#endif
  }
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
  return eq(system_id,"NT4")||eq(system_id,"W2K")||eq(system_id,"XP")||eq(system_id,"W2K3");
#else
  return eq(system_id,"95")||eq(system_id,"98")||eq(system_id,"98SE")||eq(system_id,"ME");
#endif
}
/* The 9x shell starts Run values inside its RegEnumValue(index) loop
   (Windows 2000's explorer\initcab.cpp / runonce.c says the old shell did
   so before it switched to a snapshot). Deleting our value at once moves
   the next value down to our index and the shell skips it: on the X470
   (95 OSR2, 2026-10-20) USOSLan's quick delete hid USOSDisplay, so USOSRES
   never ran. Wait out the shell's loop first. */
#define USOS_RUN_DELETE_DELAY 15000
static void unregister(void){HKEY k;
#ifndef USOS_LAN_NT
  if(!setup_mode)Sleep(USOS_RUN_DELETE_DELAY);
#endif
  if(!RegOpenKeyExA(HKEY_LOCAL_MACHINE,run,0,KEY_SET_VALUE,&k)){RegDeleteValueA(k,"USOSLan");RegCloseKey(k);}}

#ifdef USOS_LAN_NT
static void network_evidence(void){
  char exe[MAX_PATH],out[MAX_PATH],cmd[MAX_PATH*2+80];STARTUPINFOA si;PROCESS_INFORMATION pi;
  if(!eq(system_id,"NT4"))return;
  local(exe,"USOSLOG.EXE");local(out,"USABILITY.TXT");
  if(GetFileAttributesA(exe)==INVALID_FILE_ATTRIBUTES){log_line("NT4 evidence helper missing; no connectivity result");return;}
  lstrcpyA(cmd,"\"");lstrcatA(cmd,exe);lstrcatA(cmd,"\" /once /nodbg /nohook /out \"");
  lstrcatA(cmd,out);lstrcatA(cmd,"\"");
  memset(&si,0,sizeof(si));si.cb=sizeof(si);si.dwFlags=STARTF_USESHOWWINDOW;si.wShowWindow=SW_HIDE;
  if(CreateProcessA(exe,cmd,0,0,FALSE,0,0,dir,&si,&pi)){
    CloseHandle(pi.hThread);CloseHandle(pi.hProcess);
    log_line("NT4 silent evidence started: USABILITY.TXT; launch alone is not DHCP/ping/DNS PASS");
  }else log_line("NT4 evidence launch failed; no connectivity result");
}
#endif
static unsigned long config_hash(void){unsigned long hash=2166136261UL;const char *p;
  for(p=system_id;*p;p++)hash=(hash^(BYTE)*p)*16777619UL;hash=(hash^'|')*16777619UL;
  for(p=home;*p;p++)hash=(hash^(BYTE)*p)*16777619UL;return hash;}
static void initial_state(void){state.magic=0x554c4e32UL;state.config=config_hash();state.tries=state.done=0;}
static int load_state(int refresh){HANDLE f;DWORD n;int ok;
  initial_state();local(path,"NETSTATE.DAT");f=CreateFileA(path,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);
  if(f==INVALID_HANDLE_VALUE)return GetLastError()==ERROR_FILE_NOT_FOUND;
  ok=GetFileSize(f,0)==sizeof(state)&&ReadFile(f,&state,sizeof(state),&n,0)&&n==sizeof(state);CloseHandle(f);
  if(!ok||state.magic!=0x554c4e32UL||state.tries>USOS_LAN_MAX_TRIES||(state.done&~USOS_LAN_ALL)){
    initial_state();if(!refresh)return 0;
  }
  if(state.config!=config_hash())initial_state();return 1;
}
static int save_state(void){HANDLE f;DWORD n;int ok;
  local(path,"NETSTATE.DAT");f=CreateFileA(path,GENERIC_WRITE,0,0,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);if(f==INVALID_HANDLE_VALUE)return 0;
  ok=WriteFile(f,&state,sizeof(state),&n,0)&&n==sizeof(state)&&FlushFileBuffers(f);CloseHandle(f);return ok;
}
static int refresh_requested(void){const char *p=GetCommandLineA();while(*p){if(*p==' '&&len(p)>=9&&p[1]=='/'&&!memcmp(p+2,"refresh",7)&&(p[9]==0||p[9]==' '))return 1;p++;}return 0;}
static int action(void *context){unsigned before=failures,bit=*(unsigned*)context;DWORD zero=0;
  switch(bit){
  case USOS_LAN_IE:ie(HKEY_CURRENT_USER);set(HKEY_LOCAL_MACHINE,internet,"EnableAutodial",REG_DWORD,&zero,4);break;
  case USOS_LAN_FAVORITE:if(!user_favorite(HKEY_CURRENT_USER)){failures++;log_line("Favorites unavailable");}break;
  case USOS_LAN_SHORTCUTS:shortcuts();break;
#ifdef USOS_LAN_NT
  case USOS_LAN_DEFAULT:default_user(1);break;
  case USOS_LAN_DEFAULT_FAVORITE:default_user(0);break;
  case USOS_LAN_SYSTEM:if(eq(system_id,"NT4")){DWORD disabled=4;
    set(HKEY_LOCAL_MACHINE,"SYSTEM\\CurrentControlSet\\Services\\LanmanServer","Start",REG_DWORD,&disabled,4);
    set(HKEY_LOCAL_MACHINE,"SYSTEM\\CurrentControlSet\\Services\\Browser","Start",REG_DWORD,&disabled,4);}break;
#else
  case USOS_LAN_DIALUP:remove_me_dialup();break;
  case USOS_LAN_SYSTEM:set(HKEY_LOCAL_MACHINE,"System\\CurrentControlSet\\Services\\VxD\\MSTCP","EnableDNS",REG_SZ,"1",2);transports();break;
#endif
  default:break;
  }
  return failures==before;
}
void entry(void){DWORD n;char *p;unsigned bit;int refresh;HANDLE mutex;
  n=GetModuleFileNameA(0,dir,sizeof(dir));if(!n||n>=sizeof(dir))ExitProcess(1);
  p=dir+n;while(p>dir&&p[-1]!='\\')p--;*p=0;
  local(ini,"NETCFG.INI");
#ifndef USOS_LAN_NT
  if(dhcp_later_requested())dhcp_later();
#endif
#ifdef USOS_LAN_NT
  local(path,"NETSETUP.TXT");
#else
  local(path,"LOGS");CreateDirectoryA(path,0);local(path,"LOGS\\NETSETUP.TXT");
#endif
  log_handle=CreateFileA(path,GENERIC_WRITE,FILE_SHARE_READ,0,OPEN_ALWAYS,0,0);if(log_handle==INVALID_HANDLE_VALUE)ExitProcess(1);
  SetFilePointer(log_handle,0,0,FILE_END);
#ifndef USOS_LAN_NT
  {const char *arg=GetCommandLineA();while(*arg){
    if(*arg==' '&&len(arg)>=7&&!memcmp(arg+1,"/setup",6)&&(arg[7]==0||arg[7]==' '))setup_mode=1;arg++;}
   if(setup_mode){
     /* native95_handoff also checks the exact phase1 marker and original
      * Setup key absence after read_config supplies the selected OS. */
     if(!display95_ready())ExitProcess(2);
     local(path,"FIRSTBT.ON");if(GetFileAttributesA(path)==INVALID_FILE_ATTRIBUTES)ExitProcess(2);
   }}
  /* Never while 9x Setup's RunOnce\Setup list is not empty (950 first GUI boot froze in GRPCONV, X470 2026-10-25). */
  /* RegQueryInfoKeyA resolved at run time: the static imports stay the verified NT4 RTM list. */
  {HKEY setup;DWORD keys=0,values=0;HMODULE adv;
   LONG(WINAPI *info)(HKEY,LPSTR,LPDWORD,LPDWORD,LPDWORD,LPDWORD,LPDWORD,LPDWORD,LPDWORD,LPDWORD,LPDWORD,PFILETIME);
   if(!RegOpenKeyExA(HKEY_LOCAL_MACHINE,"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce\\Setup",0,KEY_READ,&setup)){
     adv=LoadLibraryA("advapi32.dll");info=adv?(void*)GetProcAddress(adv,"RegQueryInfoKeyA"):0;
     if(!info||info(setup,0,0,0,&keys,0,0,&values,0,0,0,0))keys=values=1;RegCloseKey(setup);}
   if(keys||values){log_line("LAN deferred: Windows Setup still running (RunOnce\\Setup); Run retained");CloseHandle(log_handle);ExitProcess(0);}}
#endif
  if(!read_config()){log_line("LAN gave up: invalid/missing NETCFG and no valid DOS-native metadata");unregister();CloseHandle(log_handle);ExitProcess(1);}
#ifndef USOS_LAN_NT
  if(setup_mode&&!native95_handoff()){log_line("LAN setup: source950 handoff refused");CloseHandle(log_handle);ExitProcess(2);}
#endif
  if(vm()){
#ifndef USOS_LAN_NT
    if(!native95_handoff()){
#endif
      log_line("LAN deferred: VM; Run retained");CloseHandle(log_handle);ExitProcess(0);
#ifndef USOS_LAN_NT
    }
    log_line("LAN permitted: completed source950 handoff in VM; desktop still required");
#endif
  }
  mutex=CreateMutexA(0,FALSE,"USOSLAN-first-desktop");if(!mutex||GetLastError()==ERROR_ALREADY_EXISTS)ExitProcess(0);
  if(!setup_mode){
    if(!desktop())log_line("LAN waiting for desktop readiness notifications (bounded, no polling)");
    if(!usos_wait_desktop(desktop,300000)){log_line("LAN desktop deadline reached; Run retained");CloseHandle(log_handle);ExitProcess(0);}
  }
#ifndef USOS_LAN_NT
  /* Recheck the completion boundary after the readiness notification. */
  if(vm()&&!native95_handoff()){log_line("LAN deferred: source950 handoff changed; Run retained");CloseHandle(log_handle);ExitProcess(0);}
#endif
  refresh=refresh_requested();
  if(!load_state(refresh)){log_line("LAN gave up: invalid private retry state");unregister();CloseHandle(log_handle);ExitProcess(2);}
  if(refresh){usos_lan_refresh(&state);log_line("LAN explicit post-package refresh");
#ifndef USOS_LAN_NT
    dhcp_later_spawn();
#endif
  }
  if(state.done==USOS_LAN_ALL){log_line("LAN already completed; user settings preserved");unregister();CloseHandle(log_handle);ExitProcess(0);}
  if(!usos_lan_attempt(&state)){log_line("LAN gave up after three attempts; completed steps/user settings preserved");unregister();CloseHandle(log_handle);ExitProcess(2);}
  if(!save_state()){log_line("LAN gave up: cannot persist private retry state");unregister();CloseHandle(log_handle);ExitProcess(2);}
#ifndef USOS_LAN_NT
  if(vm())log_line("LAN installed source950 VM desktop; no connectivity assertion or automatic restart");
  else
#endif
  log_line("LAN first hardware desktop; no DHCP wait, ping or automatic restart");
  for(bit=1;bit<=USOS_LAN_DEFAULT_FAVORITE;bit<<=1){
    usos_lan_step(&state,bit,action,&bit);
    if(!save_state()){log_line("LAN gave up: state write failed; no profile-directory fallback");unregister();CloseHandle(log_handle);ExitProcess(2);}
  }
  if(failures){if(state.tries>=USOS_LAN_MAX_TRIES){log_line("LAN gave up after three attempts; user settings preserved");unregister();}
    else log_line("LAN incomplete; only failed steps retry at next desktop");}
  else{
    log_line("LAN defaults applied: IE LAN, autodial/proxy/offline off, ICW completed, 68k.news Favorite");
    log_line("TCP/IP requested by Setup; connectivity and DHCP lease not asserted");
#ifdef USOS_LAN_NT
    network_evidence();
#endif
    unregister();
  }
  CloseHandle(log_handle);ExitProcess(failures?2:0);
}
