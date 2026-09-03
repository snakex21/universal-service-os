param(
    [ValidateSet('all', 'unit', 'selftest', 'x86_64', 'aarch64')]
    [string]$Suite = 'all'
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$zig = Join-Path $root 'tools\zig\zig.exe'
$zigCache = Join-Path $root 'tools\cache\zig'
$qemuLocal = Join-Path $root 'tools\qemu'

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
        -serial stdio `
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
        -serial stdio `
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
