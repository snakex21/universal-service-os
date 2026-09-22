# Repair only the pre-Setup resume flag; preserve the serviced OS and packages.
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Hash($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
$p=Get-Partition -DriveLetter M;$d=$p|Get-Disk
if(([guid]$d.Guid) -ne [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148' -or $d.FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $d.Size -ne 120034123776 -or $d.IsBoot -or $d.IsSystem){throw 'Wrong disk'}
if(([guid]$p.Guid) -ne [guid]'73dbde99-8026-4759-a19a-fd943e891d09' -or $p.Offset -ne 240123904 -or $p.Size -ne 119793516544 -or $p.IsBoot -or $p.IsSystem){throw 'Wrong partition'}
$work=Join-Path $project ('zig-out\vista\resume-usb-v6-'+(Get-Date -Format yyyyMMdd-HHmmss));[IO.Directory]::CreateDirectory($work)|Out-Null
$system='M:\Windows\System32\config\SYSTEM';$software='M:\Windows\System32\config\SOFTWARE';$components='M:\Windows\System32\config\COMPONENTS'
$preserve=@{};foreach($f in @($software,$components,'M:\Windows\System32\drivers\Wdf01000.sys','M:\Windows\System32\drivers\WdfLdr.sys')){$preserve[$f]=Hash $f}
Copy-Item -LiteralPath 'M:\USOS' -Destination $work -Recurse
foreach($f in Get-ChildItem -LiteralPath 'M:\Windows\System32\config' -File|Where-Object {$_.Name -eq 'SYSTEM' -or $_.Name.StartsWith('SYSTEM.')}){Copy-Item -LiteralPath $f.FullName -Destination $work}
$prepared=Join-Path $work 'prepared'
& python (Join-Path $project 'tools\prepare_vista_early_usb.py') $system $prepared
if($LASTEXITCODE -ne 0){throw 'State preparation failed'}
$m=(Get-Content -LiteralPath (Join-Path $prepared 'repair.json') -Raw|ConvertFrom-Json).SYSTEM
if((Hash $system) -ne $m.original_sha256 -or (Hash (Join-Path $prepared 'SYSTEM')) -ne $m.patched_sha256){throw 'SYSTEM precondition failed'}
$new=Join-Path $project 'zig-out\vista\firstboot\usb.exe'
try {
 Copy-Item -LiteralPath $new -Destination 'M:\USOS\usb.exe' -Force
 [IO.File]::Copy((Join-Path $prepared 'SYSTEM'),$system,$true)
 Write-VolumeCache -DriveLetter M
 if((Hash $system) -ne $m.patched_sha256 -or (Hash $new) -ne (Hash 'M:\USOS\usb.exe')){throw 'Readback mismatch'}
 foreach($f in $preserve.Keys){if((Hash $f) -ne $preserve[$f]){throw 'Serviced package state changed'}}
 & python (Join-Path $project 'tools\verify_vista_usb_gate.py')
 if($LASTEXITCODE -ne 0){throw 'Resume state validation failed'}
 Write-Output "USB_RESUME_REARMED; READBACK=PASS; KMDF_AND_COMPONENT_STORE_UNCHANGED; BACKUP=$work"
} catch {
 [IO.File]::Copy((Join-Path $work 'SYSTEM'),$system,$true)
 [IO.File]::Copy((Join-Path $work 'USOS\usb.exe'),'M:\USOS\usb.exe',$true)
 Write-VolumeCache -DriveLetter M
 throw
}
