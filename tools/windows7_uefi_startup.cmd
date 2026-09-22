@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "USOS_NONCE=@USOS_NONCE@"
rem WinPE drivers must be available before the USB source can be opened.
for /l %%P in (1,1,2) do for /r "%~dp0drivers" %%I in (*.inf) do drvload "%%I"
if exist "%~dp0nvme-load.flag" (
    "%~dp0usos-win7-nvme.exe"
    if errorlevel 1 goto failed
    drvload "%~dp0nvme\stornvme.inf"
    if errorlevel 1 goto failed
)
set "USOS_FOUND=0"
set "USOS_SOURCE="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do call :check_source %%D
if !USOS_FOUND! GTR 1 goto failed
if defined USOS_SOURCE goto ready
rem PnP enumeration continues after DrvLoad returns, especially on USB 3.
for /l %%R in (1,1,30) do (
    "%~dp0usos-source.exe"
    if not errorlevel 1 goto mounted
    ping -n 3 127.0.0.1 >nul
)
echo The prepared Windows 7 source could not be opened.
goto failed
:mounted
set "USOS_FOUND=0"
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do call :check_source %%D
if not !USOS_FOUND!==1 goto failed
:ready
"%~dp0usos-win7-finalize.exe" before
if errorlevel 1 goto failed
set "USOS_ARGS="
if exist "!USOS_SOURCE!\Autounattend.xml" set USOS_ARGS=/unattend:"!USOS_SOURCE!\Autounattend.xml"
if exist "%~dp0nvme-enabled.flag" (
    set "USOS_INPUT=-"
    if exist "!USOS_SOURCE!\Autounattend.xml" set "USOS_INPUT=!USOS_SOURCE!\Autounattend.xml"
    set "USOS_SOURCE_DISK="
    for /f "delims=" %%N in ('"%~dp0usos-source.exe" --source-disk') do set "USOS_SOURCE_DISK=%%N"
    if not defined USOS_SOURCE_DISK goto failed
    "%~dp0usos-win7-unattend.exe" "!USOS_INPUT!" "%~dp0nvme-unattend.xml" "!USOS_SOURCE_DISK!"
    if errorlevel 1 goto failed
    set USOS_ARGS=/unattend:"%~dp0nvme-unattend.xml"
)
"%~dp0usos-win7-finalize.exe" run /noreboot /installfrom:"!USOS_SOURCE!\sources\install.wim" !USOS_ARGS!
if errorlevel 1 goto failed
"%~dp0usos-win7-finalize.exe" after
if errorlevel 1 goto failed
wpeutil reboot
exit /b 0
:failed
rem Keep the process error code outside parenthesized blocks on WinPE 6.1.
exit /b 1
:check_source
if not exist "%~1:\.usos-work" exit /b
set "USOS_MATCH="
for /f "usebackq delims=" %%L in ("%~1:\.usos-work") do if "%%L"=="nonce=%USOS_NONCE%" set "USOS_MATCH=1"
if not defined USOS_MATCH exit /b
if not exist "%~1:\sources\install.wim" exit /b
set "USOS_SOURCE=%~1:"
set /a USOS_FOUND+=1
exit /b
