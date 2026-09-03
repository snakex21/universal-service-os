param(
    [Parameter(Mandatory=$true)][string]$IsoPath,
    [Parameter(Mandatory=$true)][string]$VhdPath,
    [Parameter(Mandatory=$true)][string]$BaseQcow2Path,
    [Parameter(Mandatory=$true)][string]$QemuImgPath,
    [Parameter(Mandatory=$true)][string]$BootEfiPath,
    [Parameter(Mandatory=$true)][string]$NtfsDriverPath
)

$ErrorActionPreference = 'Stop'
$IsoPath = [IO.Path]::GetFullPath($IsoPath)
$VhdPath = [IO.Path]::GetFullPath($VhdPath)
$BaseQcow2Path = [IO.Path]::GetFullPath($BaseQcow2Path)
$QemuImgPath = [IO.Path]::GetFullPath($QemuImgPath)
$BootEfiPath = [IO.Path]::GetFullPath($BootEfiPath)
$NtfsDriverPath = [IO.Path]::GetFullPath($NtfsDriverPath)
$DataType = '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'
$WorkType = $DataType
$EspType = '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
$WorkLabel = 'USOS_WORK'

function Assert-TestImagePath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\test-images'))
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing image path outside test-images: $full"
    }
}

Assert-TestImagePath $VhdPath
Assert-TestImagePath $BaseQcow2Path
foreach ($required in @($IsoPath, $QemuImgPath, $BootEfiPath, $NtfsDriverPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing required file: $required" }
}

$outDir = Split-Path -Parent $VhdPath
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
if (Test-Path -LiteralPath $VhdPath) { Remove-Item -LiteralPath $VhdPath -Force }
if (Test-Path -LiteralPath $BaseQcow2Path) { Remove-Item -LiteralPath $BaseQcow2Path -Force }

& $QemuImgPath create -f vpc -o subformat=fixed $VhdPath 12G
if ($LASTEXITCODE -ne 0) { throw "qemu-img create failed: $LASTEXITCODE" }
& fsutil.exe sparse setflag $VhdPath 0 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "failed to clear sparse flag on VHD: $LASTEXITCODE" }

$mountedVhd = $false
$mountedIso = $false
try {
    Mount-DiskImage -ImagePath $VhdPath -StorageType VHD | Out-Null
    $mountedVhd = $true
    Start-Sleep -Milliseconds 500

    $diskImage = Get-DiskImage -ImagePath $VhdPath
    $disk = $diskImage | Get-Disk
    if ($null -eq $disk) { throw 'VHD did not expose a disk' }
    if ($disk.PartitionStyle -ne 'RAW') { throw "New VHD is not RAW: $($disk.PartitionStyle)" }

    Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
    $disk = Get-Disk -Number $disk.Number
    $esp = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType $EspType -AssignDriveLetter
    $data = New-Partition -DiskNumber $disk.Number -Size 1024MB -GptType $DataType -AssignDriveLetter
    $work = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType $WorkType -AssignDriveLetter

    $esp | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'USOS_ESP' -Confirm:$false -Force | Out-Null
    $data | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'USOS_DATA' -Confirm:$false -Force | Out-Null
    $work | Format-Volume -FileSystem NTFS -NewFileSystemLabel $WorkLabel -Confirm:$false -Force | Out-Null

    $esp = Get-Partition -DiskNumber $disk.Number -PartitionNumber $esp.PartitionNumber
    $data = Get-Partition -DiskNumber $disk.Number -PartitionNumber $data.PartitionNumber
    $work = Get-Partition -DiskNumber $disk.Number -PartitionNumber $work.PartitionNumber
    if (-not $esp.DriveLetter -or -not $work.DriveLetter) { throw 'ESP or WORK has no temporary drive letter' }
    if (("$($work.DriveLetter):") -eq $env:SystemDrive) { throw 'WORK unexpectedly equals Windows root volume' }

    $espRoot = "$($esp.DriveLetter):\"
    $workRoot = "$($work.DriveLetter):\"
    $nonce = [Guid]::NewGuid().ToString('N')

    # WORK identity marker must be the first file written after format.
    $markerPath = Join-Path $workRoot '.usos-work'
    [IO.File]::WriteAllText($markerPath, "nonce=$nonce`r`n")
    $workFiles = @(Get-ChildItem -LiteralPath $workRoot -Force -File)
    if ($workFiles.Count -ne 1 -or $workFiles[0].Name -ne '.usos-work') {
        throw '.usos-work was not the first regular WORK file after format'
    }

    New-Item -ItemType Directory -Force -Path (Join-Path $espRoot 'EFI\BOOT') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $espRoot 'EFI\USOS') | Out-Null
    Copy-Item -LiteralPath $BootEfiPath -Destination (Join-Path $espRoot 'EFI\BOOT\BOOTX64.EFI') -Force
    Copy-Item -LiteralPath $NtfsDriverPath -Destination (Join-Path $espRoot 'EFI\USOS\ntfs_x64.efi') -Force

    $deviceIni = @(
        '[device]',
        "nonce=$nonce",
        "disk_ptuuid=$($disk.Guid)",
        "esp_partuuid=$($esp.Guid)",
        "data_partuuid=$($data.Guid)",
        "work_partuuid=$($work.Guid)",
        "work_label=$WorkLabel"
    ) -join "`r`n"
    $deviceIniPath = Join-Path $espRoot 'EFI\USOS\usos-device.ini'
    [IO.File]::WriteAllText($deviceIniPath, $deviceIni + "`r`n")

    Mount-DiskImage -ImagePath $IsoPath | Out-Null
    $mountedIso = $true
    Start-Sleep -Milliseconds 500
    $isoVolume = Get-DiskImage -ImagePath $IsoPath | Get-Volume | Where-Object DriveLetter | Select-Object -First 1
    if ($null -eq $isoVolume) { throw 'Windows ISO has no mounted volume' }
    $isoRoot = "$($isoVolume.DriveLetter):\"

    & robocopy.exe $isoRoot $workRoot /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -gt 7) { throw "robocopy failed: $LASTEXITCODE" }

    $markerNonce = ((Get-Content -LiteralPath $markerPath -Raw) -split '=', 2)[1].Trim()
    if ($markerNonce -ne $nonce) { throw '.usos-work nonce changed during extraction' }
    $iniNonceLine = Get-Content -LiteralPath $deviceIniPath | Where-Object { $_ -like 'nonce=*' } | Select-Object -First 1
    if ($iniNonceLine -ne "nonce=$nonce") { throw 'usos-device.ini nonce mismatch' }

    $install = Join-Path $workRoot 'sources\install.wim'
    if (-not (Test-Path -LiteralPath $install -PathType Leaf)) { throw 'sources/install.wim missing after extraction' }
    $installSize = (Get-Item -LiteralPath $install).Length

    $work = Get-Partition -DiskNumber $disk.Number -PartitionNumber $work.PartitionNumber
    $esp = Get-Partition -DiskNumber $disk.Number -PartitionNumber $esp.PartitionNumber
    $data = Get-Partition -DiskNumber $disk.Number -PartitionNumber $data.PartitionNumber
    $disk = Get-Disk -Number $disk.Number
    $workVolume = Get-Volume -DriveLetter $work.DriveLetter

    if ($disk.PartitionStyle -ne 'GPT') { throw 'Final image partition table is not GPT' }
    if ($work.GptType -ne $WorkType) { throw "WORK GPT type mismatch: expected Microsoft Basic Data $WorkType, got $($work.GptType)" }
    if ($esp.GptType -ne $EspType) { throw "ESP GPT type mismatch: $($esp.GptType)" }
    if ($data.GptType -ne $DataType) { throw "DATA GPT type mismatch: $($data.GptType)" }
    if ($workVolume.FileSystemLabel -ne $WorkLabel) { throw "WORK label mismatch: $($workVolume.FileSystemLabel)" }
    if ($work.Guid -eq $esp.Guid -or $work.Guid -eq $data.Guid -or $esp.Guid -eq $data.Guid) { throw 'Partition GUID collision' }

    Write-Host "[PASS] VHD GPT disk=$($disk.Guid)"
    Write-Host "[PASS] ESP PARTUUID=$($esp.Guid) FAT32"
    Write-Host "[PASS] DATA PARTUUID=$($data.Guid) NTFS"
    Write-Host "[PASS] WORK PARTUUID=$($work.Guid) type=$($work.GptType) label=$WorkLabel NTFS install.wim=$installSize"
    Write-Host "[PASS] WORK identity nonce=$nonce marker=.usos-work matches EFI/USOS/usos-device.ini"
}
finally {
    if ($mountedIso) { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null }
    if ($mountedVhd) { Dismount-DiskImage -ImagePath $VhdPath -ErrorAction SilentlyContinue | Out-Null }
}

& $QemuImgPath convert -f vpc -O qcow2 $VhdPath $BaseQcow2Path
if ($LASTEXITCODE -ne 0) { throw "qemu-img convert to qcow2 failed: $LASTEXITCODE" }
Remove-Item -LiteralPath $VhdPath -Force
Write-Host "[PASS] qcow2 base created: $BaseQcow2Path"