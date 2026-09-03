@echo off
setlocal
cd /d "%~dp0"

set "QEMU_DIR=%~dp0tools\qemu"
if not exist "%QEMU_DIR%\qemu-system-aarch64.exe" (
    echo [ERROR] QEMU ARM64 not found.
    exit /b 2
)

set "FIRMWARE_CODE=%QEMU_DIR%\share\edk2-aarch64-code.fd"
set "FIRMWARE_VARS=%QEMU_DIR%\share\edk2-arm-vars.fd"
if not exist "%FIRMWARE_CODE%" (
    echo [ERROR] ARM64 UEFI firmware code not found.
    exit /b 3
)
if not exist "%FIRMWARE_VARS%" (
    echo [ERROR] ARM64 UEFI firmware vars not found.
    exit /b 3
)

call "%~dp0tools\zig\zig.exe" build qemu-aarch64-image -Doptimize=ReleaseFast
if errorlevel 1 exit /b %errorlevel%

"%QEMU_DIR%\qemu-system-aarch64.exe" ^
    -machine virt ^
    -cpu cortex-a57 ^
    -m 128M ^
    -drive "if=pflash,format=raw,readonly=on,file=%FIRMWARE_CODE%" ^
    -drive "if=pflash,format=raw,file=%FIRMWARE_VARS%,snapshot=on" ^
    -drive "file=fat:rw:%~dp0zig-out\qemu-arm64-usb,format=raw,if=none,id=bootdisk" ^
    -device virtio-blk-pci,drive=bootdisk ^
    -net none ^
    -display none ^
    -monitor none ^
    -serial stdio ^
    -no-reboot

if errorlevel 1 (
    echo [FAIL] ARM64 QEMU boot self-test
    exit /b 1
)

echo [PASS] ARM64 QEMU boot self-test
exit /b 0
