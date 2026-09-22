# Read-only on Intel. Build a GUID-bound trial profile and preserve its BCD.
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$disks=@(Get-Disk|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'8e281c54-58d1-4ad0-8afd-ad76d2e48148'})
if($disks.Count -ne 1 -or $disks[0].FriendlyName -ne 'INTEL SS DSC2BW120A4' -or $disks[0].Size -ne 120034123776 -or $disks[0].IsBoot -or $disks[0].IsSystem){throw 'Intel identity mismatch'}
$disk=$disks[0]
$parts=@(Get-Partition -DiskNumber $disk.Number)
$esp=@($parts|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'266ef7fa-2486-4050-892f-20c3bc889930'})
$os=@($parts|Where-Object {$_.Guid -and ([guid]$_.Guid) -eq [guid]'7aa055ad-34cc-4db0-8c76-c8a9d4324200'})
if($esp.Count -ne 1 -or $esp[0].Size -ne 100MB -or ([guid]$esp[0].GptType) -ne [guid]'c12a7328-f81f-11d2-ba4b-00a0c93ec93b' -or $os.Count -ne 1 -or !$os[0].DriveLetter){throw 'Intel partition identity mismatch'}
$volume=$esp[0]|Get-Volume
if($volume.FileSystem -ne 'FAT32'){throw 'ESP is not FAT32'}
$out=Join-Path $project 'zig-out\vista\intel-boot-profile'
[IO.Directory]::CreateDirectory($out)|Out-Null
$root=@($esp[0].AccessPaths|Where-Object {$_ -like '\\?\Volume*'})[0]
$bcd=Join-Path $root 'EFI\Microsoft\Boot\BCD'
[IO.File]::Copy($bcd,(Join-Path $out 'BCD.before'),$true)
$exe="$($os[0].DriveLetter):\Windows\System32\bcdedit.exe"
$info=[Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
if($info.FileMajorPart -ne 6 -or $info.FileMinorPart -ne 0){throw 'Expected Vista bcdedit'}
[IO.File]::Copy($exe,(Join-Path $out 'vista-bcdedit.exe'),$true)
$mui="$($os[0].DriveLetter):\Windows\System32\pl-PL\bcdedit.exe.mui"
[IO.File]::Copy($mui,(Join-Path $out 'vista-bcdedit.exe.mui'),$true)
$bytes=[Text.Encoding]::ASCII.GetBytes('VESP0001')+([guid]$disk.Guid).ToByteArray()+([guid]$esp[0].Guid).ToByteArray()+[BitConverter]::GetBytes([uint64]$disk.Size)
[IO.File]::WriteAllBytes((Join-Path $out 'vista-target-esp.bin'),$bytes)
$report=@{diskGuid=$disk.Guid;espGuid=$esp[0].Guid;diskSize=$disk.Size;espFree=$volume.SizeRemaining;bcdeditVersion=$info.FileVersion;sha256=@{}}
foreach($name in @('vista-bcdedit.exe','vista-bcdedit.exe.mui','vista-target-esp.bin','BCD.before')){$report.sha256[$name]=(Get-FileHash -LiteralPath (Join-Path $out $name) -Algorithm SHA256).Hash.ToLowerInvariant()}
$report|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $out 'manifest.json') -Encoding UTF8
Write-Output ($report|ConvertTo-Json -Depth 4)
