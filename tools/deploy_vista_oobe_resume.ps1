$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$part=Get-Partition -DriveLetter M;$disk=Get-Disk -Number $part.DiskNumber
if($disk.FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $disk.Size -ne 120034123776 -or ([guid]$disk.Guid) -ne [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148' -or $disk.IsBoot -or $disk.IsSystem -or ([guid]$part.Guid) -ne [guid]'8dca99dc-9f12-46c9-9c0d-5230748ee536'){throw 'Wrong Intel target'}
$folder=[IO.File]::ReadAllText((Join-Path $project 'zig-out\vista\oobe-resume-path.txt'))
$dirty=& fsutil.exe dirty query M:
$dirty|Write-Output
if($LASTEXITCODE -ne 0 -or ($dirty -join ' ') -notmatch 'is NOT Dirty'){throw 'Volume must be checked before deployment; snapshot already saved'}
& python (Join-Path $project 'tools\write_vista_oobe_resume.py') $folder
if($LASTEXITCODE -ne 0){throw 'Intel recovery deployment failed'}
Write-VolumeCache -DriveLetter M
Write-Output 'INTEL_RESUME_V2_DEPLOYED; verified files; no account or Setup completion edits'
