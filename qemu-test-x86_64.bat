@echo off
setlocal
cd /d "%~dp0"

set "QEMU_DIR=%~dp0tools\qemu"
if not exist "%QEMU_DIR%\qemu-system-x86_64.exe" set "QEMU_DIR=C:\Program Files\qemu"

if not exist "%QEMU_DIR%\qemu-system-x86_64.exe" (
    echo [ERROR] QEMU not found. Expected tools\qemu\qemu-system-x86_64.exe
    exit /b 2
)

set "FIRMWARE_CODE=%QEMU_DIR%\share\edk2-x86_64-code.fd"
set "FIRMWARE_VARS=%QEMU_DIR%\share\edk2-i386-vars.fd"
if not exist "%FIRMWARE_CODE%" (
    echo [ERROR] UEFI firmware code not found: %FIRMWARE_CODE%
    exit /b 3
)
if not exist "%FIRMWARE_VARS%" (
    echo [ERROR] UEFI firmware vars not found: %FIRMWARE_VARS%
    exit /b 3
)

call "%~dp0tools\zig\zig.exe" build qemu-x86_64-image -Doptimize=ReleaseFast
if errorlevel 1 exit /b %errorlevel%

"%QEMU_DIR%\qemu-system-x86_64.exe" ^
    -machine q35 ^
    -m 64M ^
    -drive "if=pflash,format=raw,readonly=on,file=%FIRMWARE_CODE%" ^
    -drive "if=pflash,format=raw,file=%FIRMWARE_VARS%,snapshot=on" ^
    -drive "file=fat:rw:%~dp0zig-out\qemu-usb,format=raw,if=ide" ^
    -boot order=c ^
    -net none ^
    -display none ^
    -monitor none ^
    -serial stdio ^
    -no-reboot ^
    -device isa-debug-exit,iobase=0xf4,iosize=0x04

set "QEMU_EXIT=%errorlevel%"
if "%QEMU_EXIT%"=="33" (
    echo [PASS] QEMU boot self-test
    exit /b 0
)
if "%QEMU_EXIT%"=="35" (
    echo [FAIL] QEMU boot self-test
    exit /b 1
)

echo [ERROR] QEMU ended with unexpected code %QEMU_EXIT%
exit /b %QEMU_EXIT%
