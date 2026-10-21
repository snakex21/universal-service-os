/* Vista / Server 2008 SP2 x64, CSMWrap path: every partition of a USB stick
 * (docs/vista-x64-usb-multipartition-2026-10-21.md).
 *
 * usosmpart.sys (own GPL disk class lower filter, tools/nt/usosmpart, WDK 7.1
 * fre x64 WLH build) signed with the per-build usosnvme amd64 test
 * certificate. x64 NT 6 loads it only with testsigning on, so this runs only
 * after the target BCD got testsigning (configure_boot_bios succeeded) and
 * never on the UEFI path. Mirrors the x86 :mpart rows of
 * tools/windows_x86_csmwrap.cmd: the file into System32\drivers, a
 * boot-start service (group "Filter") and usosmpart appended to the disk
 * class LowerFilters, in the Current and Default control sets. Not fatal:
 * any failure restores the SYSTEM hive backup and removes the file, so the
 * system boots as before (one volume per removable stick). */
#define MP64_CLASS L"\\Control\\Class\\{4D36E967-E325-11CE-BFC1-08002BE10318}"
static LONG mp64_dword(HKEY hive,const WCHAR *key,const WCHAR *name,DWORD value){
 return RegSetKeyValueW(hive,key,name,REG_DWORD,&value,sizeof(value));
}
static LONG mp64_string(HKEY hive,const WCHAR *key,const WCHAR *name,DWORD type,const WCHAR *value){
 return RegSetKeyValueW(hive,key,name,type,value,(lstrlenW(value)+1)*sizeof(WCHAR));
}
/* Appends usosmpart to the REG_MULTI_SZ LowerFilters (kept as it is when
 * already listed; created when missing). */
static LONG mp64_lower_filters(HKEY hive,const WCHAR *key){
 static WCHAR list[1024];
 DWORD size=sizeof(list)-16*sizeof(WCHAR),type=0;
 LONG e=RegGetValueW(hive,key,L"LowerFilters",RRF_RT_REG_MULTI_SZ,&type,list,&size);
 if(e==ERROR_FILE_NOT_FOUND)size=0;
 else if(e!=ERROR_SUCCESS)return e;
 /* RRF_RT_REG_MULTI_SZ: double-NUL terminated; terminate again in the
  * reserved tail anyway. */
 DWORD chars=size/sizeof(WCHAR);list[chars]=0;list[chars+1]=0;WCHAR *p=list;
 while((DWORD)(p-list)<chars&&*p){
  if(!lstrcmpiW(p,L"usosmpart"))return ERROR_SUCCESS;
  p+=lstrlenW(p)+1;
 }
 DWORD at=(DWORD)(p-list);
 if(at+11>sizeof(list)/sizeof(list[0]))return ERROR_MORE_DATA;
 lstrcpyW(p,L"usosmpart");p[10]=0;
 return RegSetKeyValueW(hive,key,L"LowerFilters",REG_MULTI_SZ,list,(at+11)*sizeof(WCHAR));
}
static BOOL install_mpart64(const Target *t){
 if(!csmwrap)return TRUE;
 WCHAR src[MAX_PATH],dst[MAX_PATH],hivefile[MAX_PATH],backup[MAX_PATH],key[200];BYTE a[32],b[32];
 path(src,base,L"usosmpart-amd64.sys");
 if(GetFileAttributesW(src)==INVALID_FILE_ATTRIBUTES){logcode("Mpart64: usosmpart-amd64.sys not in this build; USB sticks stay one volume=",ERROR_FILE_NOT_FOUND);return TRUE;}
 path(dst,t->root,L"Windows\\System32\\drivers\\usosmpart.sys");
 if(!CopyFileW(src,dst,FALSE)||!hash_file(src,a)||!hash_file(dst,b)||!same(a,b,32)){
  logcode("Mpart64: driver copy or read-back failed; not registered=",GetLastError());DeleteFileW(dst);return FALSE;
 }
 path(hivefile,t->root,L"Windows\\System32\\config\\SYSTEM");
 path(backup,t->root,L"USOS\\Vista\\SYSTEM.before-mpart");
 if(!CopyFileW(hivefile,backup,FALSE)){logcode("Mpart64: SYSTEM backup failed; not registered=",GetLastError());DeleteFileW(dst);return FALSE;}
 HKEY hive=0;LONG e=RegLoadAppKeyW(hivefile,&hive,KEY_ALL_ACCESS,0,0);
 if(e!=ERROR_SUCCESS){logcode("Mpart64: load offline SYSTEM=",e);DeleteFileW(dst);return FALSE;}
 DWORD current=0,def=0,size=sizeof(DWORD),type=0;
 e=RegGetValueW(hive,L"Select",L"Current",RRF_RT_REG_DWORD,&type,&current,&size);
 if(e==ERROR_SUCCESS){size=sizeof(DWORD);e=RegGetValueW(hive,L"Select",L"Default",RRF_RT_REG_DWORD,&type,&def,&size);}
 if(e==ERROR_SUCCESS&&(!current||current>999||!def||def>999))e=ERROR_INVALID_DATA;
 for(unsigned pass=0;e==ERROR_SUCCESS&&pass<2;pass++){
  DWORD cs=pass?def:current;if(pass&&cs==current)continue;
  WCHAR prefix[24]=L"ControlSet000";prefix[10]=L'0'+cs/100;prefix[11]=L'0'+(cs/10)%10;prefix[12]=L'0'+cs%10;
  lstrcpyW(key,prefix);lstrcatW(key,L"\\Services\\usosmpart");
  if((e=mp64_dword(hive,key,L"Type",1))||
     (e=mp64_dword(hive,key,L"Start",0))||
     (e=mp64_dword(hive,key,L"ErrorControl",1))||
     (e=mp64_string(hive,key,L"Group",REG_SZ,L"Filter"))||
     (e=mp64_string(hive,key,L"ImagePath",REG_EXPAND_SZ,L"system32\\drivers\\usosmpart.sys"))||
     (e=mp64_string(hive,key,L"DisplayName",REG_SZ,L"USOS USB multi-partition disk filter")))break;
  lstrcpyW(key,prefix);lstrcatW(key,MP64_CLASS);
  if((e=mp64_lower_filters(hive,key)))break;
 }
 if(!e)e=RegFlushKey(hive);
 RegCloseKey(hive);
 logcode("Mpart64: offline boot-start filter and disk class LowerFilters=",e);
 if(e!=ERROR_SUCCESS){
  BOOL back=CopyFileW(backup,hivefile,FALSE);
  logcode("Mpart64: SYSTEM restored from the backup (1 = yes)=",back);
  DeleteFileW(dst);return FALSE;
 }
 return TRUE;
}
