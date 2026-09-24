@echo off
setlocal EnableExtensions DisableDelayedExpansion
echo USOS: Windows 7 PE x64 detected. Starting directly from the selected ISO.
echo Built-in WinPE drivers are retained. Additional packages are matched by Windows.
copy /y "%~dp0usos-win7-wrapper.bin" "%~dp0win7-wrapper.efi" >nul
if errorlevel 1 exit /b 1
copy /y "%~dp0usos-win7-video.bin" "%~dp0win7.efi" >nul
if errorlevel 1 exit /b 1
wpeinit
"%~dp0usos-usb-report-x86_64.exe"
"%~dp0usos-drivers.exe"
if errorlevel 1 exit /b 1
rem Bundled library first, then the user's boot-critical packages (user\Storage, user\USB);
rem user\Other (network, GPU, ...) is for the installed system only (DriverPaths).
if exist "%~dp0usos-win7-drivers\" for /l %%P in (1,1,2) do for /d %%D in ("%~dp0usos-win7-drivers\*") do if /i not "%%~nxD"=="user" for /r "%%D" %%I in (*.inf) do drvload "%%I" >nul 2>&1
if exist "%~dp0usos-win7-drivers\" for /l %%P in (1,1,2) do for /f "delims=" %%I in ('dir /b "%~dp0usos-win7-drivers\*.inf" 2^>nul') do drvload "%~dp0usos-win7-drivers\%%I" >nul 2>&1
for %%C in (Storage USB) do if exist "%~dp0usos-win7-drivers\user\%%C\" for /r "%~dp0usos-win7-drivers\user\%%C" %%I in (*.inf) do drvload "%%I" >nul 2>&1
if exist "%~dp0usos-win7-drivers\user\usos-user-drivers.log" type "%~dp0usos-win7-drivers\user\usos-user-drivers.log"
echo USOS Win7 x64: VMD/RST ON (Intel 11-14gen) = brak dysku w Setup - wylacz VMD/RST w BIOS.
echo USOS Win7 x64: Xe/UHD 730/770 i RDNA2 (AM5) = brak driverow pod 7, wymagane dGPU (GTX 900/1000/1600, RTX 2000/3000, RX 400/500/Vega/5000/czesc 6000), inaczej 800x600 VGA. SATA omija NVMe, CSM omija UefiSeven.
rem USOS Win7 x64 SHA-2 queue: KB4474419 Add-Package MUSI poprzedzac Add-Driver (kolejnosc sztywna). Brak pliku = warning, nie fail. Bez unattenda: nie zmienia wyborow instalacji, tylko DriverPaths/offlineServicing via usos-unattend-drivers.exe.
set "USOS_SHA2_MSU="
for %%M in ("%~dp0usos-win7-updates\KB4474419*.msu") do set "USOS_SHA2_MSU=%%M"
if not defined USOS_SHA2_MSU for %%M in ("%~dp0..\Updates\KB4474419*.msu") do set "USOS_SHA2_MSU=%%M"
if defined USOS_SHA2_MSU ( echo USOS: SHA-2 package queued [%USOS_SHA2_MSU%] - Add-Package offline do targetu PRZED Add-Driver. & where dism >nul 2>&1 && ( echo USOS: DISM dostepny w PE - offline Add-Package przed Add-Driver. ) || echo USOS WARNING: brak DISM w PE - pakiet SHA-2 zastosowany pozniej offline, przed Add-Driver. ) else ( echo USOS WARNING: brak KB4474419*.msu w usos-win7-updates - SHA-2 queue pomieta, dalej Add-Driver. )
ping -n 6 127.0.0.1 >nul
"%~dp0usos-usb-report-x86_64.exe"
set "USOS_READER=%~dp0usos-source"
if not exist "%USOS_READER%\" md "%USOS_READER%"
copy /y "%~dp0usos-source-x86_64.exe" "%USOS_READER%\usos-source.exe" >nul
copy /y "%~dp0usos-source.ini" "%USOS_READER%\usos-source.ini" >nul
for %%E in (exe cpl sys) do copy /y "%~dp0imdisk-x86_64.%%E" "%USOS_READER%\imdisk.%%E" >nul
rem Wait for the USB controller and its child disks to finish enumeration.
for /l %%R in (1,1,30) do (
    "%USOS_READER%\usos-source.exe" --source-disk > "%USOS_READER%\source-disk.txt"
    if not errorlevel 1 goto source_ready
    ping -n 3 127.0.0.1 >nul
)
echo USB source not available. A matching signed Windows 7 controller driver is required.
exit /b 1
:source_ready
set "USOS_SOURCE_DISK="
set /p USOS_SOURCE_DISK=<"%USOS_READER%\source-disk.txt"
if not defined USOS_SOURCE_DISK exit /b 1
"%USOS_READER%\usos-source.exe"
if errorlevel 1 exit /b 1
set "USOS_SOURCE="
set /p USOS_SOURCE=<"%USOS_READER%\usos-iso-drive.txt"
if not defined USOS_SOURCE exit /b 1
if not exist "%USOS_SOURCE%\sources\install.wim" exit /b 1
copy /y "%SystemRoot%\Boot\EFI\bootmgfw.efi" "%~dp0win7.original.efi" >nul
if errorlevel 1 exit /b 1
set "USOS_ANSWER=-"
set "USOS_NEED_UNATTEND=0"
if exist "%~dp0usos-unattend.xml" set "USOS_ANSWER=%~dp0usos-unattend.xml"
if exist "%~dp0usos-unattend.xml" set "USOS_NEED_UNATTEND=1"
if exist "%~dp0usos-nvme-packages.flag" set "USOS_NEED_UNATTEND=1"
rem Manual SATA install: bundled usos-win7-drivers are pre-loaded via drvload above (when present), they must NOT force /unattend (Win7 SP1 Setup hosted from WinPE10 then demands <ProductKey>).
if "%USOS_NEED_UNATTEND%"=="1" (
    if exist "%~dp0usos-nvme-packages.flag" (
        "%~dp0usos-win7-unattend.exe" "%USOS_ANSWER%" "%~dp0usos-nvme-unattend.xml" "%USOS_SOURCE_DISK%"
        if errorlevel 1 exit /b 1
        set "USOS_ANSWER=%~dp0usos-nvme-unattend.xml"
    )
    "%~dp0usos-unattend-drivers.exe" "%USOS_ANSWER%" "%~dp0usos-driver-unattend.xml" "%~dp0usos-win7-drivers" "%USOS_SOURCE_DISK%"
    if errorlevel 1 exit /b 1
)
"%~dp0usos-win7-finalize.exe" before
if errorlevel 1 exit /b 1
if "%USOS_NEED_UNATTEND%"=="1" (
    "%~dp0usos-win7-finalize.exe" run /noreboot /installfrom:"%USOS_SOURCE%\sources\install.wim" /unattend:"%~dp0usos-driver-unattend.xml"
) else (
    "%~dp0usos-win7-finalize.exe" run /noreboot /installfrom:"%USOS_SOURCE%\sources\install.wim"
)
if errorlevel 1 exit /b 1
"%~dp0usos-win7-finalize.exe" after
if errorlevel 1 exit /b 1
wpeutil reboot
exit /b 0
