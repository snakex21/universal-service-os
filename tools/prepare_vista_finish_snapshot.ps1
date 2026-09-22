# Guard and preserve the successful Setup run before finishing its boot hook.
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$disks=@(Get-Disk|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148'})
if($disks.Count -ne 1 -or $disks[0].FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $disks[0].Size -ne 120034123776 -or $disks[0].IsBoot -or $disks[0].IsSystem){throw 'Intel identity mismatch'}
$disk=$disks[0];$parts=@(Get-Partition -DiskNumber $disk.Number)
$esp=@($parts|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'266ef7fa-2486-4050-892f-20c3bc889930'})
$os=@($parts|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'8dca99dc-9f12-46c9-9c0d-5230748ee536'})
if($esp.Count -ne 1 -or $esp[0].Size -ne 100MB -or $os.Count -ne 1 -or !$os[0].DriveLetter -or $os[0].Size -ne 119374086144){throw 'Intel partition mismatch'}
$out=Join-Path $project ('artifacts\vista\finish-successful-setup-'+(Get-Date -Format yyyyMMdd-HHmmss))
[IO.Directory]::CreateDirectory($out)|Out-Null
$osRoot="$($os[0].DriveLetter):\"
$espRoot=@($esp[0].AccessPaths|Where-Object {$_ -like '\\?\Volume*'})[0]
foreach($name in @('SYSTEM','SOFTWARE')){[IO.File]::Copy((Join-Path $osRoot ('Windows\System32\config\'+$name)),(Join-Path $out $name),$false)}
[IO.File]::Copy((Join-Path $espRoot 'EFI\Microsoft\Boot\BCD'),(Join-Path $out 'BCD'),$false)
foreach($suffix in @('.LOG','.LOG1','.LOG2')){
 $transaction=Join-Path $espRoot ('EFI\Microsoft\Boot\BCD'+$suffix)
 if([IO.File]::Exists($transaction)){[IO.File]::Copy($transaction,(Join-Path $out ('BCD'+$suffix)),$false)}
}
[IO.File]::Copy((Join-Path $espRoot 'EFI\Microsoft\Boot\bootmgfw.efi'),(Join-Path $out 'bootmgfw.efi'),$false)
$fallback=Join-Path $espRoot 'EFI\Boot\bootx64.efi'
if([IO.File]::Exists($fallback)){[IO.File]::Copy($fallback,(Join-Path $out 'bootx64.before'),$false)}
Copy-Item -LiteralPath 'J:\EFI\USOS\Logs\WinSetup-2026-9-21-12-41-40-1760' -Destination (Join-Path $out 'usb-logs') -Recurse
@{diskGuid=$disk.Guid;espGuid=$esp[0].Guid;osGuid=$os[0].Guid;osRoot=$osRoot;espRoot=$espRoot;layout=@($parts|Select-Object Guid,GptType,Size,Offset);sourceFiles=@{}}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $out 'snapshot.json') -Encoding UTF8
[IO.File]::WriteAllText((Join-Path $project 'zig-out\vista\finish-snapshot-path.txt'),$out)
Write-Output "SNAPSHOT_SAVED=$out; NO_INTEL_WRITES"
