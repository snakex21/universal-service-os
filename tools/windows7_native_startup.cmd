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
rem Windows installations present before Setup (never targets for the user drivers).
if exist "%~dp0usos-old-windows.txt" del "%~dp0usos-old-windows.txt"
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist "%%D:\Windows\System32\config\SOFTWARE" echo %%D>>"%~dp0usos-old-windows.txt"
if "%USOS_NEED_UNATTEND%"=="1" (
    "%~dp0usos-win7-finalize.exe" run /noreboot /installfrom:"%USOS_SOURCE%\sources\install.wim" /unattend:"%~dp0usos-driver-unattend.xml"
) else (
    "%~dp0usos-win7-finalize.exe" run /noreboot /installfrom:"%USOS_SOURCE%\sources\install.wim"
)
if errorlevel 1 exit /b 1
if "%USOS_NEED_UNATTEND%"=="0" call :user_drivers_setupcomplete
"%~dp0usos-win7-finalize.exe" after
if errorlevel 1 exit /b 1
wpeutil reboot
exit /b 0

rem Without an answer file the user packages have no DriverPaths entry, and
rem forcing /unattend would make Setup ask for a product key. Instead, once
rem Setup has applied the image (/noreboot), copy them to <target>\USOS\Drivers
rem and let the installed system add them from SetupComplete.cmd (pnputil).
rem Never fatal: any doubt about the target leaves it untouched.
:user_drivers_setupcomplete
if not exist "%~dp0usos-win7-drivers\user\" exit /b 0
set "USOS_USER_INF="
for /r "%~dp0usos-win7-drivers\user" %%I in (*.inf) do set "USOS_USER_INF=1"
if not defined USOS_USER_INF exit /b 0
set "USOS_TARGET="
set "USOS_TARGET_COUNT=0"
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist "%%D:\Windows\Panther\setupact.log" if exist "%%D:\Windows\System32\config\SOFTWARE" call :user_drivers_candidate %%D
if not "%USOS_TARGET_COUNT%"=="1" (
    echo USOS WARNING: %USOS_TARGET_COUNT% new Windows installations found; user drivers not added to the installed system.
    exit /b 0
)
if exist "%USOS_TARGET%:\Windows\Setup\Scripts\SetupComplete.cmd" (
    echo USOS WARNING: the installed image has its own SetupComplete.cmd; user drivers not added.
    exit /b 0
)
xcopy "%~dp0usos-win7-drivers\user" "%USOS_TARGET%:\USOS\Drivers\" /e /i /q /h /y >nul
if errorlevel 1 (
    echo USOS WARNING: cannot copy the user drivers to %USOS_TARGET%:\USOS\Drivers.
    exit /b 0
)
if not exist "%USOS_TARGET%:\Windows\Setup\Scripts\" md "%USOS_TARGET%:\Windows\Setup\Scripts"
copy /y "%~dp0usos-win7-setupcomplete.cmd" "%USOS_TARGET%:\Windows\Setup\Scripts\SetupComplete.cmd" >nul
if errorlevel 1 (
    echo USOS WARNING: cannot write SetupComplete.cmd; user drivers stay in %USOS_TARGET%:\USOS\Drivers.
    exit /b 0
)
echo USOS: user drivers copied to %USOS_TARGET%:\USOS\Drivers; the installed Windows adds them on its first start (SetupComplete.cmd, pnputil).
exit /b 0

:user_drivers_candidate
if exist "%~dp0usos-old-windows.txt" findstr /x /i /c:"%~1" "%~dp0usos-old-windows.txt" >nul 2>&1 && exit /b 0
set "USOS_TARGET=%~1"
set /a USOS_TARGET_COUNT+=1
exit /b 0
