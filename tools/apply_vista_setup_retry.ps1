$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$prepared=Join-Path $project 'zig-out\vista\setup-retry'
$manifest=(Get-Content -LiteralPath (Join-Path $prepared 'repair.json') -Raw | ConvertFrom-Json).SYSTEM
$disk=@(Get-Disk | Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148'})
if($disk.Count -ne 1 -or $disk[0].FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $disk[0].Size -ne 120034123776 -or $disk[0].IsBoot -or $disk[0].IsSystem){throw 'Intel identity mismatch'}
$os=@(Get-Partition -DiskNumber $disk[0].Number | Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'73dbde99-8026-4759-a19a-fd943e891d09'})
if($os.Count -ne 1 -or -not $os[0].DriveLetter -or $os[0].Offset -ne 240123904 -or $os[0].Size -ne 119793516544 -or $os[0].IsBoot -or $os[0].IsSystem){throw 'Wrong Windows partition'}
$base="$($os[0].DriveLetter):\"
$config=Join-Path $base 'Windows\System32\config'
$target=Join-Path $config 'SYSTEM'
function Hash($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
if((Hash $target) -ne $manifest.original_sha256 -or (Hash (Join-Path $prepared 'SYSTEM')) -ne $manifest.patched_sha256){throw 'Precondition checksum mismatch'}
$backup=Join-Path $prepared ('backup-'+(Get-Date -Format yyyyMMdd-HHmmss))
[IO.Directory]::CreateDirectory($backup)|Out-Null
foreach($file in Get-ChildItem -LiteralPath $config -File | Where-Object {$_.Name -eq 'SYSTEM' -or $_.Name.StartsWith('SYSTEM.')}){[IO.File]::Copy($file.FullName,(Join-Path $backup $file.Name),$false)}
if((Hash (Join-Path $backup 'SYSTEM')) -ne $manifest.original_sha256){throw 'Backup mismatch'}
try {
 if((Hash $target) -ne $manifest.original_sha256){throw 'Concurrent hive change'}
 [IO.File]::Copy((Join-Path $prepared 'SYSTEM'),$target,$true)
 if((Hash $target) -ne $manifest.patched_sha256){throw 'Readback mismatch'}
 Write-VolumeCache -DriveLetter $os[0].DriveLetter
} catch {[IO.File]::Copy((Join-Path $backup 'SYSTEM'),$target,$true);throw}
Write-Output "SETUP_RETRY_APPLIED; SHA256_READBACK=PASS; CHILD_COMPLETION=0; BACKUP=$backup"
