param(
    [Parameter(Mandatory=$true)][string]$OutputRaw,
    [Parameter(Mandatory=$true)][string]$MetadataPath,
    [switch]$ExistingActive
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
function Full([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $root $Path))
}

$qemuImg = Full 'tools/qemu/qemu-img.exe'
$output = Full $OutputRaw
$metadata = Full $MetadataPath
$directory = Split-Path -Parent $output
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$vhd = Join-Path $directory '.xp-existing-target.vhd'
$diskpartScript = Join-Path $directory '.xp-existing-target.diskpart.txt'
Remove-Item -LiteralPath $vhd,$output,$metadata,$diskpartScript -Force -ErrorAction SilentlyContinue

$diskpartText = @"
create vdisk file="$vhd" maximum=4096 type=expandable
select vdisk file="$vhd"
attach vdisk
convert mbr
create partition primary size=512 align=1024
$(if ($ExistingActive) { 'active' } else { '' })
exit
"@
[IO.File]::WriteAllText($diskpartScript,$diskpartText,[Text.UTF8Encoding]::new($false))
$mounted=$false
$mountRoot=Join-Path $directory '.xp-existing-target.mount'
Remove-Item -LiteralPath $mountRoot -Recurse -Force -ErrorAction SilentlyContinue
$sentinelName='USOS-XP-SAFETY-SENTINEL.bin'
try {
    $diskpartOutput=& diskpart.exe /s $diskpartScript 2>&1
    if ($LASTEXITCODE -ne 0) { throw "diskpart failed ($LASTEXITCODE):`n$($diskpartOutput -join "`n")" }
    $mounted=$true

    $image=Get-DiskImage -ImagePath $vhd -ErrorAction Stop
    $disk=$image | Get-Disk -ErrorAction Stop
    if ($null -eq $disk) { throw 'Cannot resolve XP target VHD disk number' }
    $partitions=@(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop | Where-Object { $_.Size -gt 100MB })
    if ($partitions.Count -ne 1) { throw "Expected one existing primary partition, got $($partitions.Count)" }
    $partition=$partitions[0]
    $partition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'EXISTING' -Confirm:$false -Force | Out-Null
    New-Item -ItemType Directory -Force -Path $mountRoot | Out-Null
    $partition | Add-PartitionAccessPath -AccessPath $mountRoot | Out-Null
    $sentinelPath=Join-Path $mountRoot $sentinelName
    $payload=New-Object byte[] (1024*1024)
    for ($i=0; $i -lt $payload.Length; $i++) { $payload[$i]=[byte](($i*31+7) -band 0xFF) }
    [IO.File]::WriteAllBytes($sentinelPath,$payload)
    $sha=(Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $size=(Get-Item -LiteralPath $sentinelPath).Length
    if ($size -ne 1048576) { throw "Sentinel size mismatch: $size" }

    $partition | Remove-PartitionAccessPath -AccessPath $mountRoot -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -LiteralPath $mountRoot -Recurse -Force -ErrorAction SilentlyContinue
    Dismount-DiskImage -ImagePath $vhd -ErrorAction Stop
    $mounted=$false

    & $qemuImg convert -f vpc -O raw -S 4k $vhd $output
    if ($LASTEXITCODE -ne 0) { throw "qemu-img VHD->raw failed: $LASTEXITCODE" }

    $stream=[IO.FileStream]::new($output,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $mbr=New-Object byte[] 512
        if ($stream.Read($mbr,0,512) -ne 512) { throw 'Short MBR read from XP target raw' }
    } finally { $stream.Dispose() }
    if ($mbr[510] -ne 0x55 -or $mbr[511] -ne 0xAA) { throw 'XP target raw lacks MBR 55AA signature' }
    $diskId=[BitConverter]::ToUInt32($mbr,440)
    if ($diskId -eq 0) { throw 'XP target fixture has zero MBR disk signature' }
    $p1Type=$mbr[450]
    $p1Start=[BitConverter]::ToUInt32($mbr,454)
    $p1Sectors=[BitConverter]::ToUInt32($mbr,458)
    if ($p1Type -ne 0x07 -or $p1Start -eq 0 -or $p1Sectors -eq 0) { throw 'XP target fixture existing partition entry is invalid' }

    $meta=@"
version=1
sentinel_partition=1
sentinel_path=/$sentinelName
sentinel_sha256=$sha
sentinel_bytes=$size
mbr_disk_id=0x$($diskId.ToString('x8'))
existing_start_lba=$p1Start
existing_sectors=$p1Sectors
existing_active=$(if ($ExistingActive) { 'yes' } else { 'no' })
"@
    [IO.File]::WriteAllText($metadata,$meta,[Text.UTF8Encoding]::new($false))
    Write-Host "[PASS] XP existing-data target raw=$output"
    Write-Host "[PASS] sentinel SHA256=$sha bytes=$size partition=1 path=/$sentinelName"
    $activeText = if ($ExistingActive) { '0x80' } else { '0x00' }
    Write-Host "[PASS] existing MBR entry1 type=0x07 start=$p1Start sectors=$p1Sectors active=$activeText disk_id=0x$($diskId.ToString('x8'))"
} finally {
    if ($mounted) {
        try {
            $image=Get-DiskImage -ImagePath $vhd -ErrorAction SilentlyContinue
            if ($image) {
                $disk=$image | Get-Disk -ErrorAction SilentlyContinue
                if ($disk) {
                    Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | ForEach-Object {
                        $_ | Remove-PartitionAccessPath -AccessPath $mountRoot -ErrorAction SilentlyContinue | Out-Null
                    }
                }
            }
        } catch {}
    }
    if ($mounted) { Dismount-DiskImage -ImagePath $vhd -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $mountRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $vhd,$diskpartScript -Force -ErrorAction SilentlyContinue
}
