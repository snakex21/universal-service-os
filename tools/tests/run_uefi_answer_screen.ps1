# QEMU/OVMF click-through of the XP answer-file screen (UEFI menu; since
# 2026-09-26 the answer-profile manager, docs/answer-profiles.md): rows with
# an active usos-xp.ini and one .sif, Back by Esc, Backspace (handheld B),
# right click and a click on the footer Esc hint (the touch tap hit test),
# the summary for each row and the kernel command line handed to the XP
# micro-Linux; a USOS profile added with the keyboard, used
# (usos.xp_settings=plan), edited (F2 = pad X), left with Esc, deleted
# (Delete = pad Y, confirmed); Windows 10's manager; and the theme editor
# (Tools -> Theme: contrast failure blocks Save, a valid theme is saved on
# the ESP and used).
#
#   powershell -File tools/tests/run_uefi_answer_screen.ps1 [-Update]
#
# Needs an elevated shell (it mounts a file-backed VHD), a finished build
# (zig-out/manual-usb/EFI/BOOT/BOOTX64.EFI) and the boot-ui test disk from
# tools/render_boot_ui_screenshots.ps1. The disk is COPIED to
# tools/tests/artifacts/qemu/answer-screen/answer-screen.vhd; files are
# added to the copy (nothing is formatted) and QEMU runs it with -snapshot.
# It never touches a physical disk.
#
# Golden: tools/tests/golden/uefi_answer_screen.tsv (-Update rewrites it).
param(
    [string]$Language = 'en',
    [string]$OutputDirectory = 'tools/tests/artifacts/answer-screen',
    [switch]$Update
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
function Full([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $root $Path))
}

$base = Full 'tools/tests/artifacts/qemu/boot-ui/boot-ui.vhd'
$work = Full 'tools/tests/artifacts/qemu/answer-screen'
$vhd = Join-Path $work 'answer-screen.vhd'
$mountRoot = Join-Path $work 'mount'
$out = Full $OutputDirectory
$python = (Get-Command python.exe -ErrorAction Stop).Source
$efi = Full 'zig-out/manual-usb/EFI/BOOT/BOOTX64.EFI'
$EspType = '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
$BasicDataType = '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'

if (-not (Test-Path -LiteralPath $base)) { throw "Missing $base; run tools/render_boot_ui_screenshots.ps1 once first" }
if (-not (Test-Path -LiteralPath $efi)) { throw "Missing build output: $efi" }
New-Item -ItemType Directory -Force -Path $work, $out | Out-Null
if (Test-Path -LiteralPath $mountRoot) { Remove-Item -LiteralPath $mountRoot -Recurse -Force }
Copy-Item -LiteralPath $base -Destination $vhd -Force

$export = Join-Path $work "lang-$Language"
Push-Location (Full 'installer')
try {
    & go run ./cmd/usos-i18n-gen -export $Language -out $export | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "language export failed for $Language" }
} finally {
    Pop-Location
}

Mount-DiskImage -ImagePath $vhd -StorageType VHD -NoDriveLetter | Out-Null
Start-Sleep -Milliseconds 500
$disk = Get-DiskImage -ImagePath $vhd | Get-Disk
if ($null -eq $disk -or $disk.Location -notlike "*answer-screen.vhd") { Dismount-DiskImage -ImagePath $vhd | Out-Null; throw 'Test VHD did not expose its disk' }
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
    foreach ($name in @('usos-settings.ini', 'lang.bin', 'lang.cpio', 'lang-xp.ini')) {
        Copy-Item -LiteralPath (Join-Path $export "EFI\USOS\$name") -Destination (Join-Path $esp "EFI\USOS\$name") -Force
    }
    # XP stage 1 finds its initramfs and the ESP identity; the kernel is
    # left out on purpose, so the start stops after the command line trace.
    $xpDir = Join-Path $esp 'EFI\USOS-XP'
    New-Item -ItemType Directory -Force -Path $xpDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $xpDir 'initramfs-xp'), "USOS answer-screen test placeholder`n")
    Remove-Item -LiteralPath (Join-Path $xpDir 'vmlinuz.efi') -Force -ErrorAction SilentlyContinue
    $partuuid = $parts[0].Guid.Trim('{}').ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $esp 'EFI\USOS\usos-device.ini'), "esp_partuuid=$partuuid`r`n")
    # DATA: an XP image (placeholder), an active usos-xp.ini and one .sif.
    $xp = Join-Path $data 'Systems\Windows\Windows XP'
    New-Item -ItemType Directory -Force -Path (Join-Path $xp 'Images'), (Join-Path $xp 'Unattended') | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $xp 'Images\WinXP_SP3_PL.iso'))) {
        [IO.File]::WriteAllBytes((Join-Path $xp 'Images\WinXP_SP3_PL.iso'), (New-Object byte[] 65536))
    }
    Copy-Item -LiteralPath (Full 'tools/tests/golden/xp_user_settings_test.ini') -Destination (Join-Path $xp 'Unattended\usos-xp.ini') -Force
    Copy-Item -LiteralPath (Full 'tools/tests/golden/xp_custom_test.sif') -Destination (Join-Path $xp 'Unattended\test.sif') -Force
    Write-Host "[TEST] answer-screen disk ready: $vhd (esp_partuuid=$partuuid)"
} finally {
    foreach ($item in $mounted) {
        Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $item[0] -AccessPath $item[1] -Confirm:$false -ErrorAction SilentlyContinue
    }
    Dismount-DiskImage -ImagePath $vhd -ErrorAction SilentlyContinue | Out-Null
    if (Test-Path -LiteralPath $mountRoot) { Remove-Item -LiteralPath $mountRoot -Recurse -Force }
}

$arguments = @((Full 'tools/boot_answer_screen_qemu.py'), '--disk', $vhd, '--out', $out, '--golden', (Full 'tools/tests/golden/uefi_answer_screen.tsv'))
if ($Update) { $arguments += '--update' }
& $python @arguments
if ($LASTEXITCODE -ne 0) { throw 'UEFI answer-screen click-through failed' }
Write-Host "[PASS] UEFI answer-screen click-through: $out"
