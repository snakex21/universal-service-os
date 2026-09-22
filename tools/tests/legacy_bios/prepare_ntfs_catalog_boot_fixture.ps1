param(
    [string]$OutputDirectory = 'zig-out/legacy-bios/ntfs-catalog-boot'
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
function Full([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $root $Path))
}

$out = Full $OutputDirectory
$vhd = Join-Path $out 'ntfs-catalog.vhd'
$raw = Join-Path $out 'ntfs-catalog.raw'
$qcow = Join-Path $out 'ntfs-catalog.qcow2'
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$zig = Full 'tools/zig/zig.exe'
$builder = Full 'tools/tests/legacy_bios/create_fat32_boot_fixture.py'
$gptPatcher = Full 'tools/tests/legacy_bios/patch_usos_gpt_names.py'
$python = (Get-Command python.exe -ErrorAction Stop).Source
$legacyBuild = Full 'tools/build_legacy_bios.ps1'
$xpName = 'Windows.XP.Professional.SP3.OEM.PL.IE8.WMP11.DX.NET.FINAL.FULL.SATA-v2.Kwiecien.2014-NiKKA.iso'
$uefiProbe = Full 'zig-out/test-assets/uefi-ntfs-catalog-probe-x86_64.efi'
$ntfsDriver = Full 'zig-out/test-assets/ntfs_x64.efi'

& $zig build uefi-ntfs-catalog-probe-app -Doptimize=Debug
if ($LASTEXITCODE -ne 0) { throw "UEFI NTFS catalog probe build failed: $LASTEXITCODE" }
if (-not (Test-Path -LiteralPath $ntfsDriver -PathType Leaf)) {
    & $zig build fetch-ntfs-driver
    if ($LASTEXITCODE -ne 0) { throw "fetch NTFS UEFI driver failed: $LASTEXITCODE" }
}
foreach ($required in @($uefiProbe,$ntfsDriver)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing UEFI fixture payload: $required" }
}

New-Item -ItemType Directory -Force -Path $out | Out-Null
if (Test-Path -LiteralPath $vhd -PathType Leaf) { Dismount-DiskImage -ImagePath $vhd -ErrorAction SilentlyContinue | Out-Null }
Get-ChildItem -LiteralPath $out -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse

$diskpartScript = Join-Path $out 'create.diskpart.txt'
$diskpartText = @"
create vdisk file="$vhd" maximum=256 type=fixed
select vdisk file="$vhd"
attach vdisk
convert gpt
select partition 1
delete partition override
create partition efi size=80 offset=1024
create partition primary size=160
exit
"@
[IO.File]::WriteAllText($diskpartScript, $diskpartText, [Text.UTF8Encoding]::new($false))

$mounted = $false
$espRoot = Join-Path $out '.mount-esp'
$dataRoot = Join-Path $out '.mount-data'
Remove-Item -LiteralPath $espRoot,$dataRoot -Recurse -Force -ErrorAction SilentlyContinue
try {
    $diskpartOutput = & diskpart.exe /s $diskpartScript 2>&1
    if ($LASTEXITCODE -ne 0) { throw "diskpart failed ($LASTEXITCODE):`n$($diskpartOutput -join "`n")" }
    $mounted = $true
    $disk = Get-DiskImage -ImagePath $vhd -ErrorAction Stop | Get-Disk -ErrorAction Stop
    $parts = @(Get-Partition -DiskNumber $disk.Number | Sort-Object PartitionNumber)
    if ($parts.Count -ne 2) { throw "Expected ESP+DATA, got $($parts.Count) partitions" }
    $esp = $parts[0]
    $data = $parts[1]

    $esp | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'USOS_ESP' -Confirm:$false -Force | Out-Null
    $data | Format-Volume -FileSystem NTFS -AllocationUnitSize 4096 -NewFileSystemLabel 'USOS_DATA' -Confirm:$false -Force | Out-Null
    New-Item -ItemType Directory -Force -Path $espRoot,$dataRoot | Out-Null
    $esp | Add-PartitionAccessPath -AccessPath $espRoot | Out-Null
    $data | Add-PartitionAccessPath -AccessPath $dataRoot | Out-Null

    # Match the physical Kingston: 8.3 creation is disabled there, so names
    # such as "Windows 11" exist only as long NTFS $FILE_NAME entries.
    & fsutil.exe 8dot3name set $dataRoot 1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to disable 8.3 names on NTFS catalog fixture' }

    # Force the intermediate Systems\Windows directory itself to use
    # $INDEX_ALLOCATION. The previous fixture only stressed a leaf directory.
    $windowsRoot = Join-Path $dataRoot 'Systems\Windows'
    New-Item -ItemType Directory -Force -Path $windowsRoot | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
        New-Item -ItemType Directory -Force -Path (Join-Path $windowsRoot ("Compatibility Folder {0:D3}" -f $i)) | Out-Null
    }

    # Deliberately leave the ESP XP Images directory empty. If Legacy/UEFI
    # reports images=1, the result can only have come from the real NTFS DATA tree.
    New-Item -ItemType Directory -Force -Path (Join-Path $espRoot 'Systems\Windows\Windows XP\Images') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $espRoot 'EFI\BOOT') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $espRoot 'EFI\USOS') | Out-Null
    Copy-Item -LiteralPath $uefiProbe -Destination (Join-Path $espRoot 'EFI\BOOT\BOOTX64.EFI') -Force
    Copy-Item -LiteralPath $ntfsDriver -Destination (Join-Path $espRoot 'EFI\USOS\ntfs_x64.efi') -Force
    New-Item -ItemType Directory -Force -Path (Join-Path $dataRoot 'Systems\Windows\Windows XP\Images') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $dataRoot 'Systems\Windows\Windows 11\Images') | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $dataRoot "Systems\Windows\Windows XP\Images\$xpName"), [byte[]]@(0x58))
    [IO.File]::WriteAllBytes((Join-Path $dataRoot 'Systems\Windows\Windows 11\Images\Win11_25H2_Polish_x64_v2.iso'), [byte[]]@(0x31))

    $windowsExtents = (& fsutil.exe file queryextents $windowsRoot 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $windowsExtents -notmatch 'LCN:') {
        throw "Intermediate Windows directory did not expose an index-allocation extent:`n$windowsExtents"
    }
    $shortListing = (& cmd.exe /c "dir /x `"$windowsRoot`"" 2>&1 | Out-String)
    if ($shortListing -match 'WINDOW~') { throw "Fixture unexpectedly created 8.3 aliases:`n$shortListing" }

    Write-Host "[PASS] NTFS catalog fixture DATA XP image=$xpName"
    Write-Host '[PASS] Intermediate Systems\Windows uses $INDEX_ALLOCATION with 8.3 names disabled.'
    Write-Host '[PASS] ESP Windows XP/Images deliberately empty'

    $esp | Remove-PartitionAccessPath -AccessPath $espRoot -ErrorAction SilentlyContinue | Out-Null
    $data | Remove-PartitionAccessPath -AccessPath $dataRoot -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -LiteralPath $espRoot,$dataRoot -Recurse -Force -ErrorAction SilentlyContinue
} finally {
    if($mounted){
        try {
            $mountedDisk=Get-DiskImage -ImagePath $vhd -ErrorAction SilentlyContinue | Get-Disk -ErrorAction SilentlyContinue
            if($mountedDisk){
                Get-Partition -DiskNumber $mountedDisk.Number -ErrorAction SilentlyContinue | ForEach-Object {
                    $_ | Remove-PartitionAccessPath -AccessPath $espRoot -ErrorAction SilentlyContinue | Out-Null
                    $_ | Remove-PartitionAccessPath -AccessPath $dataRoot -ErrorAction SilentlyContinue | Out-Null
                }
            }
        } catch {}
    }
    if (Test-Path -LiteralPath $vhd -PathType Leaf) { Dismount-DiskImage -ImagePath $vhd -ErrorAction SilentlyContinue | Out-Null }
    Remove-Item -LiteralPath $espRoot,$dataRoot -Recurse -Force -ErrorAction SilentlyContinue
}

& $qemuImg convert -f vpc -O raw $vhd $raw
if ($LASTEXITCODE -ne 0) { throw "qemu-img VHD->raw failed: $LASTEXITCODE" }
& $python $gptPatcher --image $raw
if ($LASTEXITCODE -ne 0) { throw "patch USOS GPT names failed: $LASTEXITCODE" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $legacyBuild
if ($LASTEXITCODE -ne 0) { throw "Legacy build failed: $LASTEXITCODE" }
& $python $builder --qemu-img $qemuImg --source-raw $raw --stage1 (Full 'zig-out/legacy-bios/stage1.bin') --core-slot (Full 'zig-out/legacy-bios/core-slot.bin') --output $qcow
if ($LASTEXITCODE -ne 0) { throw "Legacy NTFS catalog boot fixture build failed: $LASTEXITCODE" }

Remove-Item -LiteralPath $diskpartScript,$raw,$vhd -Force -ErrorAction SilentlyContinue
Write-Host "[PASS] Legacy NTFS catalog boot fixture ready: $qcow"
