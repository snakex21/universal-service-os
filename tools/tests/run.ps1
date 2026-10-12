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

# Failed steps of this run; every step runs, the summary lists them all.
$script:Failures = New-Object System.Collections.Generic.List[string]

function Invoke-Step([string]$Label, [scriptblock]$Body) {
    try {
        & $Body
    } catch {
        Write-Host "[FAIL] ${Label}: $($_.Exception.Message)" -ForegroundColor Red
        $script:Failures.Add("${Label}: $($_.Exception.Message)")
    }
}

function Invoke-PythonStep([string]$Script, [string]$Message) {
    & python.exe (Join-Path $root $Script)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[FAIL] ${Script}: $Message" -ForegroundColor Red
        $script:Failures.Add("${Script}: $Message")
    }
}

function Complete-Run([string]$PassMessage) {
    if ($script:Failures.Count -gt 0) {
        Write-Host "[FAIL] $($script:Failures.Count) step(s) failed:" -ForegroundColor Red
        foreach ($failure in $script:Failures) { Write-Host "  - $failure" -ForegroundColor Red }
        exit 1
    }
    Write-Host "[PASS] $PassMessage" -ForegroundColor Green
}

function Run-Unit {
    Write-Host '[TEST] Unit tests' -ForegroundColor Cyan
    Invoke-Step 'zig build test' { Run-Zig @('build', '--cache-dir', $zigCache, 'test') }
    Invoke-Step 'zig test memtest_image.zig' { Run-Zig @('test', 'src/platform/bios/memtest_image.zig', '--cache-dir', $zigCache) }
    Invoke-Step 'zig test dos_fat.zig' { Run-Zig @('test', 'src/platform/bios/dos_fat.zig', '--cache-dir', $zigCache) }
    Invoke-Step 'zig test linux_boot_params.zig' { Run-Zig @('test', '--dep', 'graphics', '-Mroot=src/platform/bios/linux_boot_params.zig', '-Mgraphics=src/legacy_graphics_module.zig', '--cache-dir', $zigCache) }
    # M0 golden fingerprints (docs/design/refactor-os-pipeline.md): staged
    # micro-Linux/XP/WinPE payloads and WINNT.SIF of the last build.
    Invoke-PythonStep 'tools/tests/golden/staged_payloads.py' 'Staged payload goldens differ (see tools/tests/artifacts/golden).'
    Invoke-PythonStep 'tools/tests/legacy_bios/test_hardware_smart.py' 'Hardware SMART tests failed.'
    Invoke-PythonStep 'tools/tests/legacy_bios/test_legacy_rgba_rle.py' 'Legacy icon compression tests failed.'
    Invoke-PythonStep 'tools/tests/legacy_bios/test_windows3_media.py' 'Windows 3.x media conversion tests failed.'
    Invoke-PythonStep 'tools/tests/test_dos_batch_labels.py' 'MS-DOS batch label / Windows 3.x flow tests failed.'
    Invoke-PythonStep 'tools/tests/legacy_bios/test_win9x_u9fix.py' 'Windows 9x U9FIX tests failed.'
    Invoke-PythonStep 'tools/tests/legacy_bios/test_xp_dosnet_aliases.py' 'XP DOSNET alias tests failed.'
    Invoke-PythonStep 'tools/tests/legacy_bios/test_nt5_source.py' 'NT5 source identity tests failed.'
    Invoke-PythonStep 'tools/tests/legacy_bios/test_nt5_media_markers.py' 'NT5 local media marker tests failed.'
    Invoke-PythonStep 'tools/tests/legacy_bios/test_xp_drive_letters.py' 'XP drive letter tests failed.'
    Invoke-PythonStep 'tools/tests/legacy_bios/test_xp_source_io.py' 'XP source I/O tests failed.'
    Invoke-PythonStep 'tools/tests/legacy_bios/test_wimboot_kexec.py' 'Windows BIOS kexec entry tests failed.'
    Invoke-PythonStep 'tools/tests/legacy_bios/test_ordered_wimboot_kexec.py' 'Windows BIOS ordered kexec entry tests failed.'
    Invoke-PythonStep 'tools/tests/legacy_bios/test_windows_bios_cpu_check.py' 'Windows BIOS CPU compatibility tests failed.'
    Invoke-PythonStep 'tools/tests/legacy_bios/test_windows_disk_order.py' 'Windows BIOS disk-order tests failed'
    Invoke-PythonStep 'tools/tests/legacy_bios/test_dos_disk_filter.py' 'DOS disk isolation and target MBR tests failed.'
    Invoke-PythonStep 'tools/tests/legacy_bios/test_dos_reboot.py' 'DOS restart helper tests failed.'
    Invoke-PythonStep 'tools/tests/test_windows_source_mount.py' 'Windows PE source mapping tests failed.'
    Invoke-PythonStep 'tools/tests/test_windows_driver_support.py' 'Windows driver transport and answer-file tests failed.'
    Invoke-PythonStep 'tools/tests/test_windows7_nvme.py' 'Windows 7 NVMe helper tests failed.'
    Invoke-PythonStep 'tools/tests/test_vista_int10_dispatcher.py' 'Vista Int10 dispatcher step tests failed.'
    Invoke-PythonStep 'tools/tests/test_vista_autochk.py' 'Vista autochk exclusion tests failed.'
    Invoke-PythonStep 'tools/tests/test_x86_vista_oobe_gate.py' 'Vista / 2008 x86 OOBE gate tests failed.'
    Invoke-PythonStep 'tools/tests/test_image_disk_elcr.py' 'Custom OS ELCR MBR tests failed.'
    Invoke-PythonStep 'tools/tests/test_stick_release.py' 'micro-Linux stick release tests failed.'
    Invoke-PythonStep 'tools/tests/test_stick_write.py' 'micro-Linux read-only stick ESP tests failed.'
    Invoke-PythonStep 'tools/tests/test_esp_writes_helper.py' 'micro-Linux stick ESP write helper tests failed.'
    Invoke-PythonStep 'tools/tests/test_initrd_alignment.py' 'Initramfs alignment (lang.cpio) tests failed.'
    Invoke-PythonStep 'tools/tests/test_nt52_staging.py' 'NT 5.2 (Server 2003 / XP x64) staging tests failed.'
    Invoke-PythonStep 'tools/tests/test_nt5_menu_strings.py' 'NT5 menu strings without a translation key.'
    Invoke-PythonStep 'tools/tests/test_nt5_user_drivers.py' 'NT 5.2 user driver (DATA\Drivers) tests failed.'
    Invoke-PythonStep 'tools/tests/test_windows7_uefi_publish.py' 'Windows 7 EFI publication tests failed.'
    Invoke-PythonStep 'tools/tests/test_uefi_graphics_refresh.py' 'UEFI graphics mode-change regression failed.'
    Invoke-PythonStep 'tools/tests/test_uefi_graphics_connect.py' 'UEFI graphics controller reconnect regression failed.'
    Invoke-PythonStep 'tools/tests/test_xp_reproducible.py' 'XP cabinet/hive reproducibility tests failed.'
    # Answer profiles (docs/answer-profiles.md): rendered WINNT.SIF / autounattend.xml goldens.
    Invoke-PythonStep 'tools/tests/test_answer_render.py' 'Answer renderer goldens failed.'
    Invoke-PythonStep 'tools/tests/test_xp_user_settings.py' 'usos-xp.ini tests failed.'
    # Every Python test module (unittest and pytest style) in one pytest run:
    # it lists every failing test instead of stopping at the first module.
    Invoke-Step 'pytest tools/tests' {
        & python.exe -m pytest (Join-Path $root 'tools/tests') -q -p no:cacheprovider -W ignore::SyntaxWarning
        if ($LASTEXITCODE -ne 0) { throw "pytest reported failures (exit code $LASTEXITCODE)" }
    }
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
    'unit' { Run-Unit; Complete-Run 'Unit tests passed.' }
    'selftest' { Invoke-Step 'selftest' { Run-Selftest }; Complete-Run 'Startup selftest passed.' }
    'x86_64' { Invoke-Step 'x86_64 QEMU' { Run-X64 }; Complete-Run 'x86_64 QEMU boot self-test passed.' }
    'aarch64' { Invoke-Step 'aarch64 QEMU' { Run-Aarch64 }; Complete-Run 'ARM64 QEMU boot self-test passed.' }
    'all' {
        Run-Unit
        Invoke-Step 'selftest' { Run-Selftest }
        Invoke-Step 'x86_64 QEMU' { Run-X64 }
        Invoke-Step 'aarch64 QEMU' { Run-Aarch64 }
        Complete-Run 'All automated tests passed.'
    }
}
