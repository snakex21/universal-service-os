@echo off
setlocal
set "ROOT=%~dp0"
set "ZIG=%ROOT%tools\zig\zig.exe"

if not exist "%ZIG%" (
    echo [ERROR] Zig not found: %ZIG%
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\clean_release_outputs.ps1"
if errorlevel 1 exit /b %ERRORLEVEL%

rem Build release USB and manual-QEMU USB in one Zig graph so both copies of
rem BOOTX64.EFI come from the exact same emitted binary, not two separately
rem linked PE/COFF files with potentially different build metadata.
"%ZIG%" build --cache-dir "%ROOT%tools\cache\zig" install qemu-x86_64-manual-image fetch-ntfs-driver micro-linux -Doptimize=ReleaseFast
if errorlevel 1 exit /b %ERRORLEVEL%

pushd "%ROOT%installer"
go run ./cmd/usos-payload-pack -root .. -out internal/payload/assets/payload.zip
if errorlevel 1 (
    popd
    exit /b 1
)

go test ./...
if errorlevel 1 (
    popd
    exit /b 1
)

go build -trimpath -ldflags "-H=windowsgui" -o "USOS Installer.exe" ./cmd/usos-installer
if errorlevel 1 (
    popd
    exit /b 1
)
popd

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\verify_release_consistency.ps1"
if errorlevel 1 exit /b %ERRORLEVEL%

echo [PASS] Release USB, manual test and embedded installer payload are consistent.
echo [PASS] Installer: %ROOT%installer\USOS Installer.exe
exit /b 0
