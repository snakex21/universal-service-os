@echo off
setlocal EnableExtensions DisableDelayedExpansion
title USOS - Starting Windows Setup
if exist "%~dp0usos-stock-win7.flag" goto stock_win7
wpeinit
echo [USOS] phase=winpe-initialized
ver
set "USOS_ARCH=x86"
if /i "%PROCESSOR_ARCHITECTURE%"=="AMD64" set "USOS_ARCH=x86_64"
if exist "%~dp0usos-usb-report-%USOS_ARCH%.exe" "%~dp0usos-usb-report-%USOS_ARCH%.exe"
set "USOS_READER=%~dp0usos-source"
if not exist "%USOS_READER%\" md "%USOS_READER%"
copy /y "%~dp0usos-source-%USOS_ARCH%.exe" "%USOS_READER%\usos-source.exe" >nul
copy /y "%~dp0usos-source.ini" "%USOS_READER%\usos-source.ini" >nul
for %%E in (exe cpl sys) do copy /y "%~dp0imdisk-%USOS_ARCH%.%%E" "%USOS_READER%\imdisk.%%E" >nul
if exist "%USOS_READER%\usos-iso-drive.txt" del "%USOS_READER%\usos-iso-drive.txt"
for /l %%R in (1,1,30) do (
    "%USOS_READER%\usos-source.exe" --source-disk > "%USOS_READER%\source-disk.txt"
    if not errorlevel 1 goto source_ready
    ping -n 3 127.0.0.1 >nul
)
goto missing
:source_ready
"%USOS_READER%\usos-source.exe" --log-root > "%~dp0usos-log-root.txt"
if errorlevel 1 (
    echo [USOS] WARNING: persistent USB logs unavailable; diagnostics remain in WinPE RAM.
) else (
    echo [USOS] Persistent logs: source USB ESP, EFI\USOS\Logs
    start "" /b "%~dp0usos-log-%USOS_ARCH%.exe" --watch
)
echo [USOS] phase=mount-selected-iso
"%USOS_READER%\usos-source.exe" > "%USOS_READER%\source.log" 2>&1
if errorlevel 1 goto missing
set "USOS_SOURCE="
set /p USOS_SOURCE=<"%USOS_READER%\usos-iso-drive.txt"
if not defined USOS_SOURCE goto missing
if not exist "%USOS_SOURCE%\sources\setup.exe" goto missing
set "USOS_INSTALL=%USOS_SOURCE%\sources\install.wim"
if not exist "%USOS_INSTALL%" set "USOS_INSTALL=%USOS_SOURCE%\sources\install.esd"
rem A split image: /installfrom takes the first part, install.swm.
if not exist "%USOS_INSTALL%" set "USOS_INSTALL=%USOS_SOURCE%\sources\install.swm"
if not exist "%USOS_INSTALL%" goto missing
echo Selected Windows installation ISO mounted at %USOS_SOURCE%
echo [USOS] phase=source-ready install=%USOS_INSTALL%
if exist "%~dp0usos-modern-vista.flag" goto modern_vista
if exist "%~dp0usos-modern-win7.flag" goto modern_win7
if exist "%~dp0usos-modern-uefi.flag" goto modern_uefi
if exist "%~dp0usos-unattend.xml" (
    "%USOS_SOURCE%\sources\setup.exe" /installfrom:"%USOS_INSTALL%" /unattend:"%~dp0usos-unattend.xml"
) else (
    "%USOS_SOURCE%\sources\setup.exe" /installfrom:"%USOS_INSTALL%"
)
exit /b %errorlevel%
:modern_vista
call "%~dp0usos-modern-vista.cmd"
exit /b %errorlevel%
:modern_uefi
call "%~dp0usos-modern-uefi.cmd"
exit /b %errorlevel%
:modern_win7
call "%~dp0usos-modern-win7.cmd"
exit /b %errorlevel%
:stock_win7
call "%~dp0usos-win7-start.cmd"
exit /b %errorlevel%
:missing
echo The selected USOS ISO could not be opened. Setup was not started.
if exist "%USOS_READER%\source.log" type "%USOS_READER%\source.log"
exit /b 1
