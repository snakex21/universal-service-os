param([Parameter(Mandatory=$true)][string]$Prepared)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$folder=(Resolve-Path -LiteralPath $Prepared).Path
if(!$folder.StartsWith((Join-Path $project 'artifacts\xp-pae\setup-cmd-diag-'),[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected prepared directory'}
$part=Get-Partition -DriveLetter M
$disk=Get-Disk -Number $part.DiskNumber
if($disk.FriendlyName -notlike '*INTEL*' -or $disk.Size -ne 120034123776 -or $disk.IsBoot -or $disk.IsSystem -or $disk.PartitionStyle -ne 'MBR' -or $part.Offset -ne 1048576 -or $disk.Signature -ne 2225656991){throw 'Unexpected XP target'}
$installed=Get-Content -LiteralPath 'M:\USOS\XP\drivers-manifest.json' -Raw|ConvertFrom-Json
if($installed.id -ne '79b93ec0843a12c88abc68728fc9ae8f1e756f5807448d85be5eef46951389aa'){throw 'Unexpected XP source'}
function Hash($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
function Flush($p){$s=[IO.File]::Open($p,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read);try{$s.Flush($true)}finally{$s.Dispose()}}
$allowed=@{'system'='M:\WINDOWS\system32\config\system';'system.sav'='M:\WINDOWS\system32\config\system.sav';'d.cmd'='M:\d.cmd'}
$changes=Get-Content -LiteralPath (Join-Path $folder 'changes.json') -Raw|ConvertFrom-Json
if($changes.Count -ne 3 -or @($changes.file|Select-Object -Unique).Count -ne 3){throw 'Unexpected edit list'}
foreach($c in $changes){
 if(!$allowed.ContainsKey($c.file) -or [IO.Path]::GetFullPath($c.target) -ne $allowed[$c.file]){throw 'Unexpected target path'}
 if((Hash (Join-Path $folder $c.file)) -ne $c.after){throw 'Prepared hash mismatch'}
 if($null -eq $c.before){if([IO.File]::Exists($c.target)){throw 'Target unexpectedly exists'}}
 elseif((Hash $c.target) -ne $c.before -or (Hash (Join-Path $folder ($c.file+'.original'))) -ne $c.before){throw 'Original or backup hash mismatch'}
}
if((Hash 'M:\WINDOWS\system32\config\SYSTEM.LOG') -ne (Hash (Join-Path $folder 'SYSTEM.LOG.original'))){throw 'Transaction log changed'}
$disk|Select-Object Number,FriendlyName,Signature,Size|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $folder 'disk.json')
$written=@()
try{
 # Ensure the script exists before either hive refers to it.
 foreach($name in @('d.cmd','system.sav','system')){
  $c=$changes|Where-Object {$_.file -eq $name};$written+=$c
  [IO.File]::Copy((Join-Path $folder $c.file),$c.target,$true);Flush $c.target
  if((Hash $c.target) -ne $c.after){throw 'Readback mismatch'}
  Write-Output ('READBACK_OK='+$c.target)
 }
 Write-VolumeCache -DriveLetter M
}catch{
 foreach($c in $written){
  if($null -eq $c.before){Remove-Item -LiteralPath $c.target -Force}
  else{[IO.File]::Copy((Join-Path $folder ($c.file+'.original')),$c.target,$true);Flush $c.target}
 }
 Write-VolumeCache -DriveLetter M
 throw
}
Write-Output ('PASS: backed up, flushed and hash-verified; SYSTEM.LOG untouched; backup='+$folder)
