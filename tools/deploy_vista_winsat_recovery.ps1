$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$part=Get-Partition -DriveLetter M
$disk=Get-Disk -Number $part.DiskNumber
if($disk.FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $disk.Size -ne 120034123776 -or ([guid]$disk.Guid) -ne [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148' -or $disk.IsBoot -or $disk.IsSystem -or ([guid]$part.Guid) -ne [guid]'8dca99dc-9f12-46c9-9c0d-5230748ee536'){throw 'Wrong target'}
$snapshot=[IO.File]::ReadAllText((Join-Path $project 'zig-out\vista\winsat-snapshot-path.txt'))
& python (Join-Path $project 'tools\write_vista_winsat_recovery.py') $snapshot
if($LASTEXITCODE -ne 0){throw 'Recovery write failed'}
Write-VolumeCache -DriveLetter M
Write-Output 'INTEL_OOBE_RECOVERY_DEPLOYED; current account retained; no Setup completion flags changed'
