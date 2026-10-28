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
rem NVMe controller in this PE, Windows 7 SP1 x64 / 2008 R2 (Microsoft NVMe
rem packages in the answer): Setup runs from a RAM copy of the media's sources
rem whose hwcompat.txt lists PCI\CC_010802 (:nvme_setup).
set "USOS_NVME_SETUP="
if exist "%~dp0usos-nvme-packages.flag" call :nvme_setup
rem Windows installations present before Setup (native-resolution staging, NVMe check).
if exist "%~dp0usos-old-windows.txt" del "%~dp0usos-old-windows.txt"
set "USOS_OLD_LIST="
if exist "%~dp0usos-native-res.flag" set "USOS_OLD_LIST=1"
if defined USOS_NVME_SETUP set "USOS_OLD_LIST=1"
if defined USOS_OLD_LIST for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist "%%D:\Windows\System32\config\SOFTWARE" echo %%D>>"%~dp0usos-old-windows.txt"
echo [USOS] phase=launch-setup generated-answer=%USOS_NEED_UNATTEND%
"%~dp0usos-log-x86_64.exe"
rem Setup copy (:nvme_setup): its folder is the working directory, as on the x86 path.
if defined USOS_NVME_SETUP pushd "%USOS_SRC%\sources"
if "%USOS_NEED_UNATTEND%"=="1" (
    "%~dp0usos-win7-finalize.exe" run-from "%USOS_SETUP%" /noreboot /installfrom:"%USOS_INSTALL%" /unattend:"%~dp0usos-driver-unattend.xml"
) else (
    "%~dp0usos-win7-finalize.exe" run-from "%USOS_SETUP%" /noreboot /installfrom:"%USOS_INSTALL%"
)
set "USOS_SETUP_RESULT=%errorlevel%"
if defined USOS_NVME_SETUP popd
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
if defined USOS_NVME_SETUP call :nvme_target
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

rem ---- NVMe controller: Setup 6.1 disk check (before Setup) -----------------
rem Windows 7 Setup looks up the disk's controller (PCI\CC_010802, run by this
rem PE10's inbox stornvme.inf) in sources\hwcompat.txt of the media, which
rem predates NVMe, and refuses the disk: "System Windows potrzebuje sterownika
rem urzadzenia [Standardowy kontroler NVM Express]" (X470 Micron 3400,
rem 2026-10-21). The Microsoft packages in the answer's servicing section come
rem too late for that check (offlineServicing, after the disk page). As on the
rem x86 donor path (tools/windows_x86_csmwrap.cmd :nvme_setup, X470 PASS
rem Windows 7 SP1 x86): Setup runs from a copy of the sources folder (the
rem install image stays on the ISO, /installfrom) in the RAM disk whose
rem hwcompat.txt also lists the NVMe class code. Nothing is injected into the
rem PE or migrated. Only with an NVMe controller in this PE; any failure keeps
rem the original Setup (SATA unchanged; an NVMe disk is refused as before).
rem docs/w7x64-nvme-setup-2026-10-21.md
:nvme_setup
set "USOS_NVME_COUNT="
for /f "tokens=3" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Services\stornvme\Enum" /v Count 2^>nul ^| find /i "Count"') do set "USOS_NVME_COUNT=%%A"
if not defined USOS_NVME_COUNT (echo [USOS] NVMe: no NVMe controller in this PE; original Setup. & exit /b 0)
if "%USOS_NVME_COUNT%"=="0x0" (echo [USOS] NVMe: no NVMe controller in this PE; original Setup. & exit /b 0)
if not exist "%USOS_SOURCE%\sources\hwcompat.txt" (echo [USOS] NVMe: the media has no sources\hwcompat.txt; original Setup. & exit /b 0)
set "USOS_SRC=%SystemDrive%\USOS-src"
if exist "%USOS_SRC%" rd /s /q "%USOS_SRC%"
echo [USOS] NVMe: %USOS_NVME_COUNT% controller(s); copying the Setup files (without the install image) to %USOS_SRC%
robocopy "%USOS_SOURCE%\sources" "%USOS_SRC%\sources" /e /r:1 /w:1 /xf install.wim install.esd install.swm boot.wim /njh /njs /nfl /ndl /np >nul
if errorlevel 8 goto nvme_setup_failed
if not exist "%USOS_SRC%\sources\setup.exe" goto nvme_setup_failed
rem boot.wim as on the proven x86 copy; without room for it Setup runs without it.
if not exist "%USOS_SOURCE%\sources\boot.wim" goto nvme_setup_hwcompat
copy /y "%USOS_SOURCE%\sources\boot.wim" "%USOS_SRC%\sources\boot.wim" >nul 2>&1
if not errorlevel 1 goto nvme_setup_hwcompat
if exist "%USOS_SRC%\sources\boot.wim" del /f /q "%USOS_SRC%\sources\boot.wim" >nul 2>&1
echo [USOS] NVMe: boot.wim not copied (RAM disk space); the copy runs without it.
:nvme_setup_hwcompat
attrib -r -h -s "%USOS_SRC%\sources\hwcompat.txt" >nul 2>&1
>>"%USOS_SRC%\sources\hwcompat.txt" echo.
>>"%USOS_SRC%\sources\hwcompat.txt" echo stornvme.inf:
>>"%USOS_SRC%\sources\hwcompat.txt" echo PCI\CC_010802
find /i "PCI\CC_010802" "%USOS_SRC%\sources\hwcompat.txt" >nul 2>&1
if errorlevel 1 goto nvme_setup_failed
rem From X: itself, as on the x86 path (a SUBST drive crashed Windows 7 Setup).
set "USOS_SETUP=%USOS_SRC%\sources\setup.exe"
set "USOS_NVME_SETUP=1"
echo [USOS] NVMe: Setup runs from %USOS_SRC%\sources\setup.exe (hwcompat.txt + PCI\CC_010802)
exit /b 0
:nvme_setup_failed
echo [USOS] NVMe WARNING: the Setup copy in %USOS_SRC% failed; original Setup (it refuses an NVMe disk).
if exist "%USOS_SRC%" rd /s /q "%USOS_SRC%"
exit /b 0

rem ---- NVMe controller: installed system's boot entry (after Setup) --------
rem KB2990941 (servicing section) brings stornvme. The first start must load
rem it for the controller before PnP runs: if Setup left no
rem CriticalDeviceDatabase entry pci#cc_010802, add it and make stornvme
rem boot-start (as the x86 path's :nvme_stornvme). Only when stornvme.sys is in
rem the new system. Never fatal.
:nvme_target
set "USOS_TARGET="
set "USOS_TARGET_COUNT=0"
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist "%%D:\Windows\Panther\setupact.log" if exist "%%D:\Windows\System32\config\SOFTWARE" call :native_res_candidate %%D
if not "%USOS_TARGET_COUNT%"=="1" (echo [USOS] NVMe WARNING: %USOS_TARGET_COUNT% new Windows installations found; stornvme boot entry not checked. & exit /b 0)
if not exist "%USOS_TARGET%:\Windows\System32\drivers\stornvme.sys" (echo [USOS] NVMe WARNING: %USOS_TARGET%: has no stornvme.sys; the NVMe packages were not installed. & exit /b 0)
reg load HKLM\USOS_SYS "%USOS_TARGET%:\Windows\System32\config\SYSTEM" >nul
if errorlevel 1 (echo [USOS] NVMe WARNING: SYSTEM hive not loaded; stornvme boot entry not checked. & exit /b 0)
set "USOS_CS="
for /f "tokens=3" %%A in ('reg query "HKLM\USOS_SYS\Select" /v Current ^| find /i "Current"') do set /a "USOS_CS=%%A"
if not defined USOS_CS set "USOS_CS=1"
set "USOS_SVC=HKLM\USOS_SYS\ControlSet00%USOS_CS%\Services\stornvme"
set "USOS_CDD=HKLM\USOS_SYS\ControlSet00%USOS_CS%\Control\CriticalDeviceDatabase\pci#cc_010802"
set "USOS_START="
for /f "tokens=3" %%A in ('reg query "%USOS_SVC%" /v Start 2^>nul ^| find /i "Start"') do set "USOS_START=%%A"
echo [USOS] NVMe: %USOS_TARGET%: stornvme service Start=%USOS_START%
reg query "%USOS_CDD%" /v Service >nul 2>&1
if not errorlevel 1 (echo [USOS] NVMe: CriticalDeviceDatabase pci#cc_010802 present. & goto nvme_target_done)
reg add "%USOS_CDD%" /v Service /t REG_SZ /d stornvme /f >nul
reg add "%USOS_CDD%" /v ClassGUID /t REG_SZ /d "{4D36E97B-E325-11CE-BFC1-08002BE10318}" /f >nul
reg add "%USOS_SVC%" /v Start /t REG_DWORD /d 0 /f >nul
echo [USOS] NVMe: CriticalDeviceDatabase pci#cc_010802 = stornvme added, stornvme Start 0.
:nvme_target_done
reg unload HKLM\USOS_SYS >nul
exit /b 0
