$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$snapshot=[IO.File]::ReadAllText((Join-Path $project 'zig-out\vista\finish-snapshot-path.txt'))
$meta=Get-Content -LiteralPath (Join-Path $snapshot 'snapshot.json') -Raw|ConvertFrom-Json
$disk=@(Get-Disk|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148'})
if($disk.Count -ne 1 -or $disk[0].FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $disk[0].Size -ne 120034123776 -or $disk[0].IsBoot -or $disk[0].IsSystem -or $disk[0].BusType -ne 'USB'){throw 'Wrong Intel disk'}
$parts=@(Get-Partition -DiskNumber $disk[0].Number)
$esp=@($parts|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'266ef7fa-2486-4050-892f-20c3bc889930'})
$os=@($parts|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'8dca99dc-9f12-46c9-9c0d-5230748ee536'})
if($esp.Count -ne 1 -or $os.Count -ne 1 -or $esp[0].Size -ne 100MB -or $os[0].Size -ne 119374086144 -or ([guid]$esp[0].GptType) -ne [guid]'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'){throw 'Wrong Intel partitions'}
$layout=$parts|Select-Object Guid,GptType,Size,Offset|ConvertTo-Json -Compress
& python (Join-Path $project 'tools\write_vista_finished_setup.py') $snapshot
if($LASTEXITCODE -ne 0){throw 'Offline finalization failed'}
if(($parts|Select-Object Guid,GptType,Size,Offset|ConvertTo-Json -Compress) -ne ((Get-Partition -DiskNumber $disk[0].Number|Select-Object Guid,GptType,Size,Offset)|ConvertTo-Json -Compress)){throw 'Partition layout changed'}
Write-Output 'INTEL_SETUP_FINALIZED; PARTITION_LAYOUT_UNCHANGED'
