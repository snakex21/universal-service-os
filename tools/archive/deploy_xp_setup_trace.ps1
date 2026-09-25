$ErrorActionPreference='Stop'
$part=Get-Partition -DriveLetter M
$disk=Get-Disk -Number $part.DiskNumber
if($disk.FriendlyName -notlike '*INTEL*' -or $disk.Size -ne 120034123776 -or $disk.IsBoot -or $disk.IsSystem -or $part.Offset -ne 1048576 -or $disk.Signature -ne 2225656991){throw 'Unexpected XP target'}
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stage=Join-Path $project 'artifacts\xp-pae\setup-trace-v3'
$changes=Get-Content -LiteralPath (Join-Path $stage 'changes.json') -Raw|ConvertFrom-Json
$config='M:\WINDOWS\system32\config'
foreach($entry in $changes){
 $path=Join-Path $config $entry.file
 if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.original_sha256){throw "Target changed: $path"}
}
$backup=Join-Path $stage ('backup-'+(Get-Date -Format yyyyMMdd-HHmmss))
[IO.Directory]::CreateDirectory($backup)|Out-Null
foreach($entry in $changes){
 foreach($suffix in @('','.LOG','.LOG1','.LOG2')){
  $src=Join-Path $config ($entry.file+$suffix)
  if(Test-Path -LiteralPath $src){[IO.File]::Copy($src,(Join-Path $backup ($entry.file+$suffix)),$false)}
 }
}
$target='M:\USOS\x.exe'
if(Test-Path -LiteralPath $target){throw 'Trace helper already present'}
[IO.Directory]::CreateDirectory('M:\USOS\XP')|Out-Null
[IO.File]::Copy((Join-Path $stage 'setup-trace.exe'),$target,$false)
if((Get-FileHash -LiteralPath (Join-Path $stage 'setup-trace.exe')).Hash -ne (Get-FileHash -LiteralPath $target).Hash){throw 'Helper readback mismatch before arming'}
foreach($entry in $changes){
 $src=Join-Path $stage $entry.file;$dst=Join-Path $config $entry.file
 try {
  [IO.File]::Copy($src,$dst,$true)
  $stream=[IO.File]::Open($dst,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  try{$stream.Flush($true)}finally{$stream.Dispose()}
  if((Get-FileHash -LiteralPath $src).Hash -ne (Get-FileHash -LiteralPath $dst).Hash){throw "Readback mismatch: $dst"}
 }catch{[IO.File]::Copy((Join-Path $backup $entry.file),$dst,$true);throw}
 Write-Output "READBACK_OK=$dst"
}
if((Get-FileHash -LiteralPath (Join-Path $stage 'setup-trace.exe')).Hash -ne (Get-FileHash -LiteralPath $target).Hash){throw 'Helper readback mismatch'}
Write-Output "BACKUP=$backup"
Write-Output 'DEPLOYED=XP Setup supervisor + timestamped verbose SetupAPI with per-entry flushing; no driver/kernel/PAE change'
