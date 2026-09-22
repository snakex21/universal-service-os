$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$package=Join-Path $project 'zig-out/windows7-int10-patch'
$source=Join-Path $package 'win7-int10-return.efi'
$manifest=Get-Content -LiteralPath (Join-Path $package 'manifest.json') -Raw | ConvertFrom-Json
function Hash($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash}
if((Hash $source) -ne $manifest.patched_sha256){throw 'Patched EFI checksum mismatch'}
$disks=@(Get-Disk | Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148'})
if($disks.Count -ne 1 -or $disks[0].FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $disks[0].Size -ne 120034123776 -or $disks[0].IsBoot -or $disks[0].IsSystem){throw 'Intel identity mismatch'}
$disk=$disks[0]
$layout=@(Get-Partition -DiskNumber $disk.Number)
$esp=@($layout | Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'266ef7fa-2486-4050-892f-20c3bc889930'})
if($esp.Count -ne 1 -or $esp[0].Size -ne 100MB -or $esp[0].Offset -ne 1048576 -or ([guid]$esp[0].GptType) -ne [guid]'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'){throw 'Intel ESP mismatch'}
$backup=Join-Path $project ('zig-out/win7-universal-work/intel-before-int10-return-'+(Get-Date -Format yyyyMMdd-HHmmss))
[IO.Directory]::CreateDirectory($backup) | Out-Null
$items=@('EFI/Microsoft/Boot/win7.efi','EFI/Boot/win7.efi','EFI/Microsoft/Boot/BCD')
$assigned=$false;$written=@();$part=$esp[0]
try {
 if(-not $part.DriveLetter){$part | Add-PartitionAccessPath -AssignDriveLetter;$assigned=$true}
 $part=Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber
 $base="$($part.DriveLetter):\"
 $guardHashes=@{}
 foreach($dir in @('EFI/Microsoft/Boot','EFI/Boot')){
  $p=Join-Path $base "$dir/win7.original.efi"
  if((Hash $p) -ne '7F5336F75511AC677D4877F8968876615E172EB2F08E54693DC655C310E7620D'){throw 'Original Windows loader changed'}
  $guardHashes[$p]=Hash $p
 }
 foreach($rel in @('EFI/Microsoft/Boot/bootmgfw.efi','EFI/Boot/bootx64.efi')){
  $p=Join-Path $base $rel
  if((Hash $p) -ne '25470C7C20B29C86C9F74C90023412530B1D6D005F806381B1E00B02724B7A1C'){throw 'Expected AMD compatibility wrapper missing'}
  $guardHashes[$p]=Hash $p
 }
 foreach($rel in $items){
  $target=Join-Path $base $rel
  if($rel.EndsWith('.efi') -and (Hash $target) -ne $manifest.original_sha256){throw 'Expected unmodified UefiSeven is missing'}
  $saved=Join-Path $backup $rel
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($saved)) | Out-Null
  [IO.File]::Copy($target,$saved,$false)
  if((Hash $target) -ne (Hash $saved)){throw 'Backup mismatch'}
 }
 $bcdRel='EFI/Microsoft/Boot/BCD'
 $bcdCandidate=Join-Path $backup 'BCD-with-bootlog'
 [IO.File]::Copy((Join-Path $backup $bcdRel),$bcdCandidate,$false)
 $loader='{53bc7825-b510-11f1-9dfe-b47cf444e757}'
 $before=& bcdedit.exe /store $bcdCandidate /enum $loader /v
 if($LASTEXITCODE -ne 0 -or -not ($before -match '\\Windows\\system32\\winload\.efi')){throw 'Expected Windows 7 loader entry missing'}
 foreach($flag in @('bootlog','nocrashautoreboot')){
  & bcdedit.exe /store $bcdCandidate /set $loader $flag Yes
  if($LASTEXITCODE -ne 0){throw "BCD option failed: $flag"}
 }
 $after=& bcdedit.exe /store $bcdCandidate /enum $loader /v
 if($LASTEXITCODE -ne 0 -or -not ($after -match 'bootlog\s+Yes') -or -not ($after -match 'nocrashautoreboot\s+Yes')){throw 'BCD readback mismatch'}
 $after | Set-Content -LiteralPath (Join-Path $backup 'bcd-after.txt')
 foreach($rel in $items){
  $target=Join-Path $base $rel
  if((Hash $target) -ne (Hash (Join-Path $backup $rel))){throw 'Concurrent change on Intel'}
  $replacement=if($rel -eq $bcdRel){$bcdCandidate}else{$source}
  $stage=$target+'.int10-new'
  [IO.File]::Copy($replacement,$stage,$false)
  if((Hash $replacement) -ne (Hash $stage)){throw 'Staged copy mismatch'}
  $written+=$rel
  [IO.File]::Copy($stage,$target,$true)
  if((Hash $target) -ne (Hash $replacement)){throw 'Readback mismatch'}
  Remove-Item -LiteralPath $stage
  Write-Output "VERIFIED $rel SHA256=$(Hash $target)"
 }
 foreach($p in $guardHashes.Keys){if((Hash $p) -ne $guardHashes[$p]){throw 'Unrelated bootloader changed'}}
 $afterLayout=@(Get-Partition -DiskNumber $disk.Number)
 if(($layout | Select-Object PartitionNumber,Guid,Offset,Size | ConvertTo-Json -Compress) -ne ($afterLayout | Select-Object PartitionNumber,Guid,Offset,Size | ConvertTo-Json -Compress)){throw 'Partition layout changed'}
 Copy-Item -LiteralPath (Join-Path $package 'manifest.json') -Destination (Join-Path $backup 'patch-manifest.json')
 Write-Output "RESULT=PASS; BACKUP=$backup; Windows files and partition layout unchanged; bootlog enabled"
} catch {
 foreach($rel in $written){[IO.File]::Copy((Join-Path $backup $rel),(Join-Path $base $rel),$true)}
 throw
} finally {if($assigned){$part | Remove-PartitionAccessPath -AccessPath $base}}
