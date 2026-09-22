$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$disk=Get-Disk -Number (Get-Partition -DriveLetter M).DiskNumber
if($disk.FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $disk.Size -ne 120034123776 -or ([guid]$disk.Guid) -ne [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148' -or $disk.IsBoot -or $disk.IsSystem){throw 'Wrong target'}
$esp=@(Get-Partition -DiskNumber $disk.Number|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'266ef7fa-2486-4050-892f-20c3bc889930'})
if($esp.Count -ne 1 -or (Test-Path Z:\)){throw 'ESP/alias guard failed'}
$out=Join-Path $project ('artifacts\vista\offline-kmdf-'+(Get-Date -Format yyyyMMdd-HHmmss))
[IO.Directory]::CreateDirectory((Join-Path $out 'scratch'))|Out-Null
foreach($name in @('SYSTEM','SOFTWARE','COMPONENTS')){Copy-Item -LiteralPath ('M:\Windows\System32\config\'+$name) -Destination (Join-Path $out $name)}
$cab='M:\USOS\Vista\Updates\Windows6.0-KB2864202-x64.cab'
$reference=Join-Path $project 'artifacts\vista\hardware-success-v11-20260920-235629\payload\USOS\Vista\Updates\Windows6.0-KB2864202-x64.cab'
if((Get-FileHash -LiteralPath $cab).Hash -ne (Get-FileHash -LiteralPath $reference).Hash){throw 'CAB hash mismatch'}
$pkgmgr='M:\Windows\System32\pkgmgr.exe'
if((Get-Item -LiteralPath $pkgmgr).VersionInfo.FileMajorPart -ne 6 -or (Get-Item -LiteralPath $pkgmgr).VersionInfo.FileMinorPart -ne 0){throw 'Not Vista pkgmgr'}
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class VistaOfflineAlias { [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool DefineDosDevice(uint flags,string name,string target); }'
$device='\Device\Harddisk'+$disk.Number+'\Partition'+$esp[0].PartitionNumber
if(![VistaOfflineAlias]::DefineDosDevice(9,'Z:',$device)){throw 'Alias failed'}
try {
 $env:TEMP=Join-Path $out 'scratch';$env:TMP=$env:TEMP
 $arguments='/o:"Z:\;M:\Windows" /ip /m:"'+$cab+'" /quiet /norestart /s:"'+(Join-Path $out 'scratch')+'" /l:"'+(Join-Path $out 'pkgmgr.log')+'"'
 $process=Start-Process -FilePath $pkgmgr -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait
 Write-Output "VISTA_OFFLINE_PKGMGR_EXIT=$($process.ExitCode); LOG=$out"
} finally {if(![VistaOfflineAlias]::DefineDosDevice(11,'Z:',$device)){throw 'Alias removal failed'}}
