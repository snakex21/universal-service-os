param([switch]$Restore,[switch]$Direct)
$ErrorActionPreference='Stop'
if($Restore -and $Direct){throw 'Choose Restore or Direct, not both'}
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$package=Join-Path $project 'zig-out/csmwrap-trial'
$disks=@(Get-Disk | Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'31c644bf-74dd-4807-9cb2-46745adeadd4'})
if($disks.Count -ne 1){throw 'Expected Kingston test USB is not connected'}
$disk=$disks[0]
if($disk.FriendlyName -ne 'Kingston DataTraveler 3.0' -or $disk.Size -ne 61991813632 -or $disk.IsBoot -or $disk.IsSystem){throw 'USB identity mismatch'}
$parts=@(Get-Partition -DiskNumber $disk.Number)
$esp=@($parts | Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'0257e175-1685-4311-91aa-5a83d8eb41e5'})
if($esp.Count -ne 1 -or -not $esp[0].DriveLetter -or $esp[0].Offset -ne 1048576 -or $esp[0].Size -ne 1073741824){throw 'ESP identity mismatch'}
$root="$($esp[0].DriveLetter):\"
$entry=Join-Path $root 'EFI/BOOT/BOOTX64.EFI'
$original=Join-Path $root 'EFI/BOOT/USOS-original.efi'
$originalHash='3008D265B13343FC694BD6FFF3985B1D67884A79C684472BE39A767F8F2A5B5D'
$csmwrapHash='96FDB387E177C6340287B7E07713DC09BF1F965DD404311EAFD9C6EB99A02745'
function Hash($path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
function CopyChecked($source,$target){
 [IO.File]::Copy($source,$target,$false)
 if((Hash $source) -ne (Hash $target)){throw "Copy verification failed: $target"}
}
function MbrHash {
 $stream=[IO.File]::Open(('\\.\PhysicalDrive'+$disk.Number),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 try {
  $bytes=New-Object byte[] 512
  if($stream.Read($bytes,0,512) -ne 512){throw 'Short MBR read'}
  $sha=[Security.Cryptography.SHA256]::Create()
  try {[BitConverter]::ToString($sha.ComputeHash($bytes))} finally {$sha.Dispose()}
 } finally {$stream.Dispose()}
}
$mbrBefore=MbrHash
$layoutBefore=$parts | Select-Object PartitionNumber,Guid,Offset,Size | ConvertTo-Json -Compress
if($Restore){
 if((Hash $original) -ne $originalHash){throw 'Original USB bootloader checksum mismatch'}
 if((Hash $entry) -notin @((Hash (Join-Path $package 'BOOTX64.EFI')),$csmwrapHash)){throw 'USB entry changed; refusing to replace it'}
 [IO.File]::Copy($original,$entry,$true)
 if((Hash $entry) -ne $originalHash){throw 'Restore verification failed'}
 Write-Output 'RESTORED: original USOS boot entry; optional CSMWrap files retained'
} elseif($Direct) {
 if((Hash $original) -ne $originalHash){throw 'Original USB bootloader checksum mismatch'}
 $menu=Join-Path $root 'EFI/CSMWrap/trial-menu.efi'
 $source=Join-Path $root 'EFI/CSMWrap/csmwrapx64.efi'
 if((Hash $entry) -ne (Hash (Join-Path $package 'BOOTX64.EFI')) -or (Hash $menu) -ne (Hash $entry)){throw 'USB entry is not the verified trial menu'}
 if((Hash $source) -ne $csmwrapHash){throw 'CSMWrap checksum mismatch'}
 $config=Join-Path $root 'EFI/BOOT/csmwrap.ini'
 if(Test-Path -LiteralPath $config){throw 'CSMWrap configuration already exists beside BOOTX64.EFI'}
 CopyChecked (Join-Path $package 'csmwrap.ini') $config
 try {
  [IO.File]::Copy($source,$entry,$true)
  if((Hash $entry) -ne $csmwrapHash){throw 'Direct CSMWrap readback mismatch'}
 } catch {
  [IO.File]::Copy($menu,$entry,$true)
  throw
 }
 Write-Output "VERIFIED: direct CSMWrap SHA256=$(Hash $entry); verbose=true; original USOS backup verified"
} else {
 if((Hash $entry) -ne $originalHash){throw 'USB boot entry is not the expected pre-trial build'}
 if(Test-Path -LiteralPath $original){throw 'A trial backup already exists; inspect before redeploying'}
 $destination=Join-Path $root 'EFI/CSMWrap'
 if(Test-Path -LiteralPath $destination){throw 'CSMWrap directory already exists; refusing overwrite'}
 $manifest=Get-Content -LiteralPath (Join-Path $package 'manifest.json') -Raw | ConvertFrom-Json
 foreach($p in $manifest.files.PSObject.Properties){
  if((Hash (Join-Path $package $p.Name)) -ne $p.Value){throw ('Vendor hash mismatch: '+$p.Name)}
 }
 $backup=Join-Path $project ('zig-out/csmwrap-trial-backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
 [IO.Directory]::CreateDirectory($backup) | Out-Null
 CopyChecked $entry (Join-Path $backup 'BOOTX64.EFI')
 $layoutBefore | Set-Content -LiteralPath (Join-Path $backup 'partitions.json')
 $mbrBefore | Set-Content -LiteralPath (Join-Path $backup 'mbr.sha256')
 [IO.Directory]::CreateDirectory($destination) | Out-Null
 $entryChanged=$false
 try {
  foreach($name in @('csmwrapx64.efi','csmwrap.ini','README.md','LICENSE','manifest.json')){
   CopyChecked (Join-Path $package $name) (Join-Path $destination $name)
  }
  CopyChecked $entry $original
  $stage=Join-Path $destination 'trial-menu.efi'
  CopyChecked (Join-Path $package 'BOOTX64.EFI') $stage
  $entryChanged=$true
  [IO.File]::Copy($stage,$entry,$true)
  if((Hash $entry) -ne (Hash $stage)){throw 'USB entry readback mismatch'}
  Write-Output "VERIFIED: trial menu SHA256=$(Hash $entry)"
  Write-Output "VERIFIED: CSMWrap SHA256=$(Hash (Join-Path $destination 'csmwrapx64.efi'))"
  Write-Output "VERIFIED: original USOS SHA256=$(Hash $original)"
  Write-Output "BACKUP=$backup"
 } catch {
  if($entryChanged){[IO.File]::Copy((Join-Path $backup 'BOOTX64.EFI'),$entry,$true)}
  throw
 }
}
$layoutAfter=Get-Partition -DiskNumber $disk.Number | Select-Object PartitionNumber,Guid,Offset,Size | ConvertTo-Json -Compress
if($layoutBefore -ne $layoutAfter -or $mbrBefore -ne (MbrHash)){throw 'Disk layout or MBR changed'}
Write-Output "RESULT=PASS; ESP=$root; partition layout and MBR unchanged; DATA and Intel untouched"
