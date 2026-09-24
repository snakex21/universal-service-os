@echo off
setlocal
set "ROOT=%~dp0"
set "ZIG=%ROOT%tools\zig\zig.exe"
set "ZIG_GLOBAL_CACHE_DIR=%ROOT%tools\cache\zig-global"

if not exist "%ZIG%" (
    echo [ERROR] Zig not found: %ZIG%
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\generate_build_info.ps1"
if errorlevel 1 exit /b %ERRORLEVEL%
call "%ROOT%build\generated\build-env.cmd"
if not defined USOS_BUILD_ID (
    echo [ERROR] Build identifier was not generated.
    exit /b 1
)
echo [BUILD] %USOS_BUILD_ID%

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\clean_release_outputs.ps1"
if errorlevel 1 exit /b %ERRORLEVEL%

rem The micro-linux Zig step builds the XP NT52 bootstrap and Strategy B MBR
rem before packing initramfs, so clean and standalone micro-linux builds use
rem the same dependency graph as the full release.

rem Build release USB and manual-QEMU USB in one Zig graph so both copies of
rem BOOTX64.EFI come from the exact same emitted binary and build identifier.
"%ZIG%" build --cache-dir "%ROOT%tools\cache\zig" test selftest install qemu-x86_64-manual-image fetch-ntfs-driver micro-linux -Doptimize=ReleaseFast
if errorlevel 1 exit /b %ERRORLEVEL%

rem Release-owned helpers for the direct Core -> Windows PE path.
python "%ROOT%tools\build_windows_native_support.py"
if errorlevel 1 exit /b %ERRORLEVEL%
python "%ROOT%tools\build_dos_native_support.py"
if errorlevel 1 exit /b %ERRORLEVEL%

rem Secure Boot: the vendored Microsoft-signed shim becomes EFI\BOOT\BOOTX64.EFI,
rem USOS becomes the MOK-signed EFI\BOOT\grubx64.efi, and the micro-Linux kernel,
rem systemd-boot and the NTFS driver are signed in place. The private key lives
rem outside the repository (%%APPDATA%%\USOS\signing); without it the same layout
rem is emitted UNSIGNED (boots only with Secure Boot off). docs\secure-boot-usos.md
pushd "%ROOT%installer"
go run ./cmd/usos-efisign release -root ..
if errorlevel 1 (
    popd
    exit /b 1
)
popd

rem Legacy BIOS boots the same pinned micro-Linux kernel without systemd-boot.
rem Fail the release build if its Linux/x86 setup header no longer matches the
rem protocol contract expected by the PM32 loader.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\tests\legacy_bios\run_linux_boot_header.ps1"
if errorlevel 1 exit /b %ERRORLEVEL%

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\build_legacy_bios.ps1"
if errorlevel 1 exit /b %ERRORLEVEL%
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\tests\legacy_bios\test_production_core_guard.ps1"
if errorlevel 1 exit /b %ERRORLEVEL%
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\generate_legacy_boot_payload.ps1"
if errorlevel 1 exit /b %ERRORLEVEL%

if not exist "%ROOT%zig-out\usb\EFI\USOS" mkdir "%ROOT%zig-out\usb\EFI\USOS"
copy /y "%ROOT%build\generated\build-info.ini" "%ROOT%zig-out\usb\EFI\USOS\build-info.ini" >nul
if errorlevel 1 exit /b %ERRORLEVEL%
if not exist "%ROOT%zig-out\manual-usb\EFI\USOS" mkdir "%ROOT%zig-out\manual-usb\EFI\USOS"
copy /y "%ROOT%build\generated\build-info.ini" "%ROOT%zig-out\manual-usb\EFI\USOS\build-info.ini" >nul
if errorlevel 1 exit /b %ERRORLEVEL%

pushd "%ROOT%installer"
go run ./cmd/usos-payload-pack -root .. -out internal/payload/assets/payload.zip
if errorlevel 1 (
    popd
    exit /b 1
)
go run ./cmd/usos-payload-pack -root .. -out internal/payload/assets/payload.zip -verify-fresh-only
if errorlevel 1 (
    echo [ERROR] Refusing to build installer with stale payload.zip.
    popd
    exit /b 1
)
popd

rem Hard gate before EXE creation: payload must exactly match the current USB
rem artifacts and must carry the generated build-info.ini.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\verify_release_consistency.ps1"
if errorlevel 1 exit /b %ERRORLEVEL%

set "USOS_GO_BUILDINFO=-X github.com/snakex21/universal-service-os/installer/internal/buildinfo.ID=%USOS_BUILD_ID% -X github.com/snakex21/universal-service-os/installer/internal/buildinfo.EpochText=%USOS_BUILD_EPOCH% -X github.com/snakex21/universal-service-os/installer/internal/buildinfo.SourceSHA256=%USOS_BUILD_SOURCE_SHA256%"
pushd "%ROOT%installer"
go test -ldflags "%USOS_GO_BUILDINFO%" ./...
if errorlevel 1 (
    popd
    exit /b 1
)

if exist "USOS Installer.exe" del /f /q "USOS Installer.exe"
go build -trimpath -ldflags "-H=windowsgui %USOS_GO_BUILDINFO%" -o "USOS Installer.exe" ./cmd/usos-installer
if errorlevel 1 (
    popd
    exit /b 1
)
popd

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\verify_release_consistency.ps1"
if errorlevel 1 exit /b %ERRORLEVEL%

echo [PASS] Release USB, manual test and embedded installer payload are consistent.
echo [PASS] Build: %USOS_BUILD_ID%
echo [PASS] Installer: %ROOT%installer\USOS Installer.exe
exit /b 0
