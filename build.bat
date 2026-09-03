@echo off
setlocal
set "ROOT=%~dp0"
set "ZIG=%ROOT%tools\zig\zig.exe"

if not exist "%ZIG%" (
    echo [ERROR] Zig not found: %ZIG%
    exit /b 1
)

"%ZIG%" build -Doptimize=ReleaseFast
exit /b %ERRORLEVEL%
