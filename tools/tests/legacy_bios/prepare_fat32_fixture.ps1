param(
    [string]$OutputDirectory = 'zig-out/legacy-bios/fat32-fixture',
    [switch]$IncludeMicroLinuxProbe,
    [switch]$BootMicroLinux,
    [ValidateSet('', 'mbr-changed', 'serial-mismatch')]
    [string]$TargetGuardTestMode = '',
    [string]$TargetGuardTargetSerial = 'XP-TARGET-A',
    [switch]$XpTargetTest,
    [switch]$XpBlankTarget,
    [switch]$XpBootFilesFast,
    [string]$XpTargetSerial = 'XP-TARGET-A',
    [string]$XpSourceSerial = 'XP-ISO-SOURCE',
    [string]$XpSentinelSha256 = '',
    [string]$XpSentinelPath = '/USOS-XP-SAFETY-SENTINEL.bin',
    [int]$XpSentinelPartition = 1,
    [switch]$OnlyValid
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
function Full([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $root $Path))
}

$out = Full $OutputDirectory
$vhd = Join-Path $out 'formatted-fat32.vhd'
$raw = Join-Path $out 'formatted-fat32.raw'
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$mutator = Full 'tools/tests/legacy_bios/mutate_fat32_fixture.py'
$python = (Get-Command python.exe -ErrorAction Stop).Source

if (-not (Test-Path -LiteralPath $qemuImg -PathType Leaf)) { throw "Missing qemu-img: $qemuImg" }
if (-not (Test-Path -LiteralPath $mutator -PathType Leaf)) { throw "Missing fixture mutator: $mutator" }
New-Item -ItemType Directory -Force -Path $out | Out-Null
Get-ChildItem -LiteralPath $out -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse

$diskpartScript = Join-Path $out 'create-vhd.diskpart.txt'
$diskpartText = @"
create vdisk file="$vhd" maximum=96 type=fixed
select vdisk file="$vhd"
attach vdisk
convert gpt
create partition efi size=80 offset=1024
exit
"@
[IO.File]::WriteAllText($diskpartScript, $diskpartText, [Text.UTF8Encoding]::new($false))

$mounted = $false
$mountRoot = Join-Path $out '.mount-esp'
Remove-Item -LiteralPath $mountRoot -Recurse -Force -ErrorAction SilentlyContinue
try {
    $diskpartOutput = & diskpart.exe /s $diskpartScript 2>&1
    if ($LASTEXITCODE -ne 0) { throw "diskpart failed ($LASTEXITCODE):`n$($diskpartOutput -join "`n")" }
    $mounted = $true

    $diskImage = Get-DiskImage -ImagePath $vhd -ErrorAction Stop
    $disk = $diskImage | Get-Disk -ErrorAction Stop
    if ($null -eq $disk) { throw 'Cannot resolve VHD disk number' }
    $espType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    $partition = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.GptType -eq $espType }
    if (@($partition).Count -ne 1) { throw "Expected exactly one EFI partition on fixture VHD; got $(@($partition).Count)" }

    $partition | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'USOS_ESP' -Confirm:$false -Force | Out-Null
    New-Item -ItemType Directory -Force -Path $mountRoot | Out-Null
    $partition | Add-PartitionAccessPath -AccessPath $mountRoot | Out-Null

    $usosDir = Join-Path $mountRoot 'EFI\USOS'
    New-Item -ItemType Directory -Force -Path $usosDir | Out-Null
    $menuPath = Join-Path $usosDir 'usos-menu.ini'
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append("[USOS]`r`n")
    [void]$builder.Append("marker=USOS FAT32 FIXTURE`r`n")
    [void]$builder.Append("firmware=any`r`n")
    for ($i = 0; $i -lt 1600; $i++) {
        [void]$builder.AppendFormat("fixture_{0:D4}=0123456789ABCDEF0123456789ABCDEF`r`n", $i)
    }
    [IO.File]::WriteAllText($menuPath, $builder.ToString(), [Text.UTF8Encoding]::new($false))
    $menuBytes = (Get-Item -LiteralPath $menuPath).Length
    if ($menuBytes -lt 65536) { throw "Fixture usos-menu.ini unexpectedly small: $menuBytes" }

    if ($IncludeMicroLinuxProbe -or $BootMicroLinux) {
        $microSource = Full 'zig-out/micro-linux'
        $kernelSource = Join-Path $microSource 'vmlinuz-virt'
        $initramfsSource = Join-Path $microSource 'initramfs-usos'
        foreach ($required in @($kernelSource, $initramfsSource)) {
            if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "micro-Linux fixture input missing: $required" }
        }
        $microTarget = Join-Path $usosDir 'micro-linux'
        New-Item -ItemType Directory -Force -Path $microTarget | Out-Null
        Copy-Item -LiteralPath $kernelSource -Destination (Join-Path $microTarget 'vmlinuz-virt') -Force
        Copy-Item -LiteralPath $initramfsSource -Destination (Join-Path $microTarget 'initramfs-usos') -Force
        $markerName = if ($BootMicroLinux) { 'legacy-linux-boot.flag' } else { 'legacy-linux-probe.flag' }
        [IO.File]::WriteAllText((Join-Path $usosDir $markerName), "probe`r`n", [Text.UTF8Encoding]::new($false))
        Write-Host "[PASS] FAT32 fixture includes Legacy Linux $markerName kernel=$((Get-Item $kernelSource).Length) initramfs=$((Get-Item $initramfsSource).Length)"
    }

    if ($TargetGuardTestMode) {
        if (-not $BootMicroLinux) { throw '-TargetGuardTestMode requires -BootMicroLinux' }
        $guardTest = @"
mode=$TargetGuardTestMode
target_serial=$TargetGuardTargetSerial
"@
        [IO.File]::WriteAllText((Join-Path $usosDir 'target-guard-test.ini'), $guardTest, [Text.UTF8Encoding]::new($false))
        Write-Host "[PASS] FAT32 fixture includes target-disk guard test mode=$TargetGuardTestMode serial=$TargetGuardTargetSerial"
    }
    if ($XpTargetTest) {
        if (-not $BootMicroLinux) { throw '-XpTargetTest requires -BootMicroLinux' }
        $xpTest = @"
target_serial=$XpTargetSerial
source_serial=$XpSourceSerial
blank_target=$(if ($XpBlankTarget) { 'yes' } else { 'no' })
local_source_test_mode=$(if ($XpBootFilesFast) { 'bootfiles' } else { '' })
sentinel_partition=$XpSentinelPartition
sentinel_path=$XpSentinelPath
sentinel_sha256=$XpSentinelSha256
"@
        [IO.File]::WriteAllText((Join-Path $usosDir 'xp-target-test.ini'), $xpTest, [Text.UTF8Encoding]::new($false))
        Write-Host "[PASS] FAT32 fixture includes XP target test serial=$XpTargetSerial sentinel_sha256=$XpSentinelSha256"
    }

    Write-Host "[PASS] Windows formatted FAT32 fixture ESP disk=$($disk.Number) offset=$($partition.Offset) size=$($partition.Size) label=USOS_ESP menu_bytes=$menuBytes"

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

$modes = if ($OnlyValid) { @('valid') } else { @('valid', 'bad-bpb', 'broken-chain', 'outside-file', 'loop') }
foreach ($mode in $modes) {
    $output = Join-Path $out "$mode.raw"
    & $python $mutator --source $raw --output $output --mode $mode
    if ($LASTEXITCODE -ne 0) { throw "FAT32 fixture mutation $mode failed with exit code $LASTEXITCODE" }
}

Remove-Item -LiteralPath $diskpartScript, $raw -Force -ErrorAction SilentlyContinue
Write-Host "[PASS] FAT32 fixture matrix ready: $out"
