$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$prepared=Join-Path $project 'zig-out\vista\early-usb-v2'
$manifest=(Get-Content -LiteralPath (Join-Path $prepared 'repair.json') -Raw|ConvertFrom-Json).SYSTEM
function Hash($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
$disk=@(Get-Disk|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148'})
if($disk.Count -ne 1 -or $disk[0].FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $disk[0].Size -ne 120034123776 -or $disk[0].IsBoot -or $disk[0].IsSystem){throw 'Intel identity mismatch'}
$os=@(Get-Partition -DiskNumber $disk[0].Number|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'73dbde99-8026-4759-a19a-fd943e891d09'})
if($os.Count -ne 1 -or $os[0].DriveLetter -ne 'M' -or $os[0].Offset -ne 240123904 -or $os[0].Size -ne 119793516544 -or $os[0].IsBoot -or $os[0].IsSystem){throw 'Partition mismatch'}
$base='M:\';$config=Join-Path $base 'Windows\System32\config';$system=Join-Path $config 'SYSTEM'
if((Hash $system) -ne $manifest.original_sha256 -or (Hash (Join-Path $prepared 'SYSTEM')) -ne $manifest.patched_sha256){throw 'SYSTEM hash precondition failed'}
$backup=Join-Path $prepared ('backup-'+(Get-Date -Format yyyyMMdd-HHmmss));[IO.Directory]::CreateDirectory($backup)|Out-Null
foreach($f in Get-ChildItem -LiteralPath $config -File|Where-Object {$_.Name -eq 'SYSTEM' -or $_.Name.StartsWith('SYSTEM.')}){Copy-Item -LiteralPath $f.FullName -Destination $backup}
Copy-Item -LiteralPath (Join-Path $base 'Windows\Panther') -Destination $backup -Recurse
Copy-Item -LiteralPath (Join-Path $base 'Windows\inf\setupapi.dev.log') -Destination $backup
Copy-Item -LiteralPath (Join-Path $base 'USOS') -Destination $backup -Recurse
# The interrupted hardware boot left this volume dirty. Repair before writing
# a new startup hook; do not run a surface scan or format any partition.
& chkdsk.exe M: /f /x *> (Join-Path $backup 'chkdsk.log')
$code=$LASTEXITCODE;Write-Output "CHKDSK_EXIT=$code"
if($code -gt 1){throw 'Filesystem repair did not complete'}
if((Hash $system) -ne $manifest.original_sha256){throw 'SYSTEM changed during filesystem repair; prepare again'}
$sources=@{
 'USOS\usb.exe'=(Join-Path $project 'zig-out\vista\firstboot\usb.exe')
 'USOS\Vista\usos-vista-firstboot.exe'=(Join-Path $project 'zig-out\vista\firstboot\usos-vista-firstboot.exe')
}
try {
 foreach($rel in $sources.Keys){Copy-Item -LiteralPath $sources[$rel] -Destination (Join-Path $base $rel) -Force}
 foreach($rel in @('USOS\usb-bootstrap.log','USOS\Vista\firstboot-usb.log')){
  # Create the file now so a forced shutdown cannot hide whether it was opened.
  [IO.File]::AppendAllText((Join-Path $base $rel),"USOS USB v2 prepared on technician host; TARGET EXECUTION PENDING.`r`n",[Text.Encoding]::ASCII)
 }
 [IO.File]::Copy((Join-Path $prepared 'SYSTEM'),$system,$true)
 Write-VolumeCache -DriveLetter M
 if((Hash $system) -ne $manifest.patched_sha256){throw 'SYSTEM readback mismatch'}
 foreach($rel in $sources.Keys){if((Hash (Join-Path $base $rel)) -ne (Hash $sources[$rel])){throw "Helper readback mismatch: $rel"}}
 Write-Output "USB_V2_DEPLOYED; SHA256_READBACK=PASS; BACKUP=$backup; HARDWARE_USB_UNVERIFIED"
} catch {
 [IO.File]::Copy((Join-Path $backup 'SYSTEM'),$system,$true)
 foreach($rel in $sources.Keys){[IO.File]::Copy((Join-Path $backup $rel),(Join-Path $base $rel),$true)}
 Write-VolumeCache -DriveLetter M
 throw
}
& fsutil.exe dirty query M:
