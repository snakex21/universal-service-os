param(
    [string]$IsoPath = 'media/Systems/Windows/Windows 11/Images/Win11_25H2_Polish_x64_v2.iso',
    [string]$QemuImgPath = 'tools/qemu/qemu-img.exe',
    [string]$InstallerTargetQcow2 = 'tools/tests/artifacts/qemu/usos-installer-full-target.qcow2',
    [string]$MountedTargetVhd = 'tools/tests/artifacts/qemu/.staging-usos-backend-target.vhd',
    [string]$OutputBaseQcow2 = 'tools/tests/artifacts/qemu/usos-backend-e2e-base.qcow2',
    [string]$BackendMediaDir = 'tools/tests/artifacts/qemu/backend-media',
    [string]$InstallerRuntimeConfigDir = 'tools/tests/artifacts/qemu/usos-backend-installer-config',
    [int]$InstallerTimeoutSeconds = 600,
    [switch]$ReuseInstallerTarget,
    [switch]$ReuseBackendMedia
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Full([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $root $Path))
}

$IsoPath = Full $IsoPath
$QemuImgPath = Full $QemuImgPath
$InstallerTargetQcow2 = Full $InstallerTargetQcow2
$MountedTargetVhd = Full $MountedTargetVhd
$OutputBaseQcow2 = Full $OutputBaseQcow2
$BackendMediaDir = Full $BackendMediaDir
$InstallerRuntimeConfigDir = Full $InstallerRuntimeConfigDir
$testRoot = Full 'tools/tests/artifacts/qemu'
$installerPath = Full 'installer/USOS Installer.exe'
$updateExe = Full 'tools/tests/artifacts/qemu/usos-backend-e2e-update.exe'
$updateLog = Full 'tools/tests/artifacts/qemu/usos-backend-e2e-update.log'
$wimInput = Join-Path $BackendMediaDir 'Win11_25H2_Polish_x64_v2.wim'
$vhdxInput = Join-Path $BackendMediaDir 'Win11_25H2_Polish_x64_v2.vhdx'

foreach ($path in @($InstallerTargetQcow2,$MountedTargetVhd,$OutputBaseQcow2,$BackendMediaDir,$InstallerRuntimeConfigDir,$updateExe,$updateLog)) {
    if (-not $path.StartsWith($testRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing backend E2E path outside tools/tests/artifacts/qemu: $path"
    }
}
foreach ($required in @($IsoPath,$QemuImgPath,$installerPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing required file: $required" }
}
if ($InstallerTimeoutSeconds -lt 120 -or $InstallerTimeoutSeconds -gt 1800) { throw 'InstallerTimeoutSeconds must be in range 120..1800' }

# Test media is user content only. This helper may create WIM/VHDX input images,
# but it must never author USOS templates, BCD stores, boot managers or identity.
if ($ReuseBackendMedia) {
    foreach ($required in @($wimInput,$vhdxInput)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf) -or (Get-Item -LiteralPath $required).Length -le 0) {
            throw "Cannot reuse missing backend input media: $required"
        }
    }
    & $QemuImgPath check $vhdxInput
    if ($LASTEXITCODE -ne 0) { throw "reused backend VHDX failed qemu-img check: $LASTEXITCODE" }
    Write-Host '[PASS] reusing existing WIM/VHDX user inputs'
} else {
    & (Full 'tools/prepare_backend_test_media.ps1') -IsoPath $IsoPath -QemuImgPath $QemuImgPath -OutputDir $BackendMediaDir
    if ($LASTEXITCODE -ne 0) { throw "backend test media preparation failed: $LASTEXITCODE" }
    foreach ($required in @($wimInput,$vhdxInput)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf) -or (Get-Item -LiteralPath $required).Length -le 0) {
            throw "Missing backend input media: $required"
        }
    }
}

# The target USOS media must come exclusively from the real production install
# engine. Reuse mode exists specifically so WIMBoot/VHDBoot can continue from a
# previously verified production target without starting another installer VM.
if ($ReuseInstallerTarget) {
    if (-not (Test-Path -LiteralPath $InstallerTargetQcow2 -PathType Leaf)) {
        throw "Cannot reuse missing production installer target: $InstallerTargetQcow2"
    }
    & $QemuImgPath check $InstallerTargetQcow2
    if ($LASTEXITCODE -ne 0) { throw "reused production installer target qcow2 check failed: $LASTEXITCODE" }
    Write-Host '[PASS] reusing previously verified production install.Engine target'
} else {
    & (Full 'tools/run_installer_gpt_qemu.ps1') `
        -IsoPath $IsoPath `
        -QemuImgPath $QemuImgPath `
        -TargetImage $InstallerTargetQcow2 `
        -RuntimeConfigDir $InstallerRuntimeConfigDir `
        -TimeoutSeconds $InstallerTimeoutSeconds
    if ($LASTEXITCODE -ne 0) { throw "production installer E2E failed: $LASTEXITCODE" }
    & $QemuImgPath check $InstallerTargetQcow2
    if ($LASTEXITCODE -ne 0) { throw "production installer target qcow2 check failed: $LASTEXITCODE" }
    Write-Host '[PASS] production install.Engine created the backend E2E USOS target'
}

# Convert only to a Windows-mountable representation of that exact production
# target. The only host-side changes before local update are user-added images.
Dismount-DiskImage -ImagePath $MountedTargetVhd -ErrorAction SilentlyContinue | Out-Null
Remove-Item -LiteralPath $MountedTargetVhd -Force -ErrorAction SilentlyContinue
& $QemuImgPath convert -f qcow2 -O vpc -o subformat=dynamic,force_size=on $InstallerTargetQcow2 $MountedTargetVhd
if ($LASTEXITCODE -ne 0) { throw "convert production target to VHD failed: $LASTEXITCODE" }
& fsutil.exe sparse setflag $MountedTargetVhd 0 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "failed to clear sparse flag on converted backend VHD: $LASTEXITCODE" }

$mounted = $false
try {
    Mount-DiskImage -ImagePath $MountedTargetVhd -StorageType VHD -NoDriveLetter | Out-Null
    $mounted = $true
    Start-Sleep -Milliseconds 700
    $disk = Get-DiskImage -ImagePath $MountedTargetVhd | Get-Disk
    if ($null -eq $disk) { throw 'mounted production target VHD did not expose a disk' }
    if ($disk.IsBoot -or $disk.IsSystem) { throw "refusing mounted system disk PhysicalDrive$($disk.Number)" }
    $identityText = ("$($disk.FriendlyName) $($disk.Model) $($disk.BusType)").ToLowerInvariant()
    if ($identityText -notmatch 'virtual|file') { throw "refusing non-virtual mounted disk PhysicalDrive$($disk.Number): $identityText" }

    $dataVolume = $null
    foreach ($partition in Get-Partition -DiskNumber $disk.Number) {
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        if ($null -ne $volume -and $volume.FileSystemLabel -eq 'USOS_DATA') {
            if ($null -ne $dataVolume) { throw 'multiple USOS_DATA volumes on mounted production target' }
            $dataVolume = $volume
        }
    }
    if ($null -eq $dataVolume -or [string]::IsNullOrWhiteSpace($dataVolume.Path)) { throw 'production target has no resolvable USOS_DATA volume' }
    $imagesDir = Join-Path $dataVolume.Path 'Systems\Windows\Windows 11\Images'
    if (-not (Test-Path -LiteralPath $imagesDir -PathType Container)) { throw "production installer did not create expected DATA Images directory: $imagesDir" }

    # These files are exactly equivalent to user-added media before running
    # Aktualizuj USOS. No generated USOS artifact is written here.
    Copy-Item -LiteralPath $IsoPath -Destination (Join-Path $imagesDir (Split-Path -Leaf $IsoPath)) -Force
    Copy-Item -LiteralPath $wimInput -Destination (Join-Path $imagesDir (Split-Path -Leaf $wimInput)) -Force
    Copy-Item -LiteralPath $vhdxInput -Destination (Join-Path $imagesDir (Split-Path -Leaf $vhdxInput)) -Force
    foreach ($source in @($IsoPath,$wimInput,$vhdxInput)) {
        $destination = Join-Path $imagesDir (Split-Path -Leaf $source)
        if ((Get-Item -LiteralPath $destination).Length -ne (Get-Item -LiteralPath $source).Length) {
            throw "backend input size mismatch after DATA copy: $destination"
        }
    }
    Write-Host '[PASS] ISO, WIM and VHDX user inputs copied to production-created DATA'

    Push-Location (Full 'installer')
    try {
        & go.exe build -trimpath -o $updateExe ./cmd/usos-backend-e2e-update
        if ($LASTEXITCODE -ne 0) { throw "build usos-backend-e2e-update failed: $LASTEXITCODE" }
    } finally {
        Pop-Location
    }

    # This runner invokes the production localupdate.Engine, whose backend calls
    # the same CopyInstallPayload() used by Aktualizuj USOS.
    & $updateExe -disk $disk.Number -installer $installerPath -log $updateLog
    if ($LASTEXITCODE -ne 0) { throw "production local-update E2E failed: $LASTEXITCODE" }

    $wimTemplate = Join-Path $dataVolume.Path 'Programs\USOS\WimBootTemplate'
    $vhdRoot = Join-Path $dataVolume.Path 'Programs\USOS\VHDBoot'
    $vhdRelative = 'Systems\Windows\Windows 11\Images\Win11_25H2_Polish_x64_v2.vhdx'
    foreach ($required in @(
        (Join-Path $wimTemplate 'EFI\BOOT\BOOTX64.EFI'),
        (Join-Path $wimTemplate 'EFI\Microsoft\Boot\BCD'),
        (Join-Path $wimTemplate 'boot\boot.sdi'),
        (Join-Path $vhdRoot 'Shared\EFI\BOOT\BOOTX64.EFI'),
        (Join-Path $vhdRoot (Join-Path 'Entries' (Join-Path $vhdRelative 'BCD')))
    )) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf) -or (Get-Item -LiteralPath $required).Length -le 0) {
            throw "production update did not generate required backend artifact: $required"
        }
    }
    Write-Host '[PASS] production CopyInstallPayload generated WIMBoot and VHDBoot templates'
} finally {
    if ($mounted) { Dismount-DiskImage -ImagePath $MountedTargetVhd -ErrorAction SilentlyContinue | Out-Null }
}

Remove-Item -LiteralPath $OutputBaseQcow2 -Force -ErrorAction SilentlyContinue
& $QemuImgPath convert -f vpc -O qcow2 $MountedTargetVhd $OutputBaseQcow2
if ($LASTEXITCODE -ne 0) { throw "convert production backend target to qcow2 failed: $LASTEXITCODE" }
& $QemuImgPath check $OutputBaseQcow2
if ($LASTEXITCODE -ne 0) { throw "backend E2E base qcow2 check failed: $LASTEXITCODE" }
Write-Host "[PASS] backend E2E base prepared exclusively through production install/update code: $OutputBaseQcow2"
