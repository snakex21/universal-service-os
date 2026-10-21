@echo off
rem Called after the selected ISO was mounted by usos-start.cmd.
rem PE10 supplies the running kernel and drivers. Setup and its media resources
rem must stay together on the selected installation ISO, including for stock Win7.
set "USOS_SETUP=%USOS_SOURCE%\sources\setup.exe"
if not exist "%USOS_SETUP%" (
    echo Required Windows Setup is missing on the selected ISO. No fallback to donor Setup.
    exit /b 1
)
echo USOS: Setup=%USOS_SETUP% / install source=%USOS_INSTALL%
echo [USOS] phase=prepare-target-drivers
rem A repair request is bound to exact disk/partition GPT identities on the USB.
rem 10 means no request. Every other result stops here, before Windows Setup.
"%~dp0usos-win7-kmdf-repair.exe"
set "USOS_REPAIR_RESULT=%errorlevel%"
if not "%USOS_REPAIR_RESULT%"=="10" exit /b %USOS_REPAIR_RESULT%
rem Stage optional target packages without automating edition, disk or OOBE choices.
"%~dp0usos-drivers.exe"
if errorlevel 1 exit /b 1
rem This PE keeps its own USB/storage stack. Win7 packages belong to the target.
rem The user's packages (DATA\Drivers\Windows 7 -> usos-win7-drivers\user, Storage/USB/Other)
rem are Windows 7 drivers too: they reach the installed system through the DriverPaths
rem entry below (offlineServicing); PE10 is not given Windows 7 drivers.
if exist "%~dp0usos-win7-drivers\user\usos-user-drivers.log" type "%~dp0usos-win7-drivers\user\usos-user-drivers.log"
set "USOS_SOURCE_DISK="
set /p USOS_SOURCE_DISK=<"%USOS_READER%\source-disk.txt"
if not defined USOS_SOURCE_DISK exit /b 1
set "USOS_ANSWER=-"
echo [USOS] phase=prepare-target-answer
set "USOS_NEED_UNATTEND=1"
if exist "%~dp0usos-unattend.xml" set "USOS_ANSWER=%~dp0usos-unattend.xml"
if exist "%~dp0usos-unattend.xml" (echo [USOS] User answer file supplied.) else (echo [USOS] No user answer file; USOS generates servicing settings.)
if exist "%~dp0usos-unattend.xml" set "USOS_NEED_UNATTEND=1"
if exist "%~dp0usos-nvme-packages.flag" set "USOS_NEED_UNATTEND=1"
rem A USOS profile answer: its commands run without console windows through
rem usos-run-hidden.exe (tools/windows_hidden_commands.h); 10 = nothing to wrap
rem (a DATA answer file, or no commands). The runner goes to the target after Setup.
set "USOS_HIDDEN="
if not exist "%~dp0usos-unattend.xml" goto hidden_done
"%~dp0usos-run-hidden.exe" --wrap "%~dp0usos-unattend.xml" "%~dp0usos-hidden-unattend.xml"
if errorlevel 11 exit /b 1
if errorlevel 10 goto hidden_done
if errorlevel 1 exit /b 1
set "USOS_ANSWER=%~dp0usos-hidden-unattend.xml"
set "USOS_HIDDEN=1"
echo [USOS] Profile answer commands run without console windows.
:hidden_done
rem DriverPaths must reach the target even without a user answer file.
rem Generated settings only service packages/drivers; edition and disk stay manual.
if exist "%~dp0usos-nvme-packages.flag" (
    "%~dp0usos-win7-unattend.exe" "%USOS_ANSWER%" "%~dp0usos-nvme-unattend.xml" "%USOS_SOURCE_DISK%"
    if errorlevel 1 exit /b 1
    set "USOS_ANSWER=%~dp0usos-nvme-unattend.xml"
)
rem Keep this outside the preceding block: cmd expands percent variables per block.
"%~dp0usos-unattend-drivers.exe" "%USOS_ANSWER%" "%~dp0usos-driver-unattend.xml" "%~dp0usos-win7-drivers" "%USOS_SOURCE_DISK%"
if errorlevel 1 exit /b 1
copy /y "%~dp0usos-win7-wrapper.bin" "%~dp0win7-wrapper.efi" >nul
if errorlevel 1 exit /b 1
copy /y "%~dp0usos-win7-video.bin" "%~dp0win7.efi" >nul
if errorlevel 1 exit /b 1
"%~dp0usos-win7-finalize.exe" before
if errorlevel 1 exit /b 1
rem Windows installations present before Setup (native-resolution staging only).
if exist "%~dp0usos-old-windows.txt" del "%~dp0usos-old-windows.txt"
if exist "%~dp0usos-native-res.flag" for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist "%%D:\Windows\System32\config\SOFTWARE" echo %%D>>"%~dp0usos-old-windows.txt"
echo [USOS] phase=launch-setup generated-answer=%USOS_NEED_UNATTEND%
"%~dp0usos-log-x86_64.exe"
if "%USOS_NEED_UNATTEND%"=="1" (
    "%~dp0usos-win7-finalize.exe" run-from "%USOS_SETUP%" /noreboot /installfrom:"%USOS_INSTALL%" /unattend:"%~dp0usos-driver-unattend.xml"
) else (
    "%~dp0usos-win7-finalize.exe" run-from "%USOS_SETUP%" /noreboot /installfrom:"%USOS_INSTALL%"
)
set "USOS_SETUP_RESULT=%errorlevel%"
echo [USOS] phase=setup-returned exit-code=%USOS_SETUP_RESULT%
"%~dp0usos-log-x86_64.exe"
if not "%USOS_SETUP_RESULT%"=="0" exit /b %USOS_SETUP_RESULT%
if defined USOS_HIDDEN (
    "%~dp0usos-run-hidden.exe" --install "%~dp0usos-driver-unattend.xml" %USOS_SOURCE_DISK%
    if errorlevel 1 (
        echo [USOS] The runner for the answer commands could not be copied to the installed Windows.
        exit /b 1
    )
    echo [USOS] Answer command runner copied to the installed Windows.
)
if exist "%~dp0usos-native-res.flag" call :native_res_display
echo [USOS] phase=finalize-target-efi
"%~dp0usos-win7-finalize.exe" after-modern
if errorlevel 1 exit /b 1
echo [USOS] phase=reboot-after-success
"%~dp0usos-log-x86_64.exe"
wpeutil reboot
exit /b 0

rem Native-resolution experiment (usos-native-res.flag from DATA
rem Systems\Windows\Windows 7\Unattended\native-res-on.txt;
rem docs/w7x64-native-res-2026-10-21.md): the dispatcher then offers the
rem monitor's native VBE mode besides 1024x768, and USOSRES (registered by
rem the USOS answer's guarded specialize command) selects it at the first
rem sign-in. Stage <target>\USOS\NT6\USOSRES.EXE + DISPLAY.TXT (auto).
rem Never fatal.
:native_res_display
if not exist "%~dp0usos-res.exe" exit /b 0
set "USOS_TARGET="
set "USOS_TARGET_COUNT=0"
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist "%%D:\Windows\Panther\setupact.log" if exist "%%D:\Windows\System32\config\SOFTWARE" call :native_res_candidate %%D
if not "%USOS_TARGET_COUNT%"=="1" (
    echo USOS WARNING: %USOS_TARGET_COUNT% new Windows installations found; USOSRES not staged.
    exit /b 0
)
if not exist "%USOS_TARGET%:\USOS\NT6\" md "%USOS_TARGET%:\USOS\NT6"
copy /y "%~dp0usos-res.exe" "%USOS_TARGET%:\USOS\NT6\USOSRES.EXE" >nul
if errorlevel 1 (
    echo USOS WARNING: cannot copy USOSRES to %USOS_TARGET%:\USOS\NT6.
    exit /b 0
)
> "%USOS_TARGET%:\USOS\NT6\DISPLAY.TXT" echo autoxauto
echo USOS: native-resolution experiment: USOSRES staged in %USOS_TARGET%:\USOS\NT6 (auto: EDID native, else highest).
exit /b 0

:native_res_candidate
if exist "%~dp0usos-old-windows.txt" find /i "%~1" "%~dp0usos-old-windows.txt" >nul 2>&1 && exit /b 0
set "USOS_TARGET=%~1"
set /a USOS_TARGET_COUNT+=1
exit /b 0
