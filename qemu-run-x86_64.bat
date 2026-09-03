@echo off
setlocal
cd /d "%~dp0"

set "QEMU_DIR=%~dp0tools\qemu"
if not exist "%QEMU_DIR%\qemu-system-x86_64w.exe" (
    echo [ERROR] QEMU not found in tools\qemu
    exit /b 2
)

set "FIRMWARE_CODE=%QEMU_DIR%\share\edk2-x86_64-code.fd"
set "FIRMWARE_VARS=%QEMU_DIR%\share\edk2-i386-vars.fd"
if not exist "%FIRMWARE_CODE%" exit /b 3
if not exist "%FIRMWARE_VARS%" exit /b 3

call "%~dp0tools\zig\zig.exe" build qemu-x86_64-manual-image -Doptimize=ReleaseFast
if errorlevel 1 exit /b %errorlevel%

start "Universal Service OS" /wait "%QEMU_DIR%\qemu-system-x86_64w.exe" ^
    -name "Universal Service OS - Manual Preview" ^
    -machine q35 ^
    -m 64M ^
    -drive "if=pflash,format=raw,readonly=on,file=%FIRMWARE_CODE%" ^
    -drive "if=pflash,format=raw,file=%FIRMWARE_VARS%,snapshot=on" ^
    -drive "file=fat:rw:%~dp0zig-out\manual-usb,format=raw,if=ide" ^
    -boot order=c ^
    -net none ^
    -monitor tcp:127.0.0.1:4444,server,nowait ^
    -serial none ^
    -no-reboot
