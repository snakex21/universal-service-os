param(
    [string]$StagingPath = 'tools/tests/artifacts/qemu/.staging-usos-installer-windows-base.vhd',
    [string]$OutputPath = 'tools/tests/artifacts/qemu/usos-installer-windows-base.vhd',
    [string]$QemuImgPath = 'tools/qemu/qemu-img.exe',
    [string]$UnattendPath = 'tools/tests/fixtures/installer/windows-qemu-base/unattend.xml',
    [string]$BootstrapPath = 'tools/tests/fixtures/installer/windows-qemu-base/bootstrap.cmd'
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Full([string]$Path) { [IO.Path]::GetFullPath((Join-Path $root $Path)) }
$StagingPath = Full $StagingPath
$OutputPath = Full $OutputPath
$QemuImgPath = Full $QemuImgPath
$UnattendPath = Full $UnattendPath
$BootstrapPath = Full $BootstrapPath
$testImages = Full 'tools/tests/artifacts/qemu'

foreach ($path in @($StagingPath,$OutputPath)) {
    if (-not $path.StartsWith($testImages, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing Windows QEMU image path outside tools/tests/artifacts/qemu: $path"
    }
}
foreach ($required in @($StagingPath,$QemuImgPath,$UnattendPath,$BootstrapPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing required file: $required" }
}
if (Test-Path -LiteralPath $OutputPath) { throw "Output already exists: $OutputPath" }

$mounted = $null
try {
    $mounted = Mount-DiskImage -ImagePath $StagingPath -StorageType VHD -PassThru
    Start-Sleep -Milliseconds 500
    $disk = $mounted | Get-Disk
    if ($null -eq $disk) { throw 'Staging VHD did not expose a disk' }

    $partitions = @(Get-Partition -DiskNumber $disk.Number)
    $esp = $partitions | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } | Select-Object -First 1
    if ($null -eq $esp) { throw 'Staging VHD has no EFI System Partition' }
    if (-not $esp.DriveLetter) {
        Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $esp.PartitionNumber -AssignDriveLetter
        $esp = Get-Partition -DiskNumber $disk.Number -PartitionNumber $esp.PartitionNumber
    }

    $windowsPart = $null
    foreach ($part in $partitions) {
        if (-not $part.DriveLetter) { continue }
        $candidateRoot = "$($part.DriveLetter):\"
        if (Test-Path -LiteralPath (Join-Path $candidateRoot 'Windows\System32\kernel32.dll') -PathType Leaf) {
            $windowsPart = $part
            break
        }
    }
    if ($null -eq $windowsPart) { throw 'Staging VHD has no applied Windows partition' }

    $espRoot = "$($esp.DriveLetter):\"
    $windowsRoot = "$($windowsPart.DriveLetter):\"
    & bcdboot.exe (Join-Path $windowsRoot 'Windows') /s "$($esp.DriveLetter):" /f UEFI
    if ($LASTEXITCODE -ne 0) { throw "bcdboot failed: $LASTEXITCODE" }

    $testDir = Join-Path $windowsRoot 'USOS_TEST'
    $panther = Join-Path $windowsRoot 'Windows\Panther'
    New-Item -ItemType Directory -Force -Path $testDir,$panther | Out-Null
    Copy-Item -LiteralPath $BootstrapPath -Destination (Join-Path $testDir 'bootstrap.cmd') -Force
    Copy-Item -LiteralPath $UnattendPath -Destination (Join-Path $panther 'unattend.xml') -Force
    Copy-Item -LiteralPath $UnattendPath -Destination (Join-Path $windowsRoot 'unattend.xml') -Force

    $systemHive = Join-Path $windowsRoot 'Windows\System32\config\SYSTEM'
    & reg.exe load HKLM\USOSQEMU $systemHive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'failed to load offline SYSTEM hive' }
    try {
        foreach ($name in @('BypassTPMCheck','BypassSecureBootCheck','BypassRAMCheck')) {
            & reg.exe add HKLM\USOSQEMU\Setup\LabConfig /v $name /t REG_DWORD /d 1 /f | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "failed to set $name" }
        }
    } finally {
        & reg.exe unload HKLM\USOSQEMU | Out-Null
    }

    if (-not (Test-Path -LiteralPath (Join-Path $espRoot 'EFI\Microsoft\Boot\bootmgfw.efi') -PathType Leaf)) {
        throw 'bcdboot did not produce EFI Microsoft boot files'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $testDir 'bootstrap.cmd') -PathType Leaf)) {
        throw 'bootstrap.cmd missing after copy'
    }
    Write-Host '[PASS] Windows QEMU base finalization content prepared'
} finally {
    if ($null -ne $mounted) {
        Dismount-DiskImage -InputObject $mounted -ErrorAction SilentlyContinue | Out-Null
    }
}

$info = & $QemuImgPath info --output=json $StagingPath
if ($LASTEXITCODE -ne 0) { throw "qemu-img info failed for staging Windows base: $LASTEXITCODE" }
if (($info -join "`n") -notmatch '"format"\s*:\s*"vpc"') { throw 'staging Windows base is not VHD/VPC' }
Move-Item -LiteralPath $StagingPath -Destination $OutputPath
Write-Host "[PASS] Windows QEMU base finalized: $OutputPath"
