# Restore only absent, original XP USB/HID dependencies on the identified Intel.
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$package=Join-Path $project 'zig-out\xp-uefi-csm'
$manifest=Get-Content -LiteralPath (Join-Path $package 'manifest.json') -Raw|ConvertFrom-Json
$part=Get-Partition -DriveLetter M
$installedId=(Get-Content -LiteralPath 'M:\USOS\XP\drivers-manifest.json' -Raw|ConvertFrom-Json).id
$entry=@($manifest.driver_sources|Where-Object {$_.bundle -eq $installedId})[0]
if(!$entry){$entry=$manifest.added_source}
$source=Join-Path $package ('drivers\'+$entry.sha256)
$report=Get-Content -LiteralPath (Join-Path $source 'bundle\manifest.json') -Raw|ConvertFrom-Json
$disk=Get-Disk -Number $part.DiskNumber
if($disk.FriendlyName -notlike '*INTEL*' -or $disk.Size -ne 120034123776 -or $disk.IsBoot -or $disk.IsSystem -or $disk.PartitionStyle -ne 'MBR' -or $part.Offset -ne 1048576 -or $disk.Signature -ne 2225656991){throw 'Unexpected XP target'}
$installed=Get-Content -LiteralPath 'M:\USOS\XP\drivers-manifest.json' -Raw|ConvertFrom-Json
if($installed.id -ne $report.id -or $installed.source -ne $report.source){throw 'Installed XP source differs from repair source'}
function Hash($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
$files=@()
foreach($name in @('usbport.sys','usbd.sys','hidclass.sys','hidparse.sys')){
 $src=Join-Path $source ('native-usb\'+$name)
 $dst=Join-Path 'M:\WINDOWS\system32\drivers' $name
 $expected=$report.native_usb_dependencies.$name
 if(!$expected -or (Hash $src) -ne $expected){throw "Repair source mismatch: $name"}
 if(Test-Path -LiteralPath $dst){if((Hash $dst) -ne $expected){throw "Different installed file: $name"}}else{$files+=@{Source=$src;Target=$dst;Sha256=$expected}}
}
$out=Join-Path $project ('artifacts\xp-pae\native-usb-repair-'+(Get-Date -Format yyyyMMdd-HHmmss))
[IO.Directory]::CreateDirectory($out)|Out-Null
$files|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $out 'files.json')
$disk|Select-Object Number,FriendlyName,Signature,Size|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $out 'disk.json')
$written=@()
try{
 foreach($file in $files){
  [IO.File]::Copy($file.Source,$file.Target,$false)
  $written+=$file.Target
  $stream=[IO.File]::Open($file.Target,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  try{$stream.Flush($true)}finally{$stream.Dispose()}
  if((Hash $file.Target) -ne $file.Sha256){throw 'Repair readback mismatch'}
  Write-Output ('READBACK_OK='+$file.Target)
 }
 Write-VolumeCache -DriveLetter M
}catch{
 foreach($path in $written){Remove-Item -LiteralPath $path -Force}
 throw
}
Write-Output "PASS: added $($files.Count) missing original USB/HID files; no registry, kernel, setup state or partition changes; record=$out"
