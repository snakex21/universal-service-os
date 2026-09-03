param(
    [Parameter(Mandatory=$true)][string]$IsoPath,
    [Parameter(Mandatory=$true)][string]$VhdPath,
    [Parameter(Mandatory=$true)][string]$BaseQcow2Path,
    [Parameter(Mandatory=$true)][string]$QemuImgPath,
    [Parameter(Mandatory=$true)][string]$BootEfiPath,
    [Parameter(Mandatory=$true)][string]$NtfsDriverPath,
    [Parameter(Mandatory=$true)][string]$MicroLinuxKernelPath,
    [Parameter(Mandatory=$true)][string]$MicroLinuxInitramfsPath,
    [Parameter(Mandatory=$true)][string]$MicroLinuxLoaderPath,
    [string]$UnattendPath = '',
    [string]$GuardTestBadPartuuid = ''
)

$ErrorActionPreference = 'Stop'
foreach ($name in @('IsoPath','VhdPath','BaseQcow2Path','QemuImgPath','BootEfiPath','NtfsDriverPath','MicroLinuxKernelPath','MicroLinuxInitramfsPath','MicroLinuxLoaderPath')) {
    Set-Variable -Name $name -Value ([IO.Path]::GetFullPath((Get-Variable -Name $name -ValueOnly)))
}
if (-not [string]::IsNullOrWhiteSpace($UnattendPath)) { $UnattendPath = [IO.Path]::GetFullPath($UnattendPath) }

$testImagesRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\test-images'))
foreach ($path in @($VhdPath, $BaseQcow2Path)) {
    if (-not $path.StartsWith($testImagesRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing image path outside test-images: $path"
    }
}
$candidateBasePath = "$BaseQcow2Path.new"
if (-not $candidateBasePath.StartsWith($testImagesRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing candidate image path outside test-images: $candidateBasePath"
}
foreach ($required in @($IsoPath, $QemuImgPath, $BootEfiPath, $NtfsDriverPath, $MicroLinuxKernelPath, $MicroLinuxInitramfsPath, $MicroLinuxLoaderPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing required file: $required" }
}
if (-not [string]::IsNullOrWhiteSpace($UnattendPath) -and -not (Test-Path -LiteralPath $UnattendPath -PathType Leaf)) {
    throw "Missing unattended file: $UnattendPath"
}

$BasicDataType = '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'
$EspType = '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
$WorkLabel = 'USOS_WORK'
$DataLabel = 'USOS_DATA'

New-Item -ItemType Directory -Force -Path $testImagesRoot | Out-Null
if (Test-Path -LiteralPath $VhdPath) { Remove-Item -LiteralPath $VhdPath -Force }
if (Test-Path -LiteralPath $candidateBasePath) { Remove-Item -LiteralPath $candidateBasePath -Force }

& $QemuImgPath create -f vpc -o subformat=fixed $VhdPath 24G
if ($LASTEXITCODE -ne 0) { throw "qemu-img VHD create failed: $LASTEXITCODE" }
& fsutil.exe sparse setflag $VhdPath 0 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "failed to clear sparse flag on VHD: $LASTEXITCODE" }

$mountedVhd = $false
try {
    Mount-DiskImage -ImagePath $VhdPath -StorageType VHD | Out-Null
    $mountedVhd = $true
    Start-Sleep -Milliseconds 500

    $disk = Get-DiskImage -ImagePath $VhdPath | Get-Disk
    if ($null -eq $disk) { throw 'VHD did not expose a disk' }
    if ($disk.PartitionStyle -ne 'RAW') { throw "New VHD is not RAW: $($disk.PartitionStyle)" }

    Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
    $disk = Get-Disk -Number $disk.Number
    $esp = New-Partition -DiskNumber $disk.Number -Size 512MB -GptType $EspType -AssignDriveLetter
    $data = New-Partition -DiskNumber $disk.Number -Size 10GB -GptType $BasicDataType -AssignDriveLetter
    $work = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType $BasicDataType -AssignDriveLetter

    $esp | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'USOS_ESP' -Confirm:$false -Force | Out-Null
    $data | Format-Volume -FileSystem NTFS -NewFileSystemLabel $DataLabel -Confirm:$false -Force | Out-Null
    $work | Format-Volume -FileSystem NTFS -NewFileSystemLabel $WorkLabel -Confirm:$false -Force | Out-Null

    $esp = Get-Partition -DiskNumber $disk.Number -PartitionNumber $esp.PartitionNumber
    $data = Get-Partition -DiskNumber $disk.Number -PartitionNumber $data.PartitionNumber
    $work = Get-Partition -DiskNumber $disk.Number -PartitionNumber $work.PartitionNumber
    $espRoot = "$($esp.DriveLetter):\"
    $dataRoot = "$($data.DriveLetter):\"
    $workRoot = "$($work.DriveLetter):\"
    if (("$($work.DriveLetter):") -eq $env:SystemDrive) { throw 'WORK unexpectedly equals Windows root volume' }

    $diskGuid = "$($disk.Guid)".Trim('{}')
    $espGuid = "$($esp.Guid)".Trim('{}')
    $dataGuid = "$($data.Guid)".Trim('{}')
    $workGuid = "$($work.Guid)".Trim('{}')

    $nonce = [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText((Join-Path $workRoot '.usos-work'), "nonce=$nonce`r`n")
    $regularWorkFiles = @(Get-ChildItem -LiteralPath $workRoot -Force -File)
    if ($regularWorkFiles.Count -ne 1 -or $regularWorkFiles[0].Name -ne '.usos-work') {
        throw '.usos-work was not the first regular WORK file'
    }

    New-Item -ItemType Directory -Force -Path (Join-Path $espRoot 'EFI\BOOT') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $espRoot 'EFI\USOS') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $espRoot 'EFI\USOS\micro-linux') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $espRoot 'loader\entries') | Out-Null
    Copy-Item -LiteralPath $BootEfiPath -Destination (Join-Path $espRoot 'EFI\BOOT\BOOTX64.EFI') -Force
    Copy-Item -LiteralPath $NtfsDriverPath -Destination (Join-Path $espRoot 'EFI\USOS\ntfs_x64.efi') -Force
    Copy-Item -LiteralPath $MicroLinuxLoaderPath -Destination (Join-Path $espRoot 'EFI\USOS\systemd-bootx64.efi') -Force
    Copy-Item -LiteralPath $MicroLinuxKernelPath -Destination (Join-Path $espRoot 'EFI\USOS\micro-linux\vmlinuz-virt') -Force
    Copy-Item -LiteralPath $MicroLinuxInitramfsPath -Destination (Join-Path $espRoot 'EFI\USOS\micro-linux\initramfs-usos') -Force
    [IO.File]::WriteAllText((Join-Path $espRoot 'loader\loader.conf'), "default usos-micro-linux.conf`r`ntimeout 0`r`neditor no`r`n")
    $kernelOptions = "console=tty0 console=ttyS0,115200 rdinit=/usos-init usos.esp_partuuid=$espGuid"
    if (-not [string]::IsNullOrWhiteSpace($GuardTestBadPartuuid)) {
        if ($GuardTestBadPartuuid -notmatch '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$') {
            throw "GuardTestBadPartuuid is not a GUID: $GuardTestBadPartuuid"
        }
        $kernelOptions += " usos.guard_test_bad_partuuid=$GuardTestBadPartuuid"
    }
    $loaderEntry = @(
        'title USOS micro-Linux preparation',
        'linux /EFI/USOS/micro-linux/vmlinuz-virt',
        'initrd /EFI/USOS/micro-linux/initramfs-usos',
        "options $kernelOptions"
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $espRoot 'loader\entries\usos-micro-linux.conf'), $loaderEntry + "`r`n")

    $deviceIni = @(
        '[device]',
        "nonce=$nonce",
        "disk_ptuuid=$diskGuid",
        "esp_partuuid=$espGuid",
        "data_partuuid=$dataGuid",
        "work_partuuid=$workGuid",
        "work_label=$WorkLabel",
        "data_label=$DataLabel"
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $espRoot 'EFI\USOS\usos-device.ini'), $deviceIni + "`r`n")
    [IO.File]::WriteAllText((Join-Path $espRoot 'EFI\USOS\install-state.ini'), "phase=pending`r`n")

    $imageDir = Join-Path $dataRoot 'Systems\Windows\Windows 11\Images'
    $unattendDir = Join-Path $dataRoot 'Systems\Windows\Windows 11\Unattended'
    New-Item -ItemType Directory -Force -Path $imageDir,$unattendDir | Out-Null
    $isoDestination = Join-Path $imageDir (Split-Path -Leaf $IsoPath)
    Copy-Item -LiteralPath $IsoPath -Destination $isoDestination -Force
    if ((Get-Item -LiteralPath $isoDestination).Length -ne (Get-Item -LiteralPath $IsoPath).Length) {
        throw 'DATA ISO size mismatch after copy'
    }
    if (-not [string]::IsNullOrWhiteSpace($UnattendPath)) {
        Copy-Item -LiteralPath $UnattendPath -Destination (Join-Path $unattendDir 'unattend.xml') -Force
    }

    # The ESP contains only catalog entries. The large payload stays on DATA
    # and is addressed by the selected relative path persisted by USOS.
    $espImageDir = Join-Path $espRoot 'Systems\Windows\Windows 11\Images'
    $espUnattendDir = Join-Path $espRoot 'Systems\Windows\Windows 11\Unattended'
    New-Item -ItemType Directory -Force -Path $espImageDir,$espUnattendDir | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $espImageDir (Split-Path -Leaf $IsoPath)), [byte[]]@())
    if (-not [string]::IsNullOrWhiteSpace($UnattendPath)) {
        Copy-Item -LiteralPath $UnattendPath -Destination (Join-Path $espUnattendDir 'unattend.xml') -Force
    }

    $workVolume = Get-Volume -DriveLetter $work.DriveLetter
    $dataVolume = Get-Volume -DriveLetter $data.DriveLetter
    if ($work.GptType -ne $BasicDataType -or $data.GptType -ne $BasicDataType) { throw 'WORK/DATA GPT type is not Microsoft Basic Data' }
    if ($workVolume.FileSystemLabel -ne $WorkLabel) { throw "WORK label mismatch: $($workVolume.FileSystemLabel)" }
    if ($dataVolume.FileSystemLabel -ne $DataLabel) { throw "DATA label mismatch: $($dataVolume.FileSystemLabel)" }
    if ($work.Guid -eq $data.Guid -or $work.Guid -eq $esp.Guid -or $data.Guid -eq $esp.Guid) { throw 'Partition GUID collision' }

    Write-Host "[PASS] E2E VHD GPT disk=$diskGuid"
    Write-Host "[PASS] ESP PARTUUID=$espGuid FAT32 micro-Linux=ready"
    Write-Host "[PASS] DATA PARTUUID=$dataGuid label=$DataLabel ISO=$isoDestination"
    Write-Host "[PASS] WORK PARTUUID=$workGuid label=$WorkLabel marker=.usos-work nonce=$nonce"
    Write-Host '[PASS] state phase=pending'
} finally {
    if ($mountedVhd) { Dismount-DiskImage -ImagePath $VhdPath -ErrorAction SilentlyContinue | Out-Null }
}

& $QemuImgPath convert -f vpc -O qcow2 $VhdPath $candidateBasePath
if ($LASTEXITCODE -ne 0) { throw "qemu-img convert to qcow2 failed: $LASTEXITCODE" }
& $QemuImgPath check $candidateBasePath
if ($LASTEXITCODE -ne 0) { throw "qemu-img check of candidate base failed: $LASTEXITCODE" }
if (Test-Path -LiteralPath $BaseQcow2Path) { Remove-Item -LiteralPath $BaseQcow2Path -Force }
Move-Item -LiteralPath $candidateBasePath -Destination $BaseQcow2Path
Remove-Item -LiteralPath $VhdPath -Force
Write-Host "[PASS] E2E qcow2 base created: $BaseQcow2Path"
