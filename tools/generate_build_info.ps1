param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$outDir = Join-Path $ProjectRoot 'build\generated'
$infoPath = Join-Path $outDir 'build-info.ini'
$envPath = Join-Path $outDir 'build-env.cmd'

function Relative-Path([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($ProjectRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Build fingerprint input outside project root: $full"
    }
    return $full.Substring($ProjectRoot.Length + 1).Replace('\', '/')
}

function Add-FilesFromDirectory([System.Collections.Generic.List[IO.FileInfo]]$List, [string]$Path, [string[]]$Extensions = @()) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $Path -Recurse -File -Force) {
        if ($Extensions.Count -gt 0 -and $Extensions -notcontains $file.Extension.ToLowerInvariant()) { continue }
        $List.Add($file)
    }
}

$files = [System.Collections.Generic.List[IO.FileInfo]]::new()
foreach ($required in @('build.zig', 'build.bat', 'installer\go.mod', 'installer\go.sum', 'installer\internal\payload\assets\README.md')) {
    $path = Join-Path $ProjectRoot $required
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing build fingerprint input: $path" }
    $files.Add((Get-Item -LiteralPath $path))
}

Add-FilesFromDirectory $files (Join-Path $ProjectRoot 'src')
Add-FilesFromDirectory $files (Join-Path $ProjectRoot 'media\UI')
Add-FilesFromDirectory $files (Join-Path $ProjectRoot 'installer\cmd') @('.go')
Add-FilesFromDirectory $files (Join-Path $ProjectRoot 'installer\internal') @('.go')

foreach ($relative in @(
    'tools\build_legacy_bios.ps1',
    'tools\generate_legacy_boot_payload.ps1',
    'tools\pack_legacy_core_slot.py',
    'tools\tests\legacy_bios\test_production_core_guard.ps1',
    'tools\build_micro_linux.py',
    'tools\build_windows_native_support.py',
    'tools\build_dos_native_support.py',
    'tools\build_freedos_support.py',
    'tools\build_dos_reboot.py',
    'tools\generate_legacy_icons.py',
    'tools\legacy_rgba_rle.py',
    'tools\vendor\himemx\3.40\manifest.json',
    'tools\vendor\syslinux\6.03\manifest.json',
    'tools\vendor\patcher9x\0.9.91\manifest.json',
    'tools\vendor\patcher9x\0.9.91\NOTICE.TXT',
    'tools\build_windows_native_cache.py',
    'tools\build_windows_source_mount.py',
    'tools\windows_setup_logging.c',
    'tools\windows_setup_launcher.c',
    'tools\windows_source_mount.c',
    'tools\build_windows7_sha2.py',
    'tools\build_windows7_kmdf.py',
    'tools\windows7_kmdf_repair.c',
    'tools\vendor\windows7-kmdf\manifest.json',
    'tools\windows7_nvme_unattend.c',
    'tools\build_windows7_uefi.py',
    'tools\windows7_uefi_finalize.c',
    'tools\windows7_uefi_wrapper.zig',
    'tools\windows7_uefi_memory_probe.zig',
    'tools\windows7_amd_shadow.zig',
    'tools\windows7_uefi_trace.zig',
    'tools\windows7_uefi_startup.cmd',
    'tools\windows7_native_startup.cmd',
    'tools\windows7_modern_startup.cmd',
    'tools\windows7_uefi_video_check.zig',
    'tools\windows_driver_archive.c',
    'tools\windows_unattend_drivers.c',
    'tools\windows_unattend_xml.h',
    'tools\windows_usb_report.c',
    'tools\prepare_windows7_uefi.sh',
    'tools\windows_wim_version.awk',
    'tools\vendor\uefiseven\1.30\manifest.json',
    'tools\windows_source_mount.c',
    'tools\windows_setup_launcher.c',
    'tools\windows_iso_startup.cmd',
    'tools\micro_linux.lock.json',
    'tools\micro_linux_init.sh',
    'tools\hardware_inventory.sh',
    'tools\hardware_smart.sh',
    'tools\hardware_smart_table.awk',
    'tools\hardware_ui.sh',
    'tools\micro_linux_ui.sh',
    'tools\partuuid.sh',
    'tools\partuuid_diagnostics.sh',
    'tools\device_guard.sh',
    'tools\target_disk_identity.sh',
    'tools\target_disk_guard.sh',
    'tools\extract.sh',
    'tools\prepare_work.sh',
    'tools\probe_xp_source.sh',
    'tools\probe_nt5_source.sh',
    'tools\prepare_nt5_media_markers.sh',
    'tools\nt5_profile.sh',
    'tools\prepare_xp_local_source.sh',
    'tools\prepare_xp_target.sh',
    'tools\legacy_xp_staging.sh',
    'tools\legacy_xp_resume.sh',
    'tools\xp_unattended_policy.sh',
    'tools\xp_windows_partition_plan.awk',
    'tools\xp_selected_partition.sif',
    'tools\xp_disk_reset.sh',
    'tools\xp_disk_reset_ui.sh',
    'tools\xp_confirmation_ui.sh',
    'tools\xp_menu_ui.sh',
    'tools\prepare_xp_source_aliases.sh',
    'tools\xp_dosnet_aliases.awk',
    'tools\xp_detect_system.sh',
    'tools\xp_disk_overview.sh',
    'tools\prepare_xp_windows_partition.sh',
    'tools\prepare_wimboot.sh',
    'tools\prepare_vhdboot.sh',
    'tools\fetch_ntfs_driver.ps1',
    'tools\build_xp_bootstrap.ps1',
    'tools\build_xp_geometry_fix_mbr.ps1',
    'tools\verify_release_consistency.ps1',
    'tools\generate_build_info.ps1'
)) {
    $path = Join-Path $ProjectRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing build fingerprint input: $path" }
    $files.Add((Get-Item -LiteralPath $path))
}

$unique = @{}
foreach ($file in $files) {
    $relative = Relative-Path $file.FullName
    if ($relative -ieq 'installer/internal/payload/assets/payload.zip') { continue }
    if ($relative -like 'build/generated/*') { continue }
    $unique[$relative] = $file.FullName
}

$records = [System.Collections.Generic.List[string]]::new()
foreach ($relative in ($unique.Keys | Sort-Object)) {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $unique[$relative]).Hash.ToLowerInvariant()
    $records.Add("$relative|$hash")
}
if ($records.Count -eq 0) { throw 'Build fingerprint input set is empty.' }

$joined = [string]::Join("`n", $records)
$bytes = [Text.Encoding]::UTF8.GetBytes($joined)
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $fingerprintBytes = $sha.ComputeHash($bytes)
} finally {
    $sha.Dispose()
}
$fingerprint = ([BitConverter]::ToString($fingerprintBytes)).Replace('-', '').ToLowerInvariant()
$now = [DateTime]::UtcNow
$epoch = [DateTimeOffset]::new($now).ToUnixTimeSeconds()
$buildId = ('B{0}-{1}' -f $now.ToString('yyMMdd-HHmmss'), $fingerprint.Substring(0, 8).ToUpperInvariant())

New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$info = @(
    '[build]',
    "id=$buildId",
    "epoch=$epoch",
    "source_sha256=$fingerprint"
) -join "`r`n"
[IO.File]::WriteAllText($infoPath, $info + "`r`n", $utf8NoBom)

$cmd = @(
    '@echo off',
    ('set "USOS_BUILD_ID={0}"' -f $buildId),
    ('set "USOS_BUILD_EPOCH={0}"' -f $epoch),
    ('set "USOS_BUILD_SOURCE_SHA256={0}"' -f $fingerprint)
) -join "`r`n"
[IO.File]::WriteAllText($envPath, $cmd + "`r`n", [Text.Encoding]::ASCII)

Write-Host "[PASS] build id=$buildId epoch=$epoch source_sha256=$fingerprint"
Write-Host "[PASS] build info: $infoPath"
Write-Host "[PASS] build env:  $envPath"
