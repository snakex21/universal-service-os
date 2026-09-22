param(
    [string]$IsoPath = 'media/Systems/Windows/Windows 11/Images/Win11_25H2_Polish_x64_v2.iso',
    [string]$VhdxPath = 'tools/tests/artifacts/qemu/usos-installer-windows-base.vhd',
    [string]$QemuImgPath = 'tools/qemu/qemu-img.exe',
    [string]$UnattendPath = 'tools/tests/fixtures/installer/windows-qemu-base/unattend.xml',
    [string]$BootstrapPath = 'tools/tests/fixtures/installer/windows-qemu-base/bootstrap.cmd',
    [string]$SetupCompletePath = 'tools/tests/fixtures/installer/windows-qemu-base/SetupComplete.cmd',
    [int]$ImageIndex = 5
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Full([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $root $Path))
}
$IsoPath = Full $IsoPath
$VhdxPath = Full $VhdxPath
$QemuImgPath = Full $QemuImgPath
$UnattendPath = Full $UnattendPath
$BootstrapPath = Full $BootstrapPath
$SetupCompletePath = Full $SetupCompletePath
$testImages = Full 'tools/tests/artifacts/qemu'

if (-not $VhdxPath.StartsWith($testImages, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing Windows QEMU base outside tools/tests/artifacts/qemu: $VhdxPath"
}
foreach ($required in @($IsoPath,$QemuImgPath,$UnattendPath,$BootstrapPath,$SetupCompletePath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing required file: $required" }
}
if (Test-Path -LiteralPath $VhdxPath) {
    Write-Host "[PASS] Windows QEMU base already exists: $VhdxPath"
    exit 0
}

$staging = Join-Path $testImages '.staging-usos-installer-windows-base.vhd'
if (Test-Path -LiteralPath $staging) {
    Dismount-DiskImage -ImagePath $staging -StorageType VHD -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -LiteralPath $staging -Force
}
& $QemuImgPath create -f vpc -o subformat=fixed $staging 32G
if ($LASTEXITCODE -ne 0) { throw "qemu-img create fixed VHD failed: $LASTEXITCODE" }
& fsutil.exe sparse setflag $staging 0 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "failed to clear sparse flag on Windows base VHD: $LASTEXITCODE" }

$vhdMounted = $false
$mountedVhd = $null
$isoMounted = $false
try {
    $mountedVhd = Mount-DiskImage -ImagePath $staging -StorageType VHD -PassThru
    $vhdMounted = $true
    Start-Sleep -Milliseconds 500
    $disk = $mountedVhd | Get-Disk
    if ($null -eq $disk) { throw 'VHDX did not expose a disk' }
    if ($disk.PartitionStyle -ne 'RAW') { throw "New Windows base disk is not RAW: $($disk.PartitionStyle)" }

    Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
    $esp = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}' -AssignDriveLetter
    $null = New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}'
    $windowsPart = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}' -AssignDriveLetter
    $esp | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'SYSTEM' -Force -Confirm:$false | Out-Null
    $windowsPart | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows' -Force -Confirm:$false | Out-Null

    $espRoot = "$($esp.DriveLetter):\"
    $windowsRoot = "$($windowsPart.DriveLetter):\"
    Mount-DiskImage -ImagePath $IsoPath | Out-Null
    $isoMounted = $true
    $isoVolume = Get-DiskImage -ImagePath $IsoPath | Get-Volume
    if ($null -eq $isoVolume.DriveLetter) { throw 'Windows ISO has no drive letter' }
    $sourceRoot = "$($isoVolume.DriveLetter):\"
    $wim = Join-Path $sourceRoot 'sources\install.wim'
    if (-not (Test-Path -LiteralPath $wim -PathType Leaf)) {
        $wim = Join-Path $sourceRoot 'sources\install.esd'
    }
    if (-not (Test-Path -LiteralPath $wim -PathType Leaf)) { throw 'Windows ISO has no install.wim/install.esd' }

    Write-Host "[INFO] Applying Windows image index $ImageIndex to $windowsRoot"
    & dism.exe /English /Apply-Image /ImageFile:$wim /Index:$ImageIndex /ApplyDir:$windowsRoot
    if ($LASTEXITCODE -ne 0) { throw "DISM Apply-Image failed: $LASTEXITCODE" }

    & bcdboot.exe (Join-Path $windowsRoot 'Windows') /s "$($esp.DriveLetter):" /f UEFI
    if ($LASTEXITCODE -ne 0) { throw "bcdboot failed: $LASTEXITCODE" }

    $testDir = Join-Path $windowsRoot 'USOS_TEST'
    $panther = Join-Path $windowsRoot 'Windows\Panther'
    $setupScripts = Join-Path $windowsRoot 'Windows\Setup\Scripts'
    New-Item -ItemType Directory -Force -Path $testDir,$panther,$setupScripts | Out-Null
    Copy-Item -LiteralPath $BootstrapPath -Destination (Join-Path $testDir 'bootstrap.cmd') -Force
    Copy-Item -LiteralPath $SetupCompletePath -Destination (Join-Path $setupScripts 'SetupComplete.cmd') -Force
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

    if (-not (Test-Path -LiteralPath (Join-Path $setupScripts 'SetupComplete.cmd') -PathType Leaf)) { throw 'SetupComplete.cmd missing after copy' }
    Write-Host '[PASS] Windows files, UEFI boot and deterministic SetupComplete test bootstrap prepared'
} finally {
    if ($isoMounted) { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null }
    if ($vhdMounted -and $null -ne $mountedVhd) { Dismount-DiskImage -InputObject $mountedVhd -ErrorAction SilentlyContinue | Out-Null }
}

& $QemuImgPath check $staging
if ($LASTEXITCODE -ne 0) { throw "qemu-img check failed for Windows base: $LASTEXITCODE" }
Move-Item -LiteralPath $staging -Destination $VhdxPath
Write-Host "[PASS] Windows QEMU base created: $VhdxPath"
