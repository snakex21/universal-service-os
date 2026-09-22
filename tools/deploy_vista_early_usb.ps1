$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$prepared=Join-Path $project 'zig-out\vista\early-usb'
$manifest=(Get-Content -LiteralPath (Join-Path $prepared 'repair.json') -Raw|ConvertFrom-Json).SYSTEM
$newBcd=Join-Path $project 'zig-out\vista\bcd-complete-v5\BCD'
$bootstrap=Join-Path $project 'zig-out\vista\firstboot\usb.exe'
$helper=Join-Path $project 'zig-out\vista\firstboot\usos-vista-firstboot.exe'
function Hash($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
$disk=@(Get-Disk|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148'})
if($disk.Count -ne 1 -or $disk[0].FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $disk[0].Size -ne 120034123776 -or $disk[0].IsBoot -or $disk[0].IsSystem){throw 'Intel identity mismatch'}
$parts=@(Get-Partition -DiskNumber $disk[0].Number)
$os=@($parts|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'73dbde99-8026-4759-a19a-fd943e891d09'})
$esp=@($parts|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'266ef7fa-2486-4050-892f-20c3bc889930'})
if($os.Count -ne 1 -or -not $os[0].DriveLetter -or $os[0].Offset -ne 240123904 -or $os[0].Size -ne 119793516544 -or $os[0].IsBoot -or $os[0].IsSystem -or $esp.Count -ne 1 -or $esp[0].Size -ne 100MB -or $esp[0].Offset -ne 1048576){throw 'Partition mismatch'}
$base="$($os[0].DriveLetter):\";$config=Join-Path $base 'Windows\System32\config';$system=Join-Path $config 'SYSTEM'
if((Hash $system) -ne $manifest.original_sha256 -or (Hash (Join-Path $prepared 'SYSTEM')) -ne $manifest.patched_sha256){throw 'SYSTEM checksum precondition failed'}
$backup=Join-Path $prepared ('backup-'+(Get-Date -Format yyyyMMdd-HHmmss));[IO.Directory]::CreateDirectory($backup)|Out-Null
foreach($f in Get-ChildItem -LiteralPath $config -File|Where-Object {$_.Name -eq 'SYSTEM' -or $_.Name.StartsWith('SYSTEM.')}){Copy-Item -LiteralPath $f.FullName -Destination $backup}
Copy-Item -LiteralPath (Join-Path $base 'Windows\Panther') -Destination $backup -Recurse
Copy-Item -LiteralPath (Join-Path $base 'USOS\Vista\usos-vista-firstboot.exe') -Destination (Join-Path $backup 'firstboot-before.exe')
$part=$esp[0];$assigned=$false;$writing=$false
try {
 if(-not $part.DriveLetter){$part|Add-PartitionAccessPath -AssignDriveLetter;$assigned=$true}
 $part=Get-Partition -DiskNumber $disk[0].Number -PartitionNumber $part.PartitionNumber
 $espRoot="$($part.DriveLetter):\";$bcd=Join-Path $espRoot 'EFI\Microsoft\Boot\BCD'
 Copy-Item -LiteralPath $bcd -Destination (Join-Path $backup 'BCD-before')
 foreach($id in @('{bootmgr}','{memdiag}')){
  & bcdedit.exe /store $newBcd /set $id device "partition=$($part.DriveLetter):" | Out-Null
  if($LASTEXITCODE -ne 0){throw 'Cannot set ESP device'}
 }
 & bcdedit.exe /store $newBcd /set '{default}' detecthal Yes | Out-Null
 if($LASTEXITCODE -ne 0){throw 'Cannot set Vista HAL detection'}
 & bcdedit.exe /store $newBcd /deletevalue '{default}' recoveryenabled | Out-Null
 if($LASTEXITCODE -ne 0){throw 'Cannot remove old recovery flag'}
 & bcdedit.exe /store $newBcd /enum all /v | Set-Content -LiteralPath (Join-Path $backup 'bcd-new.txt')
 if($LASTEXITCODE -ne 0){throw 'BCD validation failed'}
 $writing=$true
 Copy-Item -LiteralPath $bootstrap -Destination (Join-Path $base 'USOS\usb.exe') -Force
 Copy-Item -LiteralPath $helper -Destination (Join-Path $base 'USOS\Vista\usos-vista-firstboot.exe') -Force
 [IO.File]::Copy($newBcd,$bcd,$true)
 if((Hash $system) -ne $manifest.original_sha256){throw 'SYSTEM changed during preparation'}
 [IO.File]::Copy((Join-Path $prepared 'SYSTEM'),$system,$true)
 if((Hash $system) -ne $manifest.patched_sha256 -or (Hash $bcd) -ne (Hash $newBcd) -or (Hash (Join-Path $base 'USOS\usb.exe')) -ne (Hash $bootstrap) -or (Hash (Join-Path $base 'USOS\Vista\usos-vista-firstboot.exe')) -ne (Hash $helper)){throw 'Readback hash mismatch'}
 Write-VolumeCache -DriveLetter $os[0].DriveLetter
 Write-VolumeCache -DriveLetter $part.DriveLetter
 Write-Output "EARLY_USB_AND_COMPLETE_BCD_DEPLOYED; SHA256_READBACK=PASS; BACKUP=$backup; HARDWARE_BOOT_PENDING"
} catch {
 if($writing){
  [IO.File]::Copy((Join-Path $backup 'SYSTEM'),$system,$true)
  [IO.File]::Copy((Join-Path $backup 'BCD-before'),$bcd,$true)
  [IO.File]::Copy((Join-Path $backup 'firstboot-before.exe'),(Join-Path $base 'USOS\Vista\usos-vista-firstboot.exe'),$true)
 }
 throw
} finally {if($assigned){$part|Remove-PartitionAccessPath -AccessPath $espRoot}}
