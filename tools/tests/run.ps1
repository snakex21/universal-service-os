param(
    [ValidateSet('all', 'unit', 'selftest', 'x86_64', 'aarch64')]
    [string]$Suite = 'all'
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$zig = Join-Path $root 'tools\zig\zig.exe'
$zigCache = Join-Path $root 'tools\cache\zig'
$qemuLocal = Join-Path $root 'tools\qemu'
$qemuArtifacts = Join-Path $root 'tools\tests\artifacts\qemu'

function Require-File([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label not found: $Path"
    }
}

function Run-Zig([string[]]$Arguments) {
    Require-File $zig 'Zig'
    & $zig @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Zig failed with exit code ${LASTEXITCODE}: $($Arguments -join ' ')"
    }
}

function Run-Unit {
    Write-Host '[TEST] Unit tests' -ForegroundColor Cyan
    Run-Zig @('build', '--cache-dir', $zigCache, 'test')
    Run-Zig @('test', 'src/platform/bios/memtest_image.zig', '--cache-dir', $zigCache)
    Run-Zig @('test', 'src/platform/bios/dos_fat.zig', '--cache-dir', $zigCache)
    Run-Zig @('test', '--dep', 'graphics', '-Mroot=src/platform/bios/linux_boot_params.zig', '-Mgraphics=src/legacy_graphics_module.zig', '--cache-dir', $zigCache)
    # M0 golden fingerprints (docs/design/refactor-os-pipeline.md): staged
    # micro-Linux/XP/WinPE payloads and WINNT.SIF of the last build.
    & python.exe (Join-Path $root 'tools/tests/golden/staged_payloads.py')
    if ($LASTEXITCODE -ne 0) { throw 'Staged payload goldens differ (see tools/tests/artifacts/golden).' }
    & python.exe (Join-Path $root 'tools/tests/legacy_bios/test_hardware_smart.py')
    if ($LASTEXITCODE -ne 0) { throw 'Hardware SMART tests failed.' }
    & python.exe (Join-Path $root 'tools/tests/legacy_bios/test_legacy_rgba_rle.py')
    if ($LASTEXITCODE -ne 0) { throw 'Legacy icon compression tests failed.' }
    & python.exe (Join-Path $root 'tools/tests/legacy_bios/test_windows3_media.py')
    if ($LASTEXITCODE -ne 0) { throw 'Windows 3.x media conversion tests failed.' }
    & python.exe (Join-Path $root 'tools/tests/legacy_bios/test_xp_dosnet_aliases.py')
    if ($LASTEXITCODE -ne 0) { throw 'XP DOSNET alias tests failed.' }
    & python.exe (Join-Path $root 'tools/tests/legacy_bios/test_nt5_source.py')
    if ($LASTEXITCODE -ne 0) { throw 'NT5 source identity tests failed.' }
    & python.exe (Join-Path $root 'tools/tests/legacy_bios/test_nt5_media_markers.py')
    if ($LASTEXITCODE -ne 0) { throw 'NT5 local media marker tests failed.' }
    & python.exe (Join-Path $root 'tools/tests/legacy_bios/test_xp_drive_letters.py')
    if ($LASTEXITCODE -ne 0) { throw 'XP drive letter tests failed.' }
    & python.exe (Join-Path $root 'tools/tests/legacy_bios/test_xp_source_io.py')
    if ($LASTEXITCODE -ne 0) { throw 'XP source I/O tests failed.' }
    & python.exe (Join-Path $root 'tools/tests/legacy_bios/test_wimboot_kexec.py')
    if ($LASTEXITCODE -ne 0) { throw 'Windows BIOS kexec entry tests failed.' }
    & python.exe (Join-Path $root 'tools/tests/legacy_bios/test_ordered_wimboot_kexec.py')
    if ($LASTEXITCODE -ne 0) { throw 'Windows BIOS ordered kexec entry tests failed.' }
    & python.exe (Join-Path $root 'tools/tests/legacy_bios/test_windows_bios_cpu_check.py')
    if ($LASTEXITCODE -ne 0) { throw 'Windows BIOS CPU compatibility tests failed.' }
    & python.exe (Join-Path $root 'tools/tests/legacy_bios/test_windows_disk_order.py')
    if ($LASTEXITCODE -ne 0) { throw 'Windows BIOS disk-order tests failed' }
    & python.exe (Join-Path $root 'tools/tests/legacy_bios/test_dos_disk_filter.py')
    if ($LASTEXITCODE -ne 0) { throw 'DOS disk isolation and target MBR tests failed.' }
    & python.exe (Join-Path $root 'tools/tests/legacy_bios/test_dos_reboot.py')
    if ($LASTEXITCODE -ne 0) { throw 'DOS restart helper tests failed.' }
    & python.exe (Join-Path $root 'tools/tests/test_windows_source_mount.py')
    if ($LASTEXITCODE -ne 0) { throw 'Windows PE source mapping tests failed.' }
    & python.exe (Join-Path $root 'tools/tests/test_windows_driver_support.py')
    if ($LASTEXITCODE -ne 0) { throw 'Windows driver transport and answer-file tests failed.' }
    & python.exe (Join-Path $root 'tools/tests/test_windows7_nvme.py')
    if ($LASTEXITCODE -ne 0) { throw 'Windows 7 NVMe helper tests failed.' }
    & python.exe (Join-Path $root 'tools/tests/test_windows7_uefi_publish.py')
    if ($LASTEXITCODE -ne 0) { throw 'Windows 7 EFI publication tests failed.' }
    & python.exe (Join-Path $root 'tools/tests/test_uefi_graphics_refresh.py')
    if ($LASTEXITCODE -ne 0) { throw 'UEFI graphics mode-change regression failed.' }
    & python.exe (Join-Path $root 'tools/tests/test_uefi_graphics_connect.py')
    if ($LASTEXITCODE -ne 0) { throw 'UEFI graphics controller reconnect regression failed.' }
    & python.exe (Join-Path $root 'tools/tests/test_xp_reproducible.py')
    if ($LASTEXITCODE -ne 0) { throw 'XP cabinet/hive reproducibility tests failed.' }
}

function Run-Selftest {
    Write-Host '[TEST] Startup selftest' -ForegroundColor Cyan
    Run-Zig @('build', '--cache-dir', $zigCache, 'selftest')
}

function Resolve-QemuX64 {
    $local = Join-Path $qemuLocal 'qemu-system-x86_64.exe'
    if (Test-Path -LiteralPath $local -PathType Leaf) { return $local }
    $installed = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
    if (Test-Path -LiteralPath $installed -PathType Leaf) { return $installed }
    throw 'QEMU x86_64 not found.'
}

function Run-X64 {
    Write-Host '[TEST] UEFI x86_64 in QEMU' -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $qemuArtifacts | Out-Null
    $serialLog = Join-Path $qemuArtifacts 'qemu-selftest-x86_64-serial.log'
    Remove-Item -LiteralPath $serialLog -Force -ErrorAction SilentlyContinue
    Run-Zig @('build', '--cache-dir', $zigCache, 'qemu-x86_64-image', '-Doptimize=ReleaseFast')

    $qemu = Resolve-QemuX64
    $qemuDir = Split-Path -Parent $qemu
    $firmwareCode = Join-Path $qemuDir 'share\edk2-x86_64-code.fd'
    $firmwareVars = Join-Path $qemuDir 'share\edk2-i386-vars.fd'
    Require-File $firmwareCode 'x86_64 UEFI firmware code'
    Require-File $firmwareVars 'x86_64 UEFI firmware vars'

    & $qemu `
        -machine q35 `
        -m 64M `
        -drive "if=pflash,format=raw,readonly=on,file=$firmwareCode" `
        -drive "if=pflash,format=raw,file=$firmwareVars,snapshot=on" `
        -drive "file=fat:rw:$root\zig-out\qemu-usb,format=raw,if=ide" `
        -boot order=c `
        -net none `
        -display none `
        -monitor none `
        -serial "file:$($serialLog.Replace('\','/'))" `
        -no-reboot `
        -device isa-debug-exit,iobase=0xf4,iosize=0x04

    $code = $LASTEXITCODE
    if ($code -eq 33) {
        Write-Host '[PASS] x86_64 QEMU boot self-test' -ForegroundColor Green
        return
    }
    if ($code -eq 35) { throw 'x86_64 QEMU boot self-test reported FAIL.' }
    throw "x86_64 QEMU ended with unexpected exit code $code"
}

function Run-Aarch64 {
    Write-Host '[TEST] UEFI ARM64 in QEMU' -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $qemuArtifacts | Out-Null
    $serialLog = Join-Path $qemuArtifacts 'qemu-selftest-aarch64-serial.log'
    Remove-Item -LiteralPath $serialLog -Force -ErrorAction SilentlyContinue
    Run-Zig @('build', '--cache-dir', $zigCache, 'qemu-aarch64-image', '-Doptimize=ReleaseFast')

    $qemu = Join-Path $qemuLocal 'qemu-system-aarch64.exe'
    $firmwareCode = Join-Path $qemuLocal 'share\edk2-aarch64-code.fd'
    $firmwareVars = Join-Path $qemuLocal 'share\edk2-arm-vars.fd'
    Require-File $qemu 'QEMU ARM64'
    Require-File $firmwareCode 'ARM64 UEFI firmware code'
    Require-File $firmwareVars 'ARM64 UEFI firmware vars'

    & $qemu `
        -machine virt `
        -cpu cortex-a57 `
        -m 128M `
        -drive "if=pflash,format=raw,readonly=on,file=$firmwareCode" `
        -drive "if=pflash,format=raw,file=$firmwareVars,snapshot=on" `
        -drive "file=fat:rw:$root\zig-out\qemu-arm64-usb,format=raw,if=none,id=bootdisk" `
        -device virtio-blk-pci,drive=bootdisk `
        -net none `
        -display none `
        -monitor none `
        -serial "file:$($serialLog.Replace('\','/'))" `
        -no-reboot

    if ($LASTEXITCODE -ne 0) {
        throw "ARM64 QEMU boot self-test failed with exit code $LASTEXITCODE"
    }
    Write-Host '[PASS] ARM64 QEMU boot self-test' -ForegroundColor Green
}

switch ($Suite) {
    'unit' { Run-Unit }
    'selftest' { Run-Selftest }
    'x86_64' { Run-X64 }
    'aarch64' { Run-Aarch64 }
    'all' {
        Run-Unit
        Run-Selftest
        Run-X64
        Run-Aarch64
        Write-Host '[PASS] All automated tests passed.' -ForegroundColor Green
    }
}
