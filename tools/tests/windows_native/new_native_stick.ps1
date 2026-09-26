<#
.SYNOPSIS
  Test-only USOS stick image for the Windows 10/11 native UEFI path (QEMU).

.DESCRIPTION
  Creates a dynamic VHD with the production GPT layout (USOS_ESP FAT32 1 GiB,
  USOS_DATA NTFS, USOS_WORK NTFS), fills the ESP from the embedded payload
  (installer/internal/payload/assets/payload.zip) plus the per-device files
  the installer writes (usos-device.ini, install-state.ini, loader entry, the
  language files), and puts the Windows ISO (and optionally an answer file)
  on DATA. Nothing outside tools/tests/artifacts is written.
#>
param(
    [Parameter(Mandatory = $true)][string]$IsoPath,
    [Parameter(Mandatory = $true)][string]$VhdPath,
    [string]$System = 'Windows 11',
    [string]$UnattendPath = '',
    [string]$Language = 'pl',
    [string]$DataDriversPath = '',
    # PE10 donor for Vista / Windows 7 originals: copied to DATA\Programs\USOS\WinPE
    # and recorded in EFI\USOS\winpe-donor.ini, as the installer does.
    [string]$DonorPath = '',
    [int]$SizeGB = 20
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$artifacts = [IO.Path]::GetFullPath((Join-Path $root 'tools\tests\artifacts'))
$VhdPath = [IO.Path]::GetFullPath($VhdPath)
if (-not $VhdPath.StartsWith($artifacts, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing image path outside tools/tests/artifacts: $VhdPath" }
$payload = Join-Path $root 'installer\internal\payload\assets\payload.zip'
foreach ($required in @($IsoPath, $payload)) { if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing: $required" } }
if ($UnattendPath -and -not (Test-Path -LiteralPath $UnattendPath -PathType Leaf)) { throw "Missing: $UnattendPath" }

$EspType = '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
$BasicDataType = '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'
New-Item -ItemType Directory -Force -Path (Split-Path $VhdPath) | Out-Null
if (Test-Path -LiteralPath $VhdPath) { Remove-Item -LiteralPath $VhdPath -Force }
$mountRoot = "$VhdPath.mount"
if (Test-Path -LiteralPath $mountRoot) { Remove-Item -LiteralPath $mountRoot -Recurse -Force }

# A fixed VHD (raw disk + footer): tools/boot_ui_screens.py --name-gpt edits
# both GPT copies in place (Windows cannot set GPT partition names).
$qemuImg = Join-Path $root 'tools\qemu\qemu-img.exe'
& $qemuImg create -f vpc -o subformat=fixed $VhdPath "$($SizeGB)G" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "qemu-img VHD create failed: $LASTEXITCODE" }
& fsutil.exe sparse setflag $VhdPath 0 | Out-Null
$bindings = @()
$mounted = $false
try {
    Mount-DiskImage -ImagePath $VhdPath -StorageType VHD -NoDriveLetter | Out-Null
    $mounted = $true
    Start-Sleep -Milliseconds 500
    $disk = Get-DiskImage -ImagePath $VhdPath | Get-Disk
    if ($disk.PartitionStyle -ne 'RAW') { throw "new VHD is not RAW: $($disk.PartitionStyle)" }
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
    $disk = Get-Disk -Number $disk.Number
    $esp = New-Partition -DiskNumber $disk.Number -Size 1GB -GptType $EspType
    $data = New-Partition -DiskNumber $disk.Number -Size (([uint64]$SizeGB - 3) * 1GB) -GptType $BasicDataType
    $work = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType $BasicDataType
    Set-Partition -InputObject $data -NoDefaultDriveLetter $false -Confirm:$false
    Set-Partition -InputObject $work -NoDefaultDriveLetter $false -Confirm:$false
    $esp | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'USOS_ESP' -Confirm:$false -Force | Out-Null
    $data | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'USOS_DATA' -Confirm:$false -Force | Out-Null
    $work | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'USOS_WORK' -Confirm:$false -Force | Out-Null
    $esp = Get-Partition -DiskNumber $disk.Number -PartitionNumber $esp.PartitionNumber
    $data = Get-Partition -DiskNumber $disk.Number -PartitionNumber $data.PartitionNumber
    $work = Get-Partition -DiskNumber $disk.Number -PartitionNumber $work.PartitionNumber
    $espRoot = Join-Path $mountRoot 'esp'; $dataRoot = Join-Path $mountRoot 'data'; $workRoot = Join-Path $mountRoot 'work'
    New-Item -ItemType Directory -Force -Path $espRoot, $dataRoot, $workRoot | Out-Null
    foreach ($b in @(@{P = $esp; D = $espRoot }, @{P = $data; D = $dataRoot }, @{P = $work; D = $workRoot })) {
        Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $b.P.PartitionNumber -AccessPath $b.D
        $bindings += $b
    }
    $g = { param($x) "$($x.Guid)".Trim('{}') }
    $diskGuid = "$($disk.Guid)".Trim('{}'); $espGuid = & $g $esp; $dataGuid = & $g $data; $workGuid = & $g $work
    $nonce = [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText((Join-Path $workRoot '.usos-work'), "nonce=$nonce`r`n")

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($payload)
    try {
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName.EndsWith('/')) { continue }
            $target = Join-Path $espRoot ($entry.FullName -replace '/', '\')
            New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally { $zip.Dispose() }
    $lang = Join-Path $mountRoot 'lang'
    Push-Location (Join-Path $root 'installer')
    try { & go run ./cmd/usos-i18n-gen -export $Language -out $lang | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'language export failed' } } finally { Pop-Location }
    & robocopy.exe $lang $espRoot /E /R:0 /W:0 /NP /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy of language files failed: $LASTEXITCODE" }
    New-Item -ItemType Directory -Force -Path (Join-Path $espRoot 'loader\entries') | Out-Null
    [IO.File]::WriteAllText((Join-Path $espRoot 'loader\loader.conf'), "default usos-micro-linux.conf`r`ntimeout 0`r`neditor no`r`n")
    [IO.File]::WriteAllText((Join-Path $espRoot 'loader\entries\usos-micro-linux.conf'), "title USOS micro-Linux preparation`r`nlinux /EFI/USOS/micro-linux/vmlinuz-virt`r`ninitrd /EFI/USOS/micro-linux/initramfs-usos`r`noptions console=tty0 console=ttyS0,115200 quiet loglevel=3 vt.global_cursor_default=0 rdinit=/usos-init usos.esp_partuuid=$espGuid`r`n")
    $device = @('[device]', "nonce=$nonce", "disk_ptuuid=$diskGuid", "esp_partuuid=$espGuid", "data_partuuid=$dataGuid", "work_partuuid=$workGuid", 'work_label=USOS_WORK', 'data_label=USOS_DATA') -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $espRoot 'EFI\USOS\usos-device.ini'), $device + "`r`n")
    [IO.File]::WriteAllText((Join-Path $espRoot 'EFI\USOS\install-state.ini'), "phase=pending`r`n")

    $images = Join-Path $dataRoot "Systems\Windows\$System\Images"
    $answers = Join-Path $dataRoot "Systems\Windows\$System\Unattended"
    New-Item -ItemType Directory -Force -Path $images, $answers, (Join-Path $dataRoot 'Programs\USOS\WinPE') | Out-Null
    $isoTarget = Join-Path $images (Split-Path -Leaf $IsoPath)
    Copy-Item -LiteralPath $IsoPath -Destination $isoTarget -Force
    if ((Get-Item -LiteralPath $isoTarget).Length -ne (Get-Item -LiteralPath $IsoPath).Length) { throw 'ISO copy size mismatch' }
    if ($UnattendPath) { Copy-Item -LiteralPath $UnattendPath -Destination (Join-Path $answers (Split-Path -Leaf $UnattendPath)) -Force }
    if ($DonorPath) {
        $donorName = Split-Path -Leaf $DonorPath
        $donorTarget = Join-Path $dataRoot "Programs\USOS\WinPE\$donorName"
        Copy-Item -LiteralPath $DonorPath -Destination $donorTarget -Force
        $donorHash = (Get-FileHash -LiteralPath $donorTarget -Algorithm SHA256).Hash.ToLowerInvariant()
        $donorSize = (Get-Item -LiteralPath $donorTarget).Length
        [IO.File]::WriteAllText((Join-Path $espRoot 'EFI\USOS\winpe-donor.ini'), "; USOS-managed PE10 donor (test stick)`r`nname=$donorName`r`nsize=$donorSize`r`nsha256=$donorHash`r`n")
    }
    if ($DataDriversPath) {
        & robocopy.exe $DataDriversPath (Join-Path $dataRoot 'Drivers') /E /R:0 /W:0 /NP /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy of DATA drivers failed: $LASTEXITCODE" }
    }
    Write-Host "[PASS] native stick disk=$diskGuid esp=$espGuid data=$dataGuid work=$workGuid iso=$isoTarget"
} finally {
    foreach ($b in $bindings) { Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $b.P.PartitionNumber -AccessPath $b.D -Confirm:$false -ErrorAction SilentlyContinue }
    if ($mounted) { Dismount-DiskImage -ImagePath $VhdPath -ErrorAction SilentlyContinue | Out-Null }
    if (Test-Path -LiteralPath $mountRoot) { Remove-Item -LiteralPath $mountRoot -Recurse -Force }
}
& python.exe (Join-Path $root 'tools\boot_ui_screens.py') --name-gpt --disk $VhdPath
if ($LASTEXITCODE -ne 0) { throw 'setting GPT partition names failed' }
Write-Host "[PASS] GPT names set: $VhdPath"
