# Configure visible driver-loading diagnostics only on the identified Intel SSD.
param([switch]$Quiet)
$ErrorActionPreference='Stop'
$sos=if($Quiet){'No'}else{'Yes'}
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$disks=@(Get-Disk | Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148'})
if($disks.Count -ne 1 -or $disks[0].FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $disks[0].Size -ne 120034123776 -or $disks[0].IsBoot -or $disks[0].IsSystem){throw 'Intel identity mismatch'}
$disk=$disks[0]
$parts=@(Get-Partition -DiskNumber $disk.Number)
$esp=@($parts | Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'266ef7fa-2486-4050-892f-20c3bc889930'})
if($esp.Count -ne 1 -or $esp[0].Offset -ne 1048576 -or $esp[0].Size -ne 100MB -or ([guid]$esp[0].GptType) -ne [guid]'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'){throw 'ESP mismatch'}
function Hash($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash}
$backup=Join-Path $project ('zig-out/win7-universal-work/intel-before-sos-'+(Get-Date -Format yyyyMMdd-HHmmss))
[IO.Directory]::CreateDirectory($backup) | Out-Null
$assigned=$false;$changed=$false;$part=$esp[0]
try {
 if(-not $part.DriveLetter){$part | Add-PartitionAccessPath -AssignDriveLetter;$assigned=$true}
 $part=Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber
 $base="$($part.DriveLetter):\"
 foreach($rel in @('EFI/Microsoft/Boot/win7.efi','EFI/Boot/win7.efi')){
  if((Hash (Join-Path $base $rel)) -ne '7C545B00D705FFDFDE21F051DD96B8036BE00E063E27E74479845170C62B2FA4'){throw 'Patched INT10 loader not present'}
 }
 $bcd=Join-Path $base 'EFI/Microsoft/Boot/BCD'
 $old=Join-Path $backup 'BCD-original'
 $new=Join-Path $backup 'BCD-sos'
 [IO.File]::Copy($bcd,$old,$false)
 if((Hash $bcd) -ne (Hash $old)){throw 'Backup verification failed'}
 [IO.File]::Copy($old,$new,$false)
 $loader='{53bc7825-b510-11f1-9dfe-b47cf444e757}'
 $before=& bcdedit.exe /store $new /enum $loader /v
 if($LASTEXITCODE -ne 0 -or -not ($before -match '\\Windows\\system32\\winload\.efi')){throw 'Expected Windows loader entry missing'}
 & bcdedit.exe /store $new /set $loader sos $sos
 if($LASTEXITCODE -ne 0){throw 'Could not set SOS'}
 $after=& bcdedit.exe /store $new /enum $loader /v
 if($LASTEXITCODE -ne 0 -or -not ($after -match ('^sos\s+'+$sos+'\s*$')) -or -not ($after -match '^bootlog\s+Yes') -or -not ($after -match '^nocrashautoreboot\s+Yes')){throw 'Diagnostic settings verification failed'}
 $after | Set-Content -LiteralPath (Join-Path $backup 'bcd-after.txt')
 foreach($rel in @('EFI/Microsoft/Boot/UefiSeven.log','EFI/Microsoft/Boot/usos-boot.log','EFI/Microsoft/Boot/usos-amd-shadow.log')){
  $file=Get-Item -LiteralPath (Join-Path $base $rel)
  "$rel LASTWRITE_UTC=$($file.LastWriteTimeUtc.ToString('o')) SHA256=$(Hash $file.FullName)" | Add-Content -LiteralPath (Join-Path $backup 'efi-evidence.txt')
 }
 if((Hash $bcd) -ne (Hash $old)){throw 'BCD changed concurrently'}
 $changed=$true
 [IO.File]::Copy($new,$bcd,$true)
 if((Hash $bcd) -ne (Hash $new)){throw 'BCD readback mismatch'}
 $afterParts=@(Get-Partition -DiskNumber $disk.Number)
 if(($parts | Select-Object PartitionNumber,Guid,Offset,Size | ConvertTo-Json -Compress) -ne ($afterParts | Select-Object PartitionNumber,Guid,Offset,Size | ConvertTo-Json -Compress)){throw 'Partition layout changed'}
 Get-Content -LiteralPath (Join-Path $backup 'efi-evidence.txt')
 Write-Output "RESULT=PASS; sos=$sos bootlog=Yes nocrashautoreboot=Yes; patched EFI hashes verified; BACKUP=$backup"
} catch {
 if($changed){[IO.File]::Copy($old,$bcd,$true)}
 throw
} finally {if($assigned){$part | Remove-PartitionAccessPath -AccessPath $base}}
