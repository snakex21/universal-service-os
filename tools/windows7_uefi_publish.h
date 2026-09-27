/* Publish both UEFI entry points only after staging and checking every asset.
 * Existing third-party fallback loaders are never replaced. */
static int publish_loaders(void){
 static const WCHAR *dirs[]={L"EFI\\Microsoft\\Boot\\",L"EFI\\Boot\\"};
 static const WCHAR *loaders[]={L"bootmgfw.efi",L"bootx64.efi"};
 static const WCHAR *assets[]={L"win7.original.efi",L"win7.efi",L"UefiSeven.ini",L"uefiseven-LICENSE.txt"};
 WCHAR targets[2][MAX_PATH],pending[2][MAX_PATH];int exists[2];
 for(unsigned i=0;i<2;i++){
  path(targets[i],chosen,dirs[i]);copy(targets[i]+len(targets[i]),loaders[i]);
  exists[i]=GetFileAttributesW(targets[i])!=INVALID_FILE_ATTRIBUTES;
  path(b,base,L"win7.original.efi");
  if((i==0&&!exists[i])||(exists[i]&&!same_file(targets[i],b)))return say("UEFI: existing boot entry differs; no boot loaders changed.\r\n");
 }
 /* Every existing loader is now the boot manager Setup just wrote (checked above), so
  * any dispatcher assets in these folders are leftovers of an earlier USOS
  * install on a reused ESP (X470 2026-09-27: Windows 7's win7.original.efi
  * made the Vista publication fail). Remove only these known USOS files. */
 {
  static const WCHAR *stale[]={L"win7.original.efi",L"win7.efi",L"UefiSeven.ini",L"uefiseven-LICENSE.txt",L"usos-win7-new.efi"};
  /* Only in a folder whose own loader exists and was confirmed above. */
  for(unsigned i=0;i<2;i++)for(unsigned j=0;exists[i]&&j<5;j++){
   path(b,chosen,dirs[i]);copy(b+len(b),stale[j]);
   if(GetFileAttributesW(b)==INVALID_FILE_ATTRIBUTES)continue;
   SetFileAttributesW(b,FILE_ATTRIBUTE_NORMAL);
   if(!DeleteFileW(b))return say("UEFI: a stale USOS dispatcher file could not be removed; original loaders retained.\r\n");
   say("UEFI: removed a stale USOS dispatcher file from a reused ESP.\r\n");
  }
 }
 for(unsigned i=0;i<2;i++){
  path(b,chosen,dirs[i]);b[len(b)-1]=0;
  if(!CreateDirectoryW(b,0)&&GetLastError()!=ERROR_ALREADY_EXISTS)return 1;
  for(unsigned j=0;j<4;j++){
   path(a,base,assets[j]);path(b,chosen,dirs[i]);copy(b+len(b),assets[j]);
   if(GetFileAttributesW(b)==INVALID_FILE_ATTRIBUTES&&!CopyFileW(a,b,TRUE))return 1;
   if(!same_file(a,b))return say("UEFI: compatibility asset verification failed; original loaders retained.\r\n");
  }
  path(pending[i],chosen,dirs[i]);copy(pending[i]+len(pending[i]),L"usos-win7-new.efi");
  path(a,base,L"win7-wrapper.efi");
  if(!CopyFileW(a,pending[i],TRUE)||!same_file(a,pending[i]))return 1;
 }
 for(unsigned i=0;i<2;i++){
  path(b,base,L"win7.original.efi");
  if(exists[i]?!same_file(targets[i],b):GetFileAttributesW(targets[i])!=INVALID_FILE_ATTRIBUTES)return 1;
 }
 for(unsigned i=0;i<2;i++){
  if(!MoveFileExW(pending[i],targets[i],(exists[i]?MOVEFILE_REPLACE_EXISTING:0)|MOVEFILE_WRITE_THROUGH))return say("UEFI: boot entry publication failed; preserved original remains beside loader.\r\n");
  path(b,base,L"win7-wrapper.efi");if(!same_file(targets[i],b))return 1;
 }
 return 0;
}
