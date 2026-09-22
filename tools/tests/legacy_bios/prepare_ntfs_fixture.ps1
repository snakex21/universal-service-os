param(
    [string]$OutputDirectory = 'zig-out/legacy-bios/ntfs-fixture'
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
function Full([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $root $Path))
}

$out = Full $OutputDirectory
$vhd = Join-Path $out 'formatted-ntfs.vhd'
$raw = Join-Path $out 'formatted-ntfs.raw'
$valid = Join-Path $out 'valid-hard.raw'
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$mutator = Full 'tools/tests/legacy_bios/mutate_ntfs_fixture.py'
$python = (Get-Command python.exe -ErrorAction Stop).Source

foreach ($required in @($qemuImg, $mutator)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing fixture dependency: $required" }
}
New-Item -ItemType Directory -Force -Path $out | Out-Null
Get-ChildItem -LiteralPath $out -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse

$diskpartScript = Join-Path $out 'create-vhd.diskpart.txt'
$diskpartText = @"
create vdisk file="$vhd" maximum=128 type=fixed
select vdisk file="$vhd"
attach vdisk
convert mbr
create partition primary size=120 offset=1024
exit
"@
[IO.File]::WriteAllText($diskpartScript, $diskpartText, [Text.UTF8Encoding]::new($false))

$mounted = $false
$mountRoot = Join-Path $out '.mount-data'
Remove-Item -LiteralPath $mountRoot -Recurse -Force -ErrorAction SilentlyContinue
$reserveLcn = $null
$reserveClusters = $null
try {
    $diskpartOutput = & diskpart.exe /s $diskpartScript 2>&1
    if ($LASTEXITCODE -ne 0) { throw "diskpart failed ($LASTEXITCODE):`n$($diskpartOutput -join "`n")" }
    $mounted = $true

    $disk = Get-DiskImage -ImagePath $vhd -ErrorAction Stop | Get-Disk -ErrorAction Stop
    if ($null -eq $disk) { throw 'Cannot resolve NTFS fixture VHD disk number' }
    $partition = Get-Partition -DiskNumber $disk.Number
    if (@($partition).Count -ne 1) { throw "Expected exactly one primary partition; got $(@($partition).Count)" }
    $partition | Format-Volume -FileSystem NTFS -AllocationUnitSize 4096 -NewFileSystemLabel 'USOS_DATA' -Confirm:$false -Force | Out-Null
    New-Item -ItemType Directory -Force -Path $mountRoot | Out-Null
    $partition | Add-PartitionAccessPath -AccessPath $mountRoot | Out-Null

    & fsutil.exe 8dot3name set $mountRoot 1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to disable 8.3 names on hard NTFS fixture' }

    $windowsRoot = Join-Path $mountRoot 'Systems\Windows'
    New-Item -ItemType Directory -Force -Path $windowsRoot | Out-Null
    for ($i = 0; $i -lt 96; $i++) {
        New-Item -ItemType Directory -Force -Path (Join-Path $windowsRoot ("Compatibility Folder {0:D3}" -f $i)) | Out-Null
    }

    $images = Join-Path $mountRoot 'Systems\Windows\Windows XP\Images'
    New-Item -ItemType Directory -Force -Path $images | Out-Null
    $win11Images = Join-Path $mountRoot 'Systems\Windows\Windows 11\Images'
    New-Item -ItemType Directory -Force -Path $win11Images | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $win11Images 'Win11 Space Path.iso'), [byte[]]@(0x11))
    New-Item -ItemType Directory -Force -Path (Join-Path $images 'nested') | Out-Null
    for ($i = 0; $i -lt 320; $i++) {
        $path = Join-Path $images ("payload-{0:D4}.iso" -f $i)
        [IO.File]::WriteAllBytes($path, [byte[]]@([byte]($i -band 0xff)))
    }

    $windowsExtents = (& fsutil.exe file queryextents $windowsRoot 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $windowsExtents -notmatch 'LCN:') {
        throw "Intermediate Systems\Windows did not require index allocation:`n$windowsExtents"
    }
    $shortListing = (& cmd.exe /c "dir /x `"$windowsRoot`"" 2>&1 | Out-String)
    if ($shortListing -match 'WINDOW~') { throw "Hard fixture unexpectedly created 8.3 aliases:`n$shortListing" }
    Write-Host '[PASS] hard fixture intermediate Systems\Windows uses $INDEX_ALLOCATION; 8.3 aliases disabled'

    # Reserve a known contiguous free extent after the hard directory fixture
    # has already forced MFT growth. The mutator will relocate the tail of $MFT
    # into this extent, producing a genuinely fragmented MFT runlist while
    # keeping the underlying NTFS image and directory/index structures real.
    $reserve = Join-Path $mountRoot 'MFT_FRAGMENT_RESERVE.bin'
    & fsutil.exe file createnew $reserve 33554432 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'fsutil file createnew failed for MFT reserve' }
    $extentText = (& fsutil.exe file queryextents $reserve 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "fsutil queryextents failed for reserve:`n$extentText" }
    $extents = @()
    foreach ($line in ($extentText -split "`r?`n")) {
        if ($line -match 'VCN:\s*0x([0-9A-Fa-f]+)\s+Clusters:\s*0x([0-9A-Fa-f]+)\s+LCN:\s*0x([0-9A-Fa-f]+)') {
            $extents += [pscustomobject]@{
                VCN = [Convert]::ToUInt64($matches[1],16)
                Clusters = [Convert]::ToUInt64($matches[2],16)
                LCN = [Convert]::ToUInt64($matches[3],16)
            }
        }
    }
    if ($extents.Count -eq 0) { throw "Could not parse reserve retrieval pointers:`n$extentText" }
    $best = $extents | Sort-Object Clusters -Descending | Select-Object -First 1
    $reserveLcn = $best.LCN
    $reserveClusters = $best.Clusters
    if ($reserveClusters -lt 1024) { throw "Largest reserve extent unexpectedly small: $reserveClusters clusters" }

    $mftText = (& fsutil.exe file queryextents (Join-Path $mountRoot '$MFT') 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "fsutil queryextents failed for `$MFT:`n$mftText" }
    [IO.File]::WriteAllText((Join-Path $out 'mft-before.txt'), $mftText, [Text.UTF8Encoding]::new($false))

    Remove-Item -LiteralPath $reserve -Force
    Write-Host "[PASS] real NTFS fixture populated images=320 reserve_lcn=$reserveLcn reserve_clusters=$reserveClusters"
    Write-Host '[PASS] Images directory population is large enough to require $INDEX_ALLOCATION on standard NTFS.'
    Write-Host "[INFO] native `$MFT extents before hardening:`n$mftText"

    $partition | Remove-PartitionAccessPath -AccessPath $mountRoot -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -LiteralPath $mountRoot -Recurse -Force -ErrorAction SilentlyContinue
} finally {
    if ($mounted) {
        try {
            $mountedDisk=Get-DiskImage -ImagePath $vhd -ErrorAction SilentlyContinue | Get-Disk -ErrorAction SilentlyContinue
            if($mountedDisk){
                Get-Partition -DiskNumber $mountedDisk.Number -ErrorAction SilentlyContinue | ForEach-Object {
                    $_ | Remove-PartitionAccessPath -AccessPath $mountRoot -ErrorAction SilentlyContinue | Out-Null
                }
            }
        } catch {}
        Dismount-DiskImage -ImagePath $vhd -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $mountRoot -Recurse -Force -ErrorAction SilentlyContinue
}

& $qemuImg convert -f vpc -O raw $vhd $raw
if ($LASTEXITCODE -ne 0) { throw "qemu-img convert VHD->raw failed with exit code $LASTEXITCODE" }

& $python $mutator --source $raw --output $valid --mode valid-hard --reserve-lcn $reserveLcn --reserve-clusters $reserveClusters
if ($LASTEXITCODE -ne 0) { throw "NTFS hard fixture fragmentation failed with exit code $LASTEXITCODE" }

$negative = @('bad-vbr','bad-mft-signature','bad-fixup','run-outside','run-loop')
foreach ($mode in $negative) {
    $output = Join-Path $out "$mode.raw"
    & $python $mutator --source $valid --output $output --mode $mode
    if ($LASTEXITCODE -ne 0) { throw "NTFS fixture mutation $mode failed with exit code $LASTEXITCODE" }
}

Remove-Item -LiteralPath $diskpartScript, $raw, $vhd -Force -ErrorAction SilentlyContinue
Write-Host "[PASS] NTFS host fixture matrix ready: $out"
