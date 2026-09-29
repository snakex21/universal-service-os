# QEMU/OVMF check that the menu theme survives the UEFI -> micro-Linux
# handover (usos.theme=, src/gui/theme_cmdline.zig): for each theme the UEFI
# XP preparation page (step 1/5) and the usos-fb-ui screens that follow
# (Windows XP, manual installation, blank target disk) are screenshotted and
# their background compared with the theme's.
#
#   powershell -File tools/tests/run_fb_theme_qemu.ps1 [-Themes retro,usos-sunset]
#
# Needs an elevated shell (it mounts a file-backed VHD), a finished build
# (zig-out/manual-usb/EFI/BOOT/BOOTX64.EFI, zig-out/micro-linux) and the
# boot-ui test disk from tools/render_boot_ui_screenshots.ps1 (-BaseDisk).
# The disk is COPIED; files are added to the copy (nothing is formatted) and
# QEMU runs it with -snapshot, next to a blank qcow2 target. It never
# touches a physical disk.
param(
    [string[]]$Themes = @('retro', 'usos-sunset'),
    [string]$BaseDisk = 'tools/tests/artifacts/qemu/boot-ui/boot-ui.vhd',
    [string]$OutputDirectory = 'tools/tests/artifacts/fb-theme'
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
function Full([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $root $Path))
}

$base = Full $BaseDisk
$work = Full 'tools/tests/artifacts/qemu/fb-theme'
$vhd = Join-Path $work 'fb-theme.vhd'
$target = Join-Path $work 'target.qcow2'
$mountRoot = Join-Path $work 'mount'
$out = Full $OutputDirectory
$python = (Get-Command python.exe -ErrorAction Stop).Source
$efi = Full 'zig-out/manual-usb/EFI/BOOT/BOOTX64.EFI'
$kernel = Full 'zig-out/micro-linux/vmlinuz-virt'
$initramfs = Full 'zig-out/micro-linux/initramfs-usos'
$EspType = '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
$BasicDataType = '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'

foreach ($required in @($base, $efi, $kernel, $initramfs)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing $required" }
}
New-Item -ItemType Directory -Force -Path $work, $out | Out-Null
if (-not (Test-Path -LiteralPath $target)) {
    & (Full 'tools/qemu/qemu-img.exe') create -f qcow2 $target 8G | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'qemu-img create failed' }
}

$export = Join-Path $work 'lang-en'
Push-Location (Full 'installer')
try {
    & go run ./cmd/usos-i18n-gen -export en -out $export | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'language export failed' }
} finally {
    Pop-Location
}

# Theme background colours (src/gui/theme_presets.zig, src/gui/themes).
function Background([string]$Theme) {
    $builtin = @{ 'default' = '080d14'; 'dark' = '0a0a0a'; 'light' = 'eef1f5'; 'high-contrast' = '000000'; 'retro' = '0000aa' }
    if ($builtin.ContainsKey($Theme)) { return $builtin[$Theme] }
    $file = Full "src/gui/themes/$Theme.ini"
    $line = Select-String -LiteralPath $file -Pattern '^\s*background\s*=\s*#([0-9a-fA-F]{6})' | Select-Object -First 1
    if ($null -eq $line) { throw "No background in $file" }
    return $line.Matches[0].Groups[1].Value
}

$failed = @()
foreach ($theme in $Themes) {
    if (Test-Path -LiteralPath $mountRoot) { Remove-Item -LiteralPath $mountRoot -Recurse -Force }
    Copy-Item -LiteralPath $base -Destination $vhd -Force
    Mount-DiskImage -ImagePath $vhd -StorageType VHD -NoDriveLetter | Out-Null
    Start-Sleep -Milliseconds 500
    $disk = Get-DiskImage -ImagePath $vhd | Get-Disk
    if ($null -eq $disk -or $disk.Location -notlike "*fb-theme.vhd") { Dismount-DiskImage -ImagePath $vhd | Out-Null; throw 'Test VHD did not expose its disk' }
    $mounted = @()
    try {
        $parts = @(Get-Partition -DiskNumber $disk.Number | Where-Object { $_.GptType -eq $EspType -or $_.GptType -eq $BasicDataType } | Sort-Object Offset)
        if ($parts.Count -lt 2) { throw 'Test VHD has no ESP + DATA' }
        $paths = @{}
        foreach ($pair in @(@('esp', 0), @('data', 1))) {
            $path = Join-Path $mountRoot $pair[0]
            New-Item -ItemType Directory -Force -Path $path | Out-Null
            Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $parts[$pair[1]].PartitionNumber -AccessPath $path
            $mounted += , @($parts[$pair[1]].PartitionNumber, $path)
            $paths[$pair[0]] = $path
        }
        $esp = $paths['esp']; $data = $paths['data']
        Copy-Item -LiteralPath $efi -Destination (Join-Path $esp 'EFI\BOOT\BOOTX64.EFI') -Force
        foreach ($name in @('lang.bin', 'lang.cpio', 'lang-xp.ini')) {
            Copy-Item -LiteralPath (Join-Path $export "EFI\USOS\$name") -Destination (Join-Path $esp "EFI\USOS\$name") -Force
        }
        $settings = (Get-Content -LiteralPath (Join-Path $export 'EFI\USOS\usos-settings.ini') -Raw) -replace '(?m)^theme=.*\r?\n', ''
        [IO.File]::WriteAllText((Join-Path $esp 'EFI\USOS\usos-settings.ini'), $settings.TrimEnd() + "`r`ntheme=$theme`r`n")
        $themes = Join-Path $esp 'EFI\USOS\themes'
        New-Item -ItemType Directory -Force -Path $themes | Out-Null
        if (Test-Path -LiteralPath (Full "src/gui/themes/$theme.ini")) {
            Copy-Item -LiteralPath (Full "src/gui/themes/$theme.ini") -Destination (Join-Path $themes "$theme.ini") -Force
        }
        # The production micro-Linux as the XP package (its first screens and
        # the target disk menu are the same usos-fb-ui).
        $xpDir = Join-Path $esp 'EFI\USOS-XP'
        New-Item -ItemType Directory -Force -Path $xpDir | Out-Null
        Copy-Item -LiteralPath $kernel -Destination (Join-Path $xpDir 'vmlinuz.efi') -Force
        Copy-Item -LiteralPath $initramfs -Destination (Join-Path $xpDir 'initramfs-xp') -Force
        $partuuid = $parts[0].Guid.Trim('{}').ToLowerInvariant()
        $datauuid = $parts[1].Guid.Trim('{}').ToLowerInvariant()
        [IO.File]::WriteAllText((Join-Path $esp 'EFI\USOS\usos-device.ini'), "esp_partuuid=$partuuid`r`ndata_partuuid=$datauuid`r`n")
        $xp = Join-Path $data 'Systems\Windows\Windows XP'
        New-Item -ItemType Directory -Force -Path (Join-Path $xp 'Images') | Out-Null
        if (-not (Test-Path -LiteralPath (Join-Path $xp 'Images\WinXP_SP3_PL.iso'))) {
            [IO.File]::WriteAllBytes((Join-Path $xp 'Images\WinXP_SP3_PL.iso'), (New-Object byte[] 65536))
        }
        Write-Host "[TEST] fb-theme disk ready for $theme (esp_partuuid=$partuuid)"
    } finally {
        foreach ($item in $mounted) {
            Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $item[0] -AccessPath $item[1] -Confirm:$false -ErrorAction SilentlyContinue
        }
        Dismount-DiskImage -ImagePath $vhd -ErrorAction SilentlyContinue | Out-Null
        if (Test-Path -LiteralPath $mountRoot) { Remove-Item -LiteralPath $mountRoot -Recurse -Force }
    }
    & $python (Full 'tools/fb_theme_qemu.py') --disk $vhd --target $target --theme $theme --background (Background $theme) --out $out
    if ($LASTEXITCODE -ne 0) { $failed += $theme }
}
if ($failed.Count -ne 0) { throw "Theme handover failed for: $($failed -join ', ')" }
Write-Host "[PASS] menu theme kept by micro-Linux: $out"
