$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$prepared=Join-Path $project 'zig-out\vista\drive-mapping-repair-v2'
$manifest=Get-Content -LiteralPath (Join-Path $prepared 'repair.json') -Raw | ConvertFrom-Json
$disk=@(Get-Disk | Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148'})
if($disk.Count -ne 1 -or $disk[0].FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $disk[0].Size -ne 120034123776 -or $disk[0].IsBoot -or $disk[0].IsSystem){throw 'Intel identity mismatch'}
$os=@(Get-Partition -DiskNumber $disk[0].Number | Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'73dbde99-8026-4759-a19a-fd943e891d09'})
if($os.Count -ne 1 -or $os[0].Offset -ne 240123904 -or $os[0].Size -ne 119793516544 -or -not $os[0].DriveLetter -or $os[0].IsBoot -or $os[0].IsSystem){throw 'Intel Windows partition mismatch'}
$base="$($os[0].DriveLetter):\"
$config=Join-Path $base 'Windows\System32\config'
function Hash($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
foreach($name in @('SYSTEM','SOFTWARE')){
 if((Hash (Join-Path $config $name)) -ne $manifest.$name.original_sha256){throw "Target $name changed since preparation"}
 if((Hash (Join-Path $prepared $name)) -ne $manifest.$name.patched_sha256){throw "Prepared $name checksum mismatch"}
}
$backup=Join-Path $prepared ('backup-'+(Get-Date -Format yyyyMMdd-HHmmss))
[IO.Directory]::CreateDirectory($backup)|Out-Null
foreach($name in @('SYSTEM','SOFTWARE')){
 foreach($file in Get-ChildItem -LiteralPath $config -File | Where-Object {$_.Name -eq $name -or $_.Name.StartsWith($name+'.')}){
  [IO.File]::Copy($file.FullName,(Join-Path $backup $file.Name),$false)
 }
}
$written=@()
try {
 foreach($name in @('SYSTEM','SOFTWARE')){
  if((Hash (Join-Path $config $name)) -ne $manifest.$name.original_sha256){throw "Concurrent $name change"}
  $written+=$name
  [IO.File]::Copy((Join-Path $prepared $name),(Join-Path $config $name),$true)
  if((Hash (Join-Path $config $name)) -ne $manifest.$name.patched_sha256){throw "$name readback mismatch"}
 }
 Write-VolumeCache -DriveLetter $os[0].DriveLetter
} catch {
 foreach($name in $written){[IO.File]::Copy((Join-Path $backup $name),(Join-Path $config $name),$true)}
 throw
}
@('REPAIR=2026-09-20 preserve original Vista image drive letter D:', 'USB_HELPER_LOG=%SystemDrive%\USOS\Vista\firstboot-usb.log', 'NEXT_HARDWARE_BOOT=PENDING') | Add-Content -LiteralPath (Join-Path $base 'USOS\Vista\deployment.txt')
Write-VolumeCache -DriveLetter $os[0].DriveLetter
Write-Output "VISTA_DRIVE_MAPPING_REPAIR_APPLIED; SHA256_READBACK=PASS; VISTA_SYSTEM_DRIVE=D:; BACKUP=$backup"
