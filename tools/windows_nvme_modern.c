/* Offline 8.1/10 x86 NVMe setup. Own code, GPL-3.0-or-later.
 * Existing stornvme service identity, separate owned binary and INF package.
 * Runs only in WinPE and never opens the running host's certificate store. */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0600
#include <windows.h>
#include <wincrypt.h>
#include <shellapi.h>

static const char *operation="arguments";
static DWORD failure_code;
static BYTE cert[16384],buffer[65536],other[65536];
static WCHAR target[MAX_PATH],package[MAX_PATH],path[MAX_PATH],backup[MAX_PATH];
static BOOL join(WCHAR *out,const WCHAR *base,const WCHAR *tail){if(lstrlenW(base)+lstrlenW(tail)>=MAX_PATH)return FALSE;lstrcpyW(out,base);lstrcatW(out,tail);return TRUE;}
static BOOL equal_files(const WCHAR *a,const WCHAR *b){
 HANDLE x=CreateFileW(a,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0),y=CreateFileW(b,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);BOOL ok=FALSE;
 if(x!=INVALID_HANDLE_VALUE&&y!=INVALID_HANDLE_VALUE){DWORD n,m;for(;;){if(!ReadFile(x,buffer,sizeof(buffer),&n,0)||!ReadFile(y,other,sizeof(other),&m,0)||n!=m)break;DWORD i=0;for(;i<n&&buffer[i]==other[i];i++){}if(i!=n)break;if(!n){ok=TRUE;break;}}}
 if(x!=INVALID_HANDLE_VALUE)CloseHandle(x);if(y!=INVALID_HANDLE_VALUE)CloseHandle(y);return ok;
}
static BOOL trusted_store(HKEY software,const WCHAR *name,DWORD size){
 HKEY key=0;HCERTSTORE store=0;BOOL ok=FALSE;
 if(RegCreateKeyExW(software,name,0,0,0,KEY_ALL_ACCESS,0,&key,0)!=ERROR_SUCCESS)return FALSE;
 store=CertOpenStore(CERT_STORE_PROV_REG,0,0,0,key);
 if(store){ok=CertAddEncodedCertificateToStore(store,X509_ASN_ENCODING,cert,size,CERT_STORE_ADD_REPLACE_EXISTING,0);if(!CertCloseStore(store,0))ok=FALSE;}
 if(RegFlushKey(key)!=ERROR_SUCCESS)ok=FALSE;RegCloseKey(key);return ok;
}
static LONG put_dword(HKEY key,const WCHAR *name,DWORD value){return RegSetValueExW(key,name,0,REG_DWORD,(const BYTE*)&value,sizeof(value));}
static BOOL service(HKEY hive,DWORD cs){
 WCHAR keypath[160],digits[4];HKEY key=0;LONG e;
 if(!cs||cs>999){SetLastError(ERROR_INVALID_DATA);return FALSE;}digits[0]=(WCHAR)('0'+cs/100);digits[1]=(WCHAR)('0'+cs/10%10);digits[2]=(WCHAR)('0'+cs%10);digits[3]=0;
 lstrcpyW(keypath,L"ControlSet");lstrcatW(keypath,digits);lstrcatW(keypath,L"\\Services\\stornvme");
 e=RegOpenKeyExW(hive,keypath,0,KEY_QUERY_VALUE|KEY_SET_VALUE,&key);if(e!=ERROR_SUCCESS){SetLastError(e);return FALSE;}
 /* Preserve the boot service identity; the inbox image is never overwritten. */
 static const WCHAR image[]=L"\\SystemRoot\\System32\\drivers\\usosnvme.sys";
 e=RegSetValueExW(key,L"ImagePath",0,REG_EXPAND_SZ,(const BYTE*)image,sizeof(image));
 if(e==ERROR_SUCCESS)e=put_dword(key,L"Start",0);
 if(e==ERROR_SUCCESS){HKEY over;if(RegOpenKeyExW(key,L"StartOverride",0,KEY_SET_VALUE,&over)==ERROR_SUCCESS){e=put_dword(over,L"0",0);RegCloseKey(over);}}
 if(e==ERROR_SUCCESS){HKEY pnp;e=RegCreateKeyExW(key,L"Parameters\\PnpInterface",0,0,0,KEY_SET_VALUE,0,&pnp,0);if(e==ERROR_SUCCESS){e=put_dword(pnp,L"5",1);RegCloseKey(pnp);}}
 if(e==ERROR_SUCCESS)e=RegFlushKey(key);RegCloseKey(key);if(e)SetLastError(e);return e==ERROR_SUCCESS;
}
static BOOL enable_privilege(const WCHAR *name){
 HANDLE token=0;TOKEN_PRIVILEGES p={0};BOOL ok=FALSE;
 if(OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY|TOKEN_ADJUST_PRIVILEGES,&token)){
  p.PrivilegeCount=1;p.Privileges[0].Attributes=SE_PRIVILEGE_ENABLED;
  if(LookupPrivilegeValueW(0,name,&p.Privileges[0].Luid)){
   SetLastError(ERROR_SUCCESS);
   ok=AdjustTokenPrivileges(token,FALSE,&p,0,0,0)&&GetLastError()==ERROR_SUCCESS;
  }
  CloseHandle(token);
 }
 return ok;
}
static void mount_name(WCHAR *name,const WCHAR *prefix){
 WCHAR digits[12];DWORD n=0,pid=GetCurrentProcessId();
 lstrcpyW(name,prefix);do{digits[n++]=(WCHAR)('0'+pid%10);pid/=10;}while(pid);
 DWORD at=lstrlenW(name);while(n)name[at++]=digits[--n];name[at]=0;
}
static LONG load_hive(const WCHAR *file,const WCHAR *name,HKEY *key,BOOL *loaded){
 HKEY existing=0;LONG e=RegOpenKeyExW(HKEY_LOCAL_MACHINE,name,0,KEY_READ,&existing);
 if(e==ERROR_SUCCESS){RegCloseKey(existing);return ERROR_ALREADY_EXISTS;}
 if(e!=ERROR_FILE_NOT_FOUND)return e;
 e=RegLoadKeyW(HKEY_LOCAL_MACHINE,name,file);if(e)return e;*loaded=TRUE;
 return RegOpenKeyExW(HKEY_LOCAL_MACHINE,name,0,KEY_ALL_ACCESS,key);
}
static BOOL configure(void){
 WCHAR sys[MAX_PATH],soft[MAX_PATH],src[MAX_PATH],dst[MAX_PATH],sm[64],wm[64];
 HKEY software=0,hive=0,select=0;BOOL ok=FALSE,soft_loaded=FALSE,sys_loaded=FALSE;
 DWORD size=0,read=0,current=0,def=0,type=0;LONG e=0;
 operation="target-paths";
 if(!join(sys,target,L"\\System32\\config\\SYSTEM")||!join(soft,target,L"\\System32\\config\\SOFTWARE"))return FALSE;
 operation="copy-driver";
 if(!join(src,package,L"\\usosnvme.sys")||!join(dst,target,L"\\System32\\drivers\\usosnvme.sys")||!CopyFileW(src,dst,FALSE)||!equal_files(src,dst))return FALSE;
 operation="read-certificate";
 if(!join(path,package,L"\\usosnvme.cer"))return FALSE;
 HANDLE file=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(file==INVALID_HANDLE_VALUE)return FALSE;
 size=GetFileSize(file,0);ok=size&&size<=sizeof(cert)&&ReadFile(file,cert,size,&read,0)&&read==size;CloseHandle(file);if(!ok)return FALSE;
 operation="backup-system";
 if(!join(backup,sys,L".before-usos-nvme")||!CopyFileW(sys,backup,TRUE))return FALSE;
 operation="backup-software";
 if(!join(backup,soft,L".before-usos-nvme")||!CopyFileW(soft,backup,TRUE))return FALSE;
 ok=FALSE;operation="enable-hive-privileges";
 if(!enable_privilege(L"SeBackupPrivilege")||!enable_privilege(L"SeRestorePrivilege"))goto done;
 /* App hives require uniform security descriptors. Real Windows SOFTWARE
  * is not such a hive. These temporary mount points exist only in WinPE;
  * entry() refuses a normal host before privileges, loads or file writes. */
 mount_name(sm,L"USOS_NVME_SYSTEM_");mount_name(wm,L"USOS_NVME_SOFTWARE_");
 operation="open-software";e=load_hive(soft,wm,&software,&soft_loaded);if(e)goto done;
 operation="trust-certificate-stores";
 if(!trusted_store(software,L"Microsoft\\SystemCertificates\\ROOT",size)||!trusted_store(software,L"Microsoft\\SystemCertificates\\TrustedPublisher",size))goto done;
 operation="flush-software";e=RegFlushKey(software);if(e)goto done;
 RegCloseKey(software);software=0;
 e=RegUnLoadKeyW(HKEY_LOCAL_MACHINE,wm);if(e)goto done;soft_loaded=FALSE;
 operation="open-system";e=load_hive(sys,sm,&hive,&sys_loaded);if(e)goto done;
 operation="read-select";e=RegOpenKeyExW(hive,L"Select",0,KEY_READ,&select);if(e)goto done;
 read=sizeof(current);e=RegQueryValueExW(select,L"Current",0,&type,(BYTE*)&current,&read);if(e||type!=REG_DWORD||read!=4)goto done;
 read=sizeof(def);e=RegQueryValueExW(select,L"Default",0,&type,(BYTE*)&def,&read);if(e||type!=REG_DWORD||read!=4)goto done;
 operation="configure-service";
 if(!service(hive,current)||(def!=current&&!service(hive,def)))goto done;
 e=RegFlushKey(hive);if(e)goto done;ok=TRUE;
 done:
 failure_code=e?e:GetLastError();
 if(select)RegCloseKey(select);if(hive)RegCloseKey(hive);if(software)RegCloseKey(software);
 if(sys_loaded){e=RegUnLoadKeyW(HKEY_LOCAL_MACHINE,sm);if(!e)sys_loaded=FALSE;else{ok=FALSE;operation="unload-system";failure_code=e;}}
 if(soft_loaded){e=RegUnLoadKeyW(HKEY_LOCAL_MACHINE,wm);if(!e)soft_loaded=FALSE;else{ok=FALSE;operation="unload-software";failure_code=e;}}
 /* Never replace a hive which is still mounted. A failure keeps the boot
  * gate closed and retains its backups for recovery. */
 if(!ok&&!sys_loaded&&!soft_loaded){
  if(join(backup,sys,L".before-usos-nvme"))CopyFileW(backup,sys,FALSE);
  if(join(backup,soft,L".before-usos-nvme"))CopyFileW(backup,soft,FALSE);
 }
 return ok;
}

void entry(void){
 HKEY pe;int argc=0;WCHAR **argv=CommandLineToArgvW(GetCommandLineW(),&argc);
 if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SYSTEM\\CurrentControlSet\\Control\\MiniNT",0,KEY_READ,&pe)!=ERROR_SUCCESS)ExitProcess(2);RegCloseKey(pe);
 if(argc!=3||lstrlenW(argv[1])>=MAX_PATH||lstrlenW(argv[2])>=MAX_PATH)ExitProcess(3);
 lstrcpyW(package,argv[1]);lstrcpyW(target,argv[2]);
 /* Require an explicit absolute Windows directory, distinct from this PE. */
 if(lstrlenW(target)<10||target[1]!=':'||target[2]!='\\')ExitProcess(3);
 WCHAR running[MAX_PATH];GetWindowsDirectoryW(running,MAX_PATH);if(!lstrcmpiW(running,target))ExitProcess(3);
 BOOL ok=configure();
 if(!ok){
  DWORD written,code=failure_code?failure_code:GetLastError();char digits[12];unsigned at=sizeof(digits);digits[--at]='\n';digits[--at]='\r';
  do{digits[--at]=(char)('0'+code%10);code/=10;}while(code);
  static const char prefix[]="USOS modern NVMe failed at ",middle[]="; Win32 code=";
  HANDLE output=GetStdHandle(STD_OUTPUT_HANDLE);
  WriteFile(output,prefix,sizeof(prefix)-1,&written,0);WriteFile(output,operation,lstrlenA(operation),&written,0);
  WriteFile(output,middle,sizeof(middle)-1,&written,0);WriteFile(output,digits+at,sizeof(digits)-at,&written,0);
 }
 LocalFree(argv);ExitProcess(ok?0:4);
}
