# Renders the USOS boot menu in QEMU (OVMF for UEFI, SeaBIOS for Legacy BIOS)
# in several languages and saves PNG screenshots.
#
#   powershell -File tools/render_boot_ui_screenshots.ps1 [-Languages pl,en,ru,el] [-OutputDirectory artifacts/boot-ui]
#
# Needs an elevated shell (it builds a small GPT test disk in a file-backed
# VHD under tools/tests/artifacts/qemu/boot-ui) and a finished build
# (zig-out/manual-usb/EFI/BOOT/BOOTX64.EFI, zig-out/legacy-bios/*). It never touches
# a physical disk.
param(
    [string[]]$Languages = @('pl', 'en', 'ru', 'el'),
    [string]$OutputDirectory = 'artifacts/boot-ui',
    # OVMF offers at most 1920x1080 here; 4K is covered by zig build ui-preview.
    [string[]]$ExtraUefiResolutions = @('1920x1080:pl'),
    [switch]$SkipBios,
    [switch]$SkipUefi,
    # Instead of screenshots: drive the UEFI menu with wheel, drag and tap
    # through QMP for usb-tablet, usb-mouse and the PS/2 mouse, and the
    # Legacy BIOS menu with the PS/2 wheel (tools/boot_input_qemu.py).
    [switch]$InputTest,
    [string]$InputDevices = 'ps2,mouse,tablet,bios',
    # Instead of screenshots: measure the boot splash and loading time
    # (tools/boot_splash_qemu.py) for UEFI and BIOS in the first language,
    # saving timelines and animation frames to <OutputDirectory>/splash.
    # -SplashLaunch also measures the transition into micro-Linux (the test
    # disk then carries the micro-Linux payload and its loader entry).
    [switch]$Splash,
    [switch]$SplashLaunch,
    [string]$SplashLabel = 'boot',
    # Disk requests per second for the splash runs (0 = unthrottled); ~150
    # models a slow USB 2.0 stick so the splash and spinner are visible.
    [int]$SplashThrottleIops = 0,
    # boot_logo= written to usos-settings.ini for the splash runs
    # ('firmware' keeps the ACPI BGRT logo), empty = default USOS logo.
    [string]$SplashBootLogo = '',
    # Refresh BOOTX64.EFI, bios-ui.bin, the Core slot and the micro-Linux
    # files on the existing test disk instead of building a new one.
    [switch]$ReuseDisk,
    # Legacy BIOS second-stage resources: 'missing' deletes EFI/USOS/bios-ui.bin
    # and 'corrupt' flips one payload byte (CRC mismatch), to check that the
    # Core falls back to its built-in 5x7 font and English text.
    [ValidateSet('present', 'missing', 'corrupt')][string]$BiosUiPack = 'present'
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Full([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $root $Path))
}

$testRoot = Full 'tools/tests/artifacts/qemu/boot-ui'
$vhd = Join-Path $testRoot 'boot-ui.vhd'
$mountRoot = Join-Path $testRoot 'mount'
$out = Full $OutputDirectory
$qemuImg = Full 'tools/qemu/qemu-img.exe'
$python = (Get-Command python.exe -ErrorAction Stop).Source
$driver = Full 'tools/boot_ui_screens.py'
$langDir = Join-Path $testRoot 'lang'

foreach ($required in @('zig-out/manual-usb/EFI/BOOT/BOOTX64.EFI', 'zig-out/legacy-bios/stage1.bin', 'zig-out/legacy-bios/core-slot.bin', 'zig-out/legacy-bios/bios-ui.bin', 'zig-out/test-assets/ntfs_x64.efi')) {
    if (-not (Test-Path -LiteralPath (Full $required) -PathType Leaf)) { throw "Missing build output: $required" }
}
New-Item -ItemType Directory -Force -Path $testRoot, $out, $langDir | Out-Null

$EspType = '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
$BasicDataType = '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'

function Mount-TestDisk {
    Mount-DiskImage -ImagePath $vhd -StorageType VHD -NoDriveLetter | Out-Null
    Start-Sleep -Milliseconds 500
    $disk = Get-DiskImage -ImagePath $vhd | Get-Disk
    if ($null -eq $disk) { throw 'Test VHD did not expose a disk' }
    return $disk
}

function Mount-Partitions($disk) {
    $parts = @(Get-Partition -DiskNumber $disk.Number | Where-Object { $_.GptType -eq $EspType -or $_.GptType -eq $BasicDataType } | Sort-Object Offset)
    $paths = @{}
    $names = @('esp', 'data', 'work')
    for ($i = 0; $i -lt [Math]::Min(3, $parts.Count); $i++) {
        $path = Join-Path $mountRoot $names[$i]
        New-Item -ItemType Directory -Force -Path $path | Out-Null
        Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $parts[$i].PartitionNumber -AccessPath $path
        $paths[$names[$i]] = @{ Path = $path; Partition = $parts[$i] }
    }
    return $paths
}

function Dismount-TestDisk($disk, $paths) {
    foreach ($name in @($paths.Keys)) {
        $entry = $paths[$name]
        Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $entry.Partition.PartitionNumber -AccessPath $entry.Path -Confirm:$false -ErrorAction SilentlyContinue
    }
    Dismount-DiskImage -ImagePath $vhd -ErrorAction SilentlyContinue | Out-Null
    if (Test-Path -LiteralPath $mountRoot) { Remove-Item -LiteralPath $mountRoot -Recurse -Force }
}

# The micro-Linux payload and its systemd-boot entry, laid out like the
# installer does (installer/internal/winhost/payload_windows.go), so the
# UEFI and BIOS menus can hand over to micro-Linux on the test disk.
function Copy-MicroLinux([string]$espRoot) {
    if (-not $SplashLaunch) { return }
    $source = Full 'zig-out/micro-linux'
    $target = Join-Path $espRoot 'EFI\USOS\micro-linux'
    New-Item -ItemType Directory -Force -Path $target, (Join-Path $espRoot 'loader\entries') | Out-Null
    foreach ($name in @('vmlinuz-virt', 'initramfs-usos')) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $target $name) -Force
    }
    Copy-Item -LiteralPath (Join-Path $source 'systemd-bootx64.efi') -Destination (Join-Path $espRoot 'EFI\USOS\systemd-bootx64.efi') -Force
    $partuuid = '00000000-0000-0000-0000-000000000000'
    $esp = Get-Partition -DiskNumber (Get-DiskImage -ImagePath $vhd | Get-Disk).Number | Where-Object { $_.GptType -eq $EspType } | Select-Object -First 1
    if ($esp) { $partuuid = $esp.Guid.Trim('{}').ToLowerInvariant() }
    [IO.File]::WriteAllText((Join-Path $espRoot 'loader\loader.conf'), "default usos-micro-linux.conf`r`ntimeout 0`r`neditor no`r`n")
    $options = (& $python (Full 'tools/boot_splash_qemu.py') --print-linux-options).Trim()
    $entry = "title USOS micro-Linux preparation`r`nlinux /EFI/USOS/micro-linux/vmlinuz-virt`r`ninitrd /EFI/USOS/micro-linux/initramfs-usos`r`ninitrd /EFI/USOS/lang.cpio`r`noptions $options usos.esp_partuuid=$partuuid`r`n"
    [IO.File]::WriteAllText((Join-Path $espRoot 'loader\entries\usos-micro-linux.conf'), $entry)
    [IO.File]::WriteAllText((Join-Path $espRoot 'EFI\USOS\usos-device.ini'), "esp_partuuid=$partuuid`r`n")
}

function Update-TestDisk {
    $disk = Mount-TestDisk
    $paths = @{}
    try {
        $paths = Mount-Partitions $disk
        $espRoot = $paths['esp'].Path
        Copy-Item -LiteralPath (Full 'zig-out/manual-usb/EFI/BOOT/BOOTX64.EFI') -Destination (Join-Path $espRoot 'EFI\BOOT\BOOTX64.EFI') -Force
        Copy-Item -LiteralPath (Full 'zig-out/legacy-bios/bios-ui.bin') -Destination (Join-Path $espRoot 'EFI\USOS\bios-ui.bin') -Force
        Copy-MicroLinux $espRoot
    } finally {
        Dismount-TestDisk $disk $paths
    }
    Write-BootCode
}

# Legacy BIOS boot code: Stage 1 into the MBR code area and the Core slot
# at LBA 64, exactly where the installer writes them (file-backed VHD).
function Write-BootCode {
    $stage1 = [IO.File]::ReadAllBytes((Full 'zig-out/legacy-bios/stage1.bin'))
    $core = [IO.File]::ReadAllBytes((Full 'zig-out/legacy-bios/core-slot.bin'))
    $stream = [IO.File]::Open($vhd, 'Open', 'ReadWrite')
    try {
        $stream.Position = 0
        $stream.Write($stage1, 0, 440)
        $stream.Position = 64 * 512
        $stream.Write($core, 0, $core.Length)
    } finally {
        $stream.Dispose()
    }
}

function New-TestDisk {
    if (Test-Path -LiteralPath $vhd) { Remove-Item -LiteralPath $vhd -Force }
    & $qemuImg create -f vpc -o subformat=fixed $vhd 2G | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "qemu-img create failed: $LASTEXITCODE" }
    & fsutil.exe sparse setflag $vhd 0 | Out-Null
    $disk = Mount-TestDisk
    $paths = @{}
    try {
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
        $esp = New-Partition -DiskNumber $disk.Number -Size 300MB -GptType $EspType
        $data = New-Partition -DiskNumber $disk.Number -Size 1200MB -GptType $BasicDataType
        $work = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType $BasicDataType
        Set-Partition -InputObject $data -NoDefaultDriveLetter $false -Confirm:$false
        Set-Partition -InputObject $work -NoDefaultDriveLetter $false -Confirm:$false
        $esp | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'USOS_ESP' -Confirm:$false -Force | Out-Null
        $data | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'USOS_DATA' -Confirm:$false -Force | Out-Null
        $work | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'USOS_WORK' -Confirm:$false -Force | Out-Null
        $paths = Mount-Partitions (Get-Disk -Number $disk.Number)
        $espRoot = $paths['esp'].Path
        $dataRoot = $paths['data'].Path
        Copy-Item -LiteralPath (Full 'zig-out/usb/EFI') -Destination (Join-Path $espRoot 'EFI') -Recurse -Force
        Copy-Item -LiteralPath (Full 'zig-out/usb/UI') -Destination (Join-Path $espRoot 'UI') -Recurse -Force
        Copy-Item -LiteralPath (Full 'zig-out/test-assets/ntfs_x64.efi') -Destination (Join-Path $espRoot 'EFI\USOS\ntfs_x64.efi') -Force
        Copy-Item -LiteralPath (Full 'zig-out/legacy-bios/bios-ui.bin') -Destination (Join-Path $espRoot 'EFI\USOS\bios-ui.bin') -Force
        Copy-MicroLinux $espRoot
        # A few catalog entries with small placeholder images, so the lists
        # show both ready systems and systems without images.
        $images = @(
            'Systems\Windows\Windows 11\Images\Win11_24H2_Polish_x64.iso',
            'Systems\Windows\Windows 11\Images\Win11_23H2_English_x64.iso',
            'Systems\Windows\Windows 10\Images\Win10_22H2_x64.iso',
            'Systems\Windows\Windows XP\Images\WinXP_SP3_PL.iso',
            'Systems\Linux\Ubuntu\Images\ubuntu-24.04-desktop-amd64.iso',
            'Systems\DOS\FreeDOS\Images\FD14-LiveCD.iso',
            'Utilities\MemTest86\Images\memtest86-plus.iso'
        )
        foreach ($image in $images) {
            $path = Join-Path $dataRoot $image
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
            [IO.File]::WriteAllBytes($path, (New-Object byte[] 65536))
        }
        foreach ($folder in @('Windows 7', 'Windows 8.1', 'Windows Vista', 'Windows 2000', 'Windows 98 SE')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $dataRoot "Systems\Windows\$folder\Images") | Out-Null
        }
        New-Item -ItemType Directory -Force -Path (Join-Path $dataRoot 'Systems\Windows\Windows 11\Unattended') | Out-Null
    } finally {
        Dismount-TestDisk $disk $paths
    }
    & $python $driver --name-gpt --disk $vhd
    if ($LASTEXITCODE -ne 0) { throw 'setting GPT partition names failed' }
    Write-BootCode
}

function Set-Language([string]$Language) {
    $export = Join-Path $langDir $Language
    Push-Location (Full 'installer')
    try {
        & go run ./cmd/usos-i18n-gen -export $Language -out $export | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "language export failed for $Language" }
    } finally {
        Pop-Location
    }
    $disk = Mount-TestDisk
    $paths = @{}
    try {
        $paths = Mount-Partitions $disk
        $target = Join-Path $paths['esp'].Path 'EFI\USOS'
        foreach ($name in @('usos-settings.ini', 'lang.bin', 'lang.cpio', 'lang-xp.ini')) {
            Copy-Item -LiteralPath (Join-Path $export "EFI\USOS\$name") -Destination (Join-Path $target $name) -Force
        }
        if ($Splash -and $SplashBootLogo) {
            Add-Content -LiteralPath (Join-Path $target 'usos-settings.ini') -Value "boot_logo=$SplashBootLogo" -Encoding Ascii
        }
    } finally {
        Dismount-TestDisk $disk $paths
    }
}

function Set-BiosUiPack([string]$Mode) {
    if ($Mode -eq 'present') { return }
    $disk = Mount-TestDisk
    $paths = @{}
    try {
        $paths = Mount-Partitions $disk
        $pack = Join-Path $paths['esp'].Path 'EFI\USOS\bios-ui.bin'
        if ($Mode -eq 'missing') {
            Remove-Item -LiteralPath $pack -Force
        } else {
            $bytes = [IO.File]::ReadAllBytes($pack)
            $bytes[$bytes.Length - 100] = $bytes[$bytes.Length - 100] -bxor 0x5A
            [IO.File]::WriteAllBytes($pack, $bytes)
        }
        Write-Host "[TEST] bios-ui.bin on the test ESP: $Mode"
    } finally {
        Dismount-TestDisk $disk $paths
    }
}

if ($ReuseDisk -and (Test-Path -LiteralPath $vhd)) { Update-TestDisk } else { New-TestDisk }
Set-BiosUiPack $BiosUiPack
if ($Splash) {
    Set-Language $Languages[0]
    $splashOut = Join-Path $out 'splash'
    foreach ($firmware in @('uefi', 'bios')) {
        if ($firmware -eq 'uefi' -and $SkipUefi) { continue }
        if ($firmware -eq 'bios' -and $SkipBios) { continue }
        $splashArgs = @((Full 'tools/boot_splash_qemu.py'), '--firmware', $firmware, '--disk', $vhd, '--out', $splashOut, '--label', "$SplashLabel-$($Languages[0])")
        if ($SplashLaunch) { $splashArgs += '--launch' }
        if ($SplashThrottleIops -gt 0) { $splashArgs += @('--throttle-iops', "$SplashThrottleIops") }
        & $python @splashArgs
        if ($LASTEXITCODE -ne 0) { throw "splash measurement failed for $firmware" }
    }
    Write-Host "[PASS] Boot splash measurements: $splashOut"
    return
}
if ($InputTest) {
    Set-Language $Languages[0]
    & $python (Full 'tools/boot_input_qemu.py') --disk $vhd --out $out --devices $InputDevices
    if ($LASTEXITCODE -ne 0) { throw 'UEFI input test failed' }
    Write-Host "[PASS] Boot UI input test: $out"
    return
}
foreach ($language in $Languages) {
    Set-Language $language
    if (-not $SkipUefi) {
        & $python $driver --firmware uefi --disk $vhd --language $language --out $out
        if ($LASTEXITCODE -ne 0) { throw "UEFI screenshots failed for $language" }
    }
    if (-not $SkipBios) {
        & $python $driver --firmware bios --disk $vhd --language $language --out $out
        if ($LASTEXITCODE -ne 0) { throw "BIOS screenshots failed for $language" }
    }
}
if (-not $SkipUefi) {
    # High-resolution UEFI captures (1.5x and 3x UI scale) for one language each.
    foreach ($item in $ExtraUefiResolutions) {
        $size, $language = $item.Split(':')
        $width, $height = $size.Split('x')
        Set-Language $language
        & $python $driver --firmware uefi --disk $vhd --language $language --out $out --width $width --height $height
        if ($LASTEXITCODE -ne 0) { throw "UEFI $size screenshots failed for $language" }
    }
}
Write-Host "[PASS] Boot UI screenshots: $out"
