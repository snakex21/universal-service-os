param([Parameter(Mandatory=$true)][string]$Prepared)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$folder=(Resolve-Path -LiteralPath $Prepared).Path
if(!$folder.StartsWith((Join-Path $project 'artifacts\xp-pae\dump-workaround-'),[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected prepared directory'}
$part=Get-Partition -DriveLetter M
$disk=Get-Disk -Number $part.DiskNumber
if($disk.FriendlyName -notlike '*INTEL*' -or $disk.Size -ne 120034123776 -or $disk.IsBoot -or $disk.IsSystem -or $disk.PartitionStyle -ne 'MBR' -or $part.Offset -ne 1048576 -or $disk.Signature -ne 2225656991){throw 'Unexpected XP target'}
$installed=Get-Content -LiteralPath 'M:\USOS\XP\drivers-manifest.json' -Raw|ConvertFrom-Json
if($installed.id -ne '79b93ec0843a12c88abc68728fc9ae8f1e756f5807448d85be5eef46951389aa'){throw 'Unexpected installed XP bundle'}
$change=Get-Content -LiteralPath (Join-Path $folder 'repair.json') -Raw|ConvertFrom-Json
if(!$change.all_registry_values_verified -or $change.value -ne 'CrashDumpEnabled' -or $change.old -ne 3 -or $change.new -ne 0){throw 'Unexpected prepared edit'}
function Hash($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
$target='M:\WINDOWS\system32\config\SYSTEM'
$replacement=Join-Path $folder 'SYSTEM'
if((Hash $target) -ne $change.original_sha256 -or (Hash (Join-Path $folder 'SYSTEM.original')) -ne $change.original_sha256 -or (Hash $replacement) -ne $change.patched_sha256){throw 'Hive changed or backup mismatch'}
foreach($name in @('SYSTEM.LOG','SYSTEM.SAV')){
 $path=Join-Path 'M:\WINDOWS\system32\config' $name
 if(Test-Path -LiteralPath $path){Copy-Item -LiteralPath $path -Destination (Join-Path $folder $name)}
}
$disk|Select-Object Number,FriendlyName,Signature,Size|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $folder 'disk.json')
try{
 [IO.File]::Copy($replacement,$target,$true)
 $stream=[IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read)
 try{$stream.Flush($true)}finally{$stream.Dispose()}
 if((Hash $target) -ne $change.patched_sha256){throw 'Readback mismatch'}
 Write-VolumeCache -DriveLetter M
}catch{
 [IO.File]::Copy((Join-Path $folder 'SYSTEM.original'),$target,$true)
 Write-VolumeCache -DriveLetter M
 throw
}
Write-Output 'READBACK_OK: Intel SYSTEM matches verified hive; CrashDumpEnabled=0; AutoReboot=0 retained'
Write-Output ('BACKUP='+$folder)
