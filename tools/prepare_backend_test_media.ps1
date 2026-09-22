param(
    [string]$IsoPath = 'media/Systems/Windows/Windows 11/Images/Win11_25H2_Polish_x64_v2.iso',
    [string]$QemuImgPath = 'tools/qemu/qemu-img.exe',
    [string]$OutputDir = 'tools/tests/artifacts/qemu/backend-media',
    [int]$InstallImageIndex = 5,
    [int]$VhdxSizeGiB = 32
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Full([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $root $Path))
}

$IsoPath = Full $IsoPath
$QemuImgPath = Full $QemuImgPath
$OutputDir = Full $OutputDir
$testRoot = Full 'tools/tests/artifacts/qemu'
if (-not $OutputDir.StartsWith($testRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing backend media output outside tools/tests/artifacts/qemu: $OutputDir"
}
foreach ($required in @($IsoPath,$QemuImgPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing required file: $required" }
}
if ($InstallImageIndex -lt 1 -or $InstallImageIndex -gt 50) { throw 'InstallImageIndex must be in range 1..50' }
if ($VhdxSizeGiB -lt 24 -or $VhdxSizeGiB -gt 64) { throw 'VhdxSizeGiB must be in range 24..64' }

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$wimOut = Join-Path $OutputDir 'Win11_25H2_Polish_x64_v2.wim'
$vhdxOut = Join-Path $OutputDir 'Win11_25H2_Polish_x64_v2.vhdx'

$isoMounted = $false
$vhdMounted = $false
try {
    Mount-DiskImage -ImagePath $IsoPath -StorageType ISO | Out-Null
    $isoMounted = $true
    Start-Sleep -Milliseconds 300
    $isoVolume = Get-DiskImage -ImagePath $IsoPath | Get-Volume | Select-Object -First 1
    if ($null -eq $isoVolume -or -not $isoVolume.DriveLetter) { throw 'Mounted Windows ISO has no drive letter required by DISM' }
    $isoRoot = "$($isoVolume.DriveLetter):\"
    $bootWim = Join-Path $isoRoot 'sources\boot.wim'
    $installImage = Join-Path $isoRoot 'sources\install.wim'
    if (-not (Test-Path -LiteralPath $installImage -PathType Leaf)) {
        $installImage = Join-Path $isoRoot 'sources\install.esd'
    }
    foreach ($required in @($bootWim,$installImage)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Windows ISO backend test source missing: $required" }
    }

    Copy-Item -LiteralPath $bootWim -Destination $wimOut -Force
    if ((Get-Item -LiteralPath $wimOut).Length -ne (Get-Item -LiteralPath $bootWim).Length) {
        throw 'WIM fixture size mismatch after copy'
    }
    Write-Host "[PASS] WIM input prepared from ISO boot.wim: $wimOut"

    if (Test-Path -LiteralPath $vhdxOut) {
        $existingImage = Get-DiskImage -ImagePath $vhdxOut -ErrorAction SilentlyContinue
        if ($null -ne $existingImage -and $existingImage.Attached) {
            $staleDetach = Join-Path $OutputDir '.detach-stale-backend-vhdx.diskpart.txt'
            try {
                [IO.File]::WriteAllLines($staleDetach, @(
                    "select vdisk file=`"$vhdxOut`"",
                    'detach vdisk',
                    'exit'
                ))
                & diskpart.exe /s $staleDetach | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "DiskPart stale VHDX detach failed: $LASTEXITCODE" }
            } finally {
                Remove-Item -LiteralPath $staleDetach -Force -ErrorAction SilentlyContinue
            }
            Start-Sleep -Milliseconds 500
        }
        Remove-Item -LiteralPath $vhdxOut -Force
    }
    $diskpartScript = Join-Path $OutputDir '.create-backend-vhdx.diskpart.txt'
    try {
        $maximumMiB = $VhdxSizeGiB * 1024
        [IO.File]::WriteAllLines($diskpartScript, @(
            "create vdisk file=`"$vhdxOut`" maximum=$maximumMiB type=expandable",
            'exit'
        ))
        & diskpart.exe /s $diskpartScript | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $vhdxOut -PathType Leaf)) {
            throw "DiskPart create VHDX failed: $LASTEXITCODE"
        }
    } finally {
        Remove-Item -LiteralPath $diskpartScript -Force -ErrorAction SilentlyContinue
    }

    $attachScript = Join-Path $OutputDir '.attach-backend-vhdx.diskpart.txt'
    try {
        [IO.File]::WriteAllLines($attachScript, @(
            "select vdisk file=`"$vhdxOut`"",
            'attach vdisk',
            'exit'
        ))
        & diskpart.exe /s $attachScript | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "DiskPart attach VHDX failed: $LASTEXITCODE" }
    } finally {
        Remove-Item -LiteralPath $attachScript -Force -ErrorAction SilentlyContinue
    }
    $vhdMounted = $true
    Start-Sleep -Milliseconds 500
    $disk = Get-DiskImage -ImagePath $vhdxOut | Get-Disk
    if ($null -eq $disk) { throw 'VHDX did not expose a disk' }
    if ($disk.PartitionStyle -ne 'RAW') { throw "New VHDX is not RAW: $($disk.PartitionStyle)" }
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
    $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}' -AssignDriveLetter
    $partition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'USOS_VHD_TEST' -Force -Confirm:$false | Out-Null
    $partition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber
    if (-not $partition.DriveLetter) { throw 'VHDX Windows partition has no drive letter' }
    $applyRoot = "$($partition.DriveLetter):\"

    Write-Host "[INFO] Applying Windows image index $InstallImageIndex to test VHDX"
    & dism.exe /English /Apply-Image /ImageFile:$installImage /Index:$InstallImageIndex /ApplyDir:$applyRoot
    if ($LASTEXITCODE -ne 0) { throw "DISM Apply-Image for VHDX fixture failed: $LASTEXITCODE" }
    foreach ($required in @('Windows\System32\winload.efi','Windows\System32\kernel32.dll')) {
        $candidate = Join-Path $applyRoot $required
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "Applied VHDX is missing $required" }
    }
    Write-Host '[PASS] bootable Windows VHDX input contains winload.efi and Windows system files'
} finally {
    if ($vhdMounted) {
        $detachScript = Join-Path $OutputDir '.detach-backend-vhdx.diskpart.txt'
        try {
            [IO.File]::WriteAllLines($detachScript, @(
                "select vdisk file=`"$vhdxOut`"",
                'detach vdisk',
                'exit'
            ))
            & diskpart.exe /s $detachScript | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "DiskPart detach VHDX failed: $LASTEXITCODE" }
            Start-Sleep -Milliseconds 500
        } finally {
            Remove-Item -LiteralPath $detachScript -Force -ErrorAction SilentlyContinue
        }
    }
    if ($isoMounted) { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null }
}

& $QemuImgPath check $vhdxOut
if ($LASTEXITCODE -ne 0) { throw "qemu-img check failed for VHDX input: $LASTEXITCODE" }
$wimBytes = (Get-Item -LiteralPath $wimOut).Length
$vhdxBytes = (Get-Item -LiteralPath $vhdxOut).Length
Write-Host "[PASS] backend inputs ready WIM=$wimBytes bytes VHDX=$vhdxBytes bytes"
