param(
    [string]$IsoPath = 'windows_xp_professional_service_pack_2_x86_pl.iso',
    [string]$OutputDirectory = 'zig-out/legacy-bios/xp-menu-flow',
    [string]$TargetSerial = 'XP-TARGET-A',
    [ValidateSet('yes','no')][string]$StopAfterPrepare = 'yes',
    [ValidateSet('direct-ntfs','esp-fallback')][string]$CatalogMode = 'direct-ntfs',
    [string]$StorageProbeVendor = '',
    [string]$StorageProbeDevice = '',
    [string]$StorageProbeDriver = '',
    [int]$StorageProbeCandidates = 0,
    [switch]$SelectNoUnattended,
    [string]$UnattendedSourcePath = '',
    [switch]$SkipMicroLinuxBuild
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
function Full([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $root $Path))
}

$iso = Full $IsoPath
$unattendedSource = if($UnattendedSourcePath){ Full $UnattendedSourcePath } else { '' }
if($unattendedSource -and -not (Test-Path -LiteralPath $unattendedSource -PathType Leaf)) { throw "Unattended source missing: $unattendedSource" }
$out = Full $OutputDirectory
$vhd = Join-Path $out 'xp-menu-usos.vhd'
$raw = Join-Path $out 'xp-menu-usos.raw'
$qcow = Join-Path $out 'xp-menu-usos.qcow2'
$diskpartScript = Join-Path $out 'create.diskpart.txt'
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$zig = Full 'tools/zig/zig.exe'
$python = (Get-Command python.exe -ErrorAction Stop).Source
$gptPatcher = Full 'tools/tests/legacy_bios/patch_usos_gpt_names.py'
$fixtureBuilder = Full 'tools/tests/legacy_bios/create_fat32_boot_fixture.py'
$legacyBuild = Full 'tools/build_legacy_bios.ps1'
$kernel = Full 'zig-out/micro-linux/vmlinuz-virt'
$initramfs = Full 'zig-out/micro-linux/initramfs-usos'

foreach ($required in @($iso,$qemuImg,$zig,$gptPatcher,$fixtureBuilder,$legacyBuild)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing fixture input: $required" }
}

if(-not $SkipMicroLinuxBuild){
    & $zig build micro-linux -Doptimize=ReleaseFast
    if ($LASTEXITCODE -ne 0) { throw "micro-Linux build failed: $LASTEXITCODE" }
} else {
    Write-Host '[TEST] Reusing prebuilt micro-Linux fixture artifacts.'
}
foreach ($required in @($kernel,$initramfs)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing micro-Linux payload: $required" }
}

New-Item -ItemType Directory -Force -Path $out | Out-Null
if (Test-Path -LiteralPath $vhd -PathType Leaf) { Dismount-DiskImage -ImagePath $vhd -ErrorAction SilentlyContinue | Out-Null }
Remove-Item -LiteralPath $vhd,$raw,$qcow,$diskpartScript -Force -ErrorAction SilentlyContinue

$diskpartText = @"
create vdisk file="$vhd" maximum=2048 type=expandable
select vdisk file="$vhd"
attach vdisk
convert gpt
select partition 1
delete partition override
create partition efi size=256 offset=1024
create partition primary size=1500
exit
"@
[IO.File]::WriteAllText($diskpartScript,$diskpartText,[Text.UTF8Encoding]::new($false))

$mounted=$false
$espRoot=Join-Path $out '.mount-esp'
$dataRoot=Join-Path $out '.mount-data'
Remove-Item -LiteralPath $espRoot,$dataRoot -Recurse -Force -ErrorAction SilentlyContinue
try {
    $diskpartOutput=& diskpart.exe /s $diskpartScript 2>&1
    if ($LASTEXITCODE -ne 0) { throw "diskpart failed ($LASTEXITCODE):`n$($diskpartOutput -join "`n")" }
    $mounted=$true
    $disk=Get-DiskImage -ImagePath $vhd -ErrorAction Stop | Get-Disk -ErrorAction Stop
    $parts=@(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop | Sort-Object Offset)
    if ($parts.Count -ne 2) { throw "Expected ESP+DATA, got $($parts.Count) partitions" }
    $esp=$parts[0]
    $data=$parts[1]
    $esp | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'USOS_ESP' -Confirm:$false -Force | Out-Null
    $data | Format-Volume -FileSystem NTFS -AllocationUnitSize 4096 -NewFileSystemLabel 'USOS_DATA' -Confirm:$false -Force | Out-Null
    New-Item -ItemType Directory -Force -Path $espRoot,$dataRoot | Out-Null
    $esp | Add-PartitionAccessPath -AccessPath $espRoot | Out-Null
    $data | Add-PartitionAccessPath -AccessPath $dataRoot | Out-Null

    $microDir=Join-Path $espRoot 'EFI\USOS\micro-linux'
    New-Item -ItemType Directory -Force -Path $microDir | Out-Null
    Copy-Item -LiteralPath $kernel -Destination (Join-Path $microDir 'vmlinuz-virt') -Force
    Copy-Item -LiteralPath $initramfs -Destination (Join-Path $microDir 'initramfs-usos') -Force

    $xpDir=Join-Path $dataRoot 'Systems\Windows\Windows XP\Images'
    New-Item -ItemType Directory -Force -Path $xpDir | Out-Null
    Copy-Item -LiteralPath $iso -Destination (Join-Path $xpDir ([IO.Path]::GetFileName($iso))) -Force
    $xpUnattendedDir=Join-Path $dataRoot 'Systems\Windows\Windows XP\Unattended'
    New-Item -ItemType Directory -Force -Path $xpUnattendedDir | Out-Null
    $safeSifPath=Join-Path $xpUnattendedDir 'safe.sif'
    if($unattendedSource){
        Copy-Item -LiteralPath $unattendedSource -Destination $safeSifPath -Force
        Write-Host '[PASS] Legacy XP menu fixture unattended=external safe.sif (contents not logged)'
    } else {
        $safeSif=@"
[Data]
AutoPartition=0

[Unattended]
Repartition=No
TargetPath=\WINDOWS

[UserData]
FullName="USOS XP unattended fixture"
ComputerName=USOS-XP-TEST
"@
        [IO.File]::WriteAllText($safeSifPath,$safeSif,[Text.Encoding]::ASCII)
    }

    if ($CatalogMode -eq 'esp-fallback') {
        $espXpImages = Join-Path $espRoot 'Systems\Windows\Windows XP\Images'
        $espXpUnattended = Join-Path $espRoot 'Systems\Windows\Windows XP\Unattended'
        New-Item -ItemType Directory -Force -Path $espXpImages,$espXpUnattended | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $espXpImages ([IO.Path]::GetFileName($iso))), [byte[]]@())
        Copy-Item -LiteralPath $safeSifPath -Destination (Join-Path $espXpUnattended 'safe.sif') -Force
        Write-Host '[INFO] Test-only ESP fallback catalog projection created for XP menu/storage diagnostics.'
    }

    $espGuid=($esp.Guid.ToString()).Trim('{}')
    $dataGuid=($data.Guid.ToString()).Trim('{}')
    if (-not $espGuid -or -not $dataGuid) { throw 'Cannot resolve fixture partition GUIDs' }
    $usosDir=Join-Path $espRoot 'EFI\USOS'
    $deviceIni=@"
version=1
esp_partuuid=$espGuid
data_partuuid=$dataGuid
"@
    [IO.File]::WriteAllText((Join-Path $usosDir 'usos-device.ini'),$deviceIni,[Text.UTF8Encoding]::new($false))
    $testIni=@"
target_serial=$TargetSerial
stop_after_prepare=$StopAfterPrepare
"@
    [IO.File]::WriteAllText((Join-Path $usosDir 'legacy-xp-menu-test.ini'),$testIni,[Text.UTF8Encoding]::new($false))
    if ($StorageProbeVendor) {
        if (-not $StorageProbeDevice -or -not $StorageProbeDriver -or $StorageProbeCandidates -lt 0) {
            throw 'Storage probe requires vendor, device, driver and non-negative candidates'
        }
        $probeIni=@"
vendor=$StorageProbeVendor
device=$StorageProbeDevice
driver=$StorageProbeDriver
candidates=$StorageProbeCandidates
"@
        [IO.File]::WriteAllText((Join-Path $usosDir 'lts-storage-probe.ini'),$probeIni,[Text.UTF8Encoding]::new($false))
        Write-Host "[PASS] LTS automatic storage probe fixture vendor=$StorageProbeVendor device=$StorageProbeDevice driver=$StorageProbeDriver candidates=$StorageProbeCandidates"
    }

    Write-Host "[PASS] Legacy XP menu fixture ISO=$([IO.Path]::GetFileName($iso))"
    if($unattendedSource){
        Write-Host '[PASS] Legacy XP menu fixture unattended=safe.sif external-source policy validated by caller'
    } else {
        Write-Host '[PASS] Legacy XP menu fixture unattended=safe.sif AutoPartition=0 Repartition=No'
    }
    Write-Host "[PASS] Fixture ESP PARTUUID=$espGuid DATA PARTUUID=$dataGuid"
    Write-Host "[PASS] legacy-xp-menu-test.ini target_serial=$TargetSerial stop_after_prepare=$StopAfterPrepare"

    $esp | Remove-PartitionAccessPath -AccessPath $espRoot -ErrorAction SilentlyContinue | Out-Null
    $data | Remove-PartitionAccessPath -AccessPath $dataRoot -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -LiteralPath $espRoot,$dataRoot -Recurse -Force -ErrorAction SilentlyContinue
    Dismount-DiskImage -ImagePath $vhd -ErrorAction Stop
    $mounted=$false

    & $qemuImg convert -f vpc -O raw -S 4k $vhd $raw
    if ($LASTEXITCODE -ne 0) { throw "qemu-img VHD->raw failed: $LASTEXITCODE" }
    & $python $gptPatcher --image $raw
    if ($LASTEXITCODE -ne 0) { throw "GPT name patch failed: $LASTEXITCODE" }
    $testCoreOut = Join-Path $out 'test-core'
    $legacyArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$legacyBuild,'-OutputDirectory',$testCoreOut,'-CatalogMode',$CatalogMode,'-XpMenuAutoTest')
    if($SelectNoUnattended){ $legacyArgs += '-XpMenuAutoNone' }
    & powershell.exe @legacyArgs
    if ($LASTEXITCODE -ne 0) { throw "Legacy build failed: $LASTEXITCODE" }
    & $python $fixtureBuilder --qemu-img $qemuImg --source-raw $raw --stage1 (Join-Path $testCoreOut 'stage1.bin') --core-slot (Join-Path $testCoreOut 'core-slot.bin') --output $qcow
    if ($LASTEXITCODE -ne 0) { throw "Legacy XP menu qcow build failed: $LASTEXITCODE" }
} finally {
    if ($mounted) {
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
    if ($mounted -and (Test-Path -LiteralPath $vhd -PathType Leaf)) { Dismount-DiskImage -ImagePath $vhd -ErrorAction SilentlyContinue | Out-Null }
    Remove-Item -LiteralPath $espRoot,$dataRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $diskpartScript,$raw,$vhd -Force -ErrorAction SilentlyContinue
}

Write-Host "[PASS] Legacy XP menu boot fixture ready: $qcow"
