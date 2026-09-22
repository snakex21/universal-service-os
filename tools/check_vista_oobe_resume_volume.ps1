$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$part=Get-Partition -DriveLetter M;$disk=Get-Disk -Number $part.DiskNumber
if($disk.FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $disk.Size -ne 120034123776 -or ([guid]$disk.Guid) -ne [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148' -or $disk.IsBoot -or $disk.IsSystem -or ([guid]$part.Guid) -ne [guid]'8dca99dc-9f12-46c9-9c0d-5230748ee536'){throw 'Wrong Intel target'}
$folder=[IO.File]::ReadAllText((Join-Path $project 'zig-out\vista\oobe-resume-path.txt'))
if(!(Test-Path -LiteralPath (Join-Path $folder 'manifest.json'))){throw 'Evidence snapshot missing'}
& chkdsk.exe M: /f /x > (Join-Path $folder 'chkdsk.txt')
$code=$LASTEXITCODE
Write-Output "CHKDSK_EXIT=$code"
Get-Content -LiteralPath (Join-Path $folder 'chkdsk.txt') -Tail 22
if($code -gt 1){throw 'Filesystem repair failed'}
& fsutil.exe dirty query M:
