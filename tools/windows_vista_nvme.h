/* Own Vista/2008 amd64 NVMe staging. Called only after the selected fresh
 * CSMWrap target was identified and armed. The package is opt-in at build
 * time; this code never changes BCD signing policy. */
static LONG nv64_dword(HKEY hive,const WCHAR *path,const WCHAR *name,DWORD value){
 return RegSetKeyValueW(hive,path,name,REG_DWORD,&value,sizeof(value));
}
static LONG nv64_string(HKEY hive,const WCHAR *path,const WCHAR *name,DWORD type,const WCHAR *value){
 return RegSetKeyValueW(hive,path,name,type,value,(lstrlenW(value)+1)*sizeof(WCHAR));
}
static BOOL install_nvme64(const Target *t){
 if(!csm_target_nvme)return TRUE;
 static const WCHAR *const from[]={L"usosnvme-nt6.sys",L"usosnvme.inf",L"usosnvme.cat",L"usosnvme.cer"};
 static const WCHAR *const to[]={L"usosnvme.sys",L"usosnvme.inf",L"usosnvme.cat",L"usosnvme.cer"};
 WCHAR src[MAX_PATH],dst[MAX_PATH],hivefile[MAX_PATH],backup[MAX_PATH],key[160],cdd[180];BYTE a[32],b[32];
 for(unsigned i=0;i<4;i++){
  path(src,base,from[i]);path(dst,t->root,L"USOS\\nvme\\");lstrcatW(dst,to[i]);
  if(!mkdirs(dst)||!CopyFileW(src,dst,FALSE)||!hash_file(src,a)||!hash_file(dst,b)||!same(a,b,32))return FALSE;
 }
 path(src,base,from[0]);path(dst,t->root,L"Windows\\System32\\drivers\\usosnvme.sys");
 if(!CopyFileW(src,dst,FALSE)||!hash_file(dst,b)||!hash_file(src,a)||!same(a,b,32))return FALSE;
 path(hivefile,t->root,L"Windows\\System32\\config\\SYSTEM");
 path(backup,t->root,L"USOS\\Vista\\SYSTEM.before-nvme");
 if(!CopyFileW(hivefile,backup,TRUE))return FALSE;
 HKEY hive=0;LONG e=RegLoadAppKeyW(hivefile,&hive,KEY_ALL_ACCESS,0,0);
 if(e!=ERROR_SUCCESS){logcode("NVMe64: load offline SYSTEM=",e);return FALSE;}
 DWORD current=0,def=0,size=sizeof(DWORD),type=0;
 e=RegGetValueW(hive,L"Select",L"Current",RRF_RT_REG_DWORD,&type,&current,&size);
 if(e==ERROR_SUCCESS){size=sizeof(DWORD);e=RegGetValueW(hive,L"Select",L"Default",RRF_RT_REG_DWORD,&type,&def,&size);}
 if(!current||current>999||!def||def>999)e=ERROR_INVALID_DATA;
 for(unsigned pass=0;e==ERROR_SUCCESS&&pass<2;pass++){
  DWORD cs=pass?def:current;if(pass&&cs==current)continue;
  WCHAR prefix[24]=L"ControlSet000";prefix[10]=L'0'+cs/100;prefix[11]=L'0'+(cs/10)%10;prefix[12]=L'0'+cs%10;
  lstrcpyW(key,prefix);lstrcatW(key,L"\\Services\\usosnvme");
  if((e=nv64_dword(hive,key,L"Type",1))||
     (e=nv64_dword(hive,key,L"Start",0))||
     (e=nv64_dword(hive,key,L"ErrorControl",1))||
     (e=nv64_string(hive,key,L"Group",REG_SZ,L"SCSI miniport"))||
     (e=nv64_string(hive,key,L"ImagePath",REG_EXPAND_SZ,L"system32\\drivers\\usosnvme.sys")))break;
  lstrcatW(key,L"\\Parameters\\PnpInterface");if((e=nv64_dword(hive,key,L"5",1)))break;
  lstrcpyW(cdd,prefix);lstrcatW(cdd,L"\\Control\\CriticalDeviceDatabase\\pci#cc_010802");
  if((e=nv64_string(hive,cdd,L"Service",REG_SZ,L"usosnvme"))||
     (e=nv64_string(hive,cdd,L"ClassGUID",REG_SZ,L"{4D36E97B-E325-11CE-BFC1-08002BE10318}")))break;
 }
 if(!e)e=RegFlushKey(hive);
 RegCloseKey(hive);
 logcode("NVMe64: offline boot service and CDD=",e);
 if(e!=ERROR_SUCCESS){CopyFileW(backup,hivefile,FALSE);return FALSE;}
 return TRUE;
}
