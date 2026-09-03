@echo off
setlocal
set "ROOT=%~dp0"
set "ZIG=%ROOT%tools\zig\zig.exe"

if not exist "%ZIG%" (
    echo [ERROR] Zig not found: %ZIG%
    exit /b 1
)

"%ZIG%" build -Doptimize=ReleaseFast
if errorlevel 1 exit /b %ERRORLEVEL%

"%ZIG%" build qemu-x86_64-manual-image fetch-ntfs-driver micro-linux -Doptimize=ReleaseFast
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

if not exist "build" mkdir "build"
go build -trimpath -ldflags "-H=windowsgui" -o "build\USOS Installer.exe" ./cmd/usos-installer
if errorlevel 1 (
    popd
    exit /b 1
)
popd

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\verify_release_consistency.ps1"
if errorlevel 1 exit /b %ERRORLEVEL%

echo [PASS] Release USB, manual test and embedded installer payload are consistent.
echo [PASS] Installer: %ROOT%installer\build\USOS Installer.exe
exit /b 0
