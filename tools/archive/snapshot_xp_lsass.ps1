$ErrorActionPreference='Stop'
$part=Get-Partition -DriveLetter M
$disk=Get-Disk -Number $part.DiskNumber
if($disk.FriendlyName -notlike '*INTEL*' -or $disk.Size -ne 120034123776 -or $disk.IsBoot -or $disk.IsSystem -or $part.Offset -ne 1048576){throw 'Unexpected XP target'}
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$out=Join-Path $project ('artifacts\xp-pae\lsass-'+(Get-Date -Format yyyyMMdd-HHmmss))
[IO.Directory]::CreateDirectory($out)|Out-Null
$disk|Select-Object Number,FriendlyName,SerialNumber,Signature,PartitionStyle,Size|ConvertTo-Json|Set-Content (Join-Path $out 'disk.json')
Get-ChildItem -LiteralPath 'M:\' -Force|Select-Object Name,Length,LastWriteTime|Format-Table -AutoSize
foreach($dir in @('WINDOWS','WINXP','WINNT')){
 $os=Join-Path 'M:\' $dir
 if(!(Test-Path -LiteralPath (Join-Path $os 'System32\config\SYSTEM'))){continue}
 Write-Output "XP_OS=$os"
 foreach($rel in @('setupact.log','setuperr.log','setupapi.log','setuplog.txt','winnt32.log','ntbtlog.txt','repair\setup.log','System32\config\SYSTEM','System32\config\SYSTEM.LOG','System32\config\SOFTWARE','System32\config\SOFTWARE.LOG','System32\config\SysEvent.Evt','System32\config\AppEvent.Evt')){
  $src=Join-Path $os $rel
  if(Test-Path -LiteralPath $src){$dst=Join-Path $out ($dir+'\'+$rel);[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dst))|Out-Null;[IO.File]::Copy($src,$dst,$false)}
 }
}
foreach($rel in @('boot.ini','USOS\XP\drivers-manifest.json','USOS\XP\pae.log','USOS\XP\pae-install.log','$WIN_NT$.~BT\WINNT.SIF','$WIN_NT$.~BT\MIGRATE.INF')){
 $src=Join-Path 'M:\' $rel
 if(Test-Path -LiteralPath $src){$dst=Join-Path $out $rel;[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dst))|Out-Null;[IO.File]::Copy($src,$dst,$false)}
}
if(Test-Path -LiteralPath 'M:\USOS'){
 $traceDir=Join-Path $out 'USOS'
 [IO.Directory]::CreateDirectory($traceDir)|Out-Null
 Get-ChildItem -LiteralPath 'M:\USOS' -File -Filter '*.log'|Copy-Item -Destination $traceDir
}
if(Test-Path -LiteralPath 'J:\EFI\USOS-XP'){
 Get-ChildItem -LiteralPath 'J:\EFI\USOS-XP' -File|Where-Object {$_.Extension -in '.log','.txt','.ini'}|Copy-Item -Destination $out
}
Write-Output "SNAPSHOT=$out"
Get-ChildItem -LiteralPath $out -Recurse -File|Select-Object FullName,Length|Format-Table -AutoSize
