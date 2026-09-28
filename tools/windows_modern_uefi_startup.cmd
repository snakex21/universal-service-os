@echo off
rem Windows 10/11 from UEFI, started natively from the ISO on DATA (no WORK copy).
rem Called by usos-start.cmd after the selected ISO was mounted read-only
rem (%USOS_SOURCE%). The ISO's own WinPE is running; Setup comes from the same ISO.
rem
rem   1. the user's INF drivers (DATA\Drivers\<Windows 10|11>) are loaded into
rem      WinPE with drvload and handed to the target through offlineServicing
rem      DriverPaths (the $WinPEDriver$ equivalent of the WORK path);
rem   2. usos-modern-finalize before: inventory of the USOS stick's ESP, a copy of
rem      its EFI\BOOT files and the start time, all in WinPE RAM;
rem   2b. usos-log --previous-install: logs of an unfinished earlier install on
rem      another disk, copied read-only to the USB log folder (diagnostic only);
rem   3. Setup runs with /noreboot (edition, license and disk stay manual unless
rem      the user's answer file says otherwise);
rem   4. usos-modern-finalize after: boot files and BCD on an ESP of the TARGET
rem      disk, Setup's additions removed from the stick's ESP, the firmware entry
rem      checked; only then the PC restarts.
set "USOS_SETUP=%USOS_SOURCE%\sources\setup.exe"
if not exist "%USOS_SETUP%" (
    echo Required Windows Setup is missing on the selected ISO.
    exit /b 1
)
set "USOS_SOURCE_DISK="
set /p USOS_SOURCE_DISK=<"%USOS_READER%\source-disk.txt"
if not defined USOS_SOURCE_DISK exit /b 1
echo USOS: Setup=%USOS_SETUP% / install source=%USOS_INSTALL% / USOS disk=%USOS_SOURCE_DISK%
echo [USOS] phase=prepare-user-drivers
set "USOS_DRIVERS="
if not exist "%~dp0usos-drivers.bin" goto drivers_done
"%~dp0usos-drivers.exe"
if errorlevel 1 (
    echo [USOS] WARNING: user driver archive rejected; continuing without user drivers.
    goto drivers_done
)
if exist "%~dp0usos-win7-drivers\user\usos-user-drivers.log" type "%~dp0usos-win7-drivers\user\usos-user-drivers.log"
set "USOS_DRIVERS=%~dp0usos-win7-drivers\user"
rem Storage and USB first: Setup lists the disks after this script started it.
for %%C in (Storage USB Other) do if exist "%USOS_DRIVERS%\%%C\" for /r "%USOS_DRIVERS%\%%C" %%I in (*.inf) do (
    echo [USOS] drvload %%I
    drvload "%%I"
)
:drivers_done
echo [USOS] phase=prepare-answer
set "USOS_ANSWER=-"
set "USOS_UNATTEND="
if exist "%~dp0usos-unattend.xml" set "USOS_ANSWER=%~dp0usos-unattend.xml"
if exist "%~dp0usos-unattend.xml" (echo [USOS] User answer file supplied.) else (echo [USOS] No user answer file.)
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
if defined USOS_DRIVERS goto merge_drivers
if not exist "%~dp0usos-unattend.xml" goto answer_ready
rem The user's file still goes through the merge helper, which refuses a
rem DiskID of the USOS stick; the extra DriverPaths folder is empty.
set "USOS_DRIVERS=%~dp0usos-win7-drivers\user"
if not exist "%USOS_DRIVERS%\" md "%USOS_DRIVERS%"
:merge_drivers
rem DriverPaths reach the installed system even without a user answer file;
rem a user DiskID that points at the USOS stick is refused here.
"%~dp0usos-unattend-drivers.exe" "%USOS_ANSWER%" "%~dp0usos-driver-unattend.xml" "%USOS_DRIVERS%" "%USOS_SOURCE_DISK%"
if errorlevel 1 exit /b 1
set "USOS_UNATTEND=%~dp0usos-driver-unattend.xml"
:answer_ready
rem Diagnostic only: an unfinished or aborted Windows installation on another
rem disk (State.ini not complete, leftover $WINDOWS.~BT) gets its logs copied,
rem read-only and size-capped, to the USB log folder (previous-install\).
rem Nothing on the target is written and the result does not change the install.
echo [USOS] phase=previous-install-check
"%~dp0usos-log-x86_64.exe" --previous-install %USOS_SOURCE_DISK%
echo [USOS] phase=esp-guard-before
"%~dp0usos-modern-finalize.exe" before %USOS_SOURCE_DISK%
if errorlevel 1 exit /b 1
echo [USOS] phase=launch-setup answer=%USOS_UNATTEND%
"%~dp0usos-log-x86_64.exe"
if defined USOS_UNATTEND (
    "%~dp0usos-modern-finalize.exe" run-from "%USOS_SETUP%" /noreboot /installfrom:"%USOS_INSTALL%" /unattend:"%USOS_UNATTEND%"
) else (
    "%~dp0usos-modern-finalize.exe" run-from "%USOS_SETUP%" /noreboot /installfrom:"%USOS_INSTALL%"
)
set "USOS_SETUP_RESULT=%errorlevel%"
echo [USOS] phase=setup-returned exit-code=%USOS_SETUP_RESULT%
"%~dp0usos-log-x86_64.exe"
if not "%USOS_SETUP_RESULT%"=="0" exit /b %USOS_SETUP_RESULT%
if defined USOS_HIDDEN (
    "%~dp0usos-run-hidden.exe" --install "%USOS_UNATTEND%" %USOS_SOURCE_DISK%
    if errorlevel 1 (
        echo [USOS] The runner for the answer commands could not be copied to the installed Windows.
        exit /b 1
    )
    echo [USOS] Answer command runner copied to the installed Windows.
)
echo [USOS] phase=finalize-target-boot
"%~dp0usos-modern-finalize.exe" after %USOS_SOURCE_DISK%
set "USOS_FINALIZE_RESULT=%errorlevel%"
"%~dp0usos-log-x86_64.exe"
if not "%USOS_FINALIZE_RESULT%"=="0" exit /b %USOS_FINALIZE_RESULT%
echo [USOS] phase=reboot-after-success
wpeutil reboot
exit /b 0
