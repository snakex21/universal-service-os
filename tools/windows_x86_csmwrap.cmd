@echo off
rem 32-bit Windows 8.1 / 10 without firmware CSM (profile win-x86-uefi-csmwrap,
rem docs/design/csmwrap-integration.md section 11). Called by usos-start.cmd
rem after the selected ISO was mounted read-only (%USOS_SOURCE%). The ISO's own
rem x86 WinPE runs in BIOS mode (CSMWrap) from the staging partition that
rem micro-Linux step 610 wrote to the target disk.
rem
rem   1. usos-x86-csmwrap before: Windows partition active, staging hidden,
rem      WinPE letters of the prepared disk dropped, InstallTo added to the
rem      answer (the disk was confirmed in micro-Linux); the Setup version
rem      decides the product key handling (8.x / 10: Setup's own key page
rem      when the answer has none, tools/windows_installto.h);
rem   2. Setup with /noreboot;
rem   3. Windows 7 x86 only: USB 3 for the installed system (offline DISM,
rem      the user's KMDF 1.11 update and 32-bit xHCI package from DATA,
rem      design doc section 12.3); never fatal;
rem   3b. Vista / Server 2008 SP2 x86 (NT 6.0.6002) only: the Vista OOBE gate
rem      (C:\USOS\oobe.exe, x86 build of tools/windows_vista_oobe_gate.c)
rem      becomes Setup's first-boot command: WinSAT's OOBE assessment is
rem      skipped (MOOBE=2; it hung on the X470 in "mem"), an interrupted
rem      OOBE resumes without a second account, autochk stays on the system
rem      volume; never fatal (design doc section 12.5);
rem   3c. Vista / Server 2008 SP2 x86 (NT 6.0.6002) only: usosusb.sys (own
rem      xHCI keyboard / mouse port driver, tools/nt4/usosusb build-nt6)
rem      copied to system32\drivers and registered offline as a system-start
rem      "Keyboard Port" service; never fatal (design doc section 12.6);
rem   3d. NVMe target (target_bus=nvme in usos-csmwrap-target.ini), Windows
rem      7 / Vista / Server 2008 x86 only: the installed system gets an NVMe
rem      boot driver before its first start (Setup itself ran in the PE10
rem      donor, which has stornvme): NT 6.1 with the user's KB2990941 +
rem      KB3087873 x86 on DATA -> DISM /Add-Package (Microsoft stornvme);
rem      otherwise usosnvme.sys (own GPL SCSIPORT miniport, tools/nt/usosnvme)
rem      as a boot-start service with a CriticalDeviceDatabase entry for
rem      PCI\CC_010802 (docs/nvme-nt6-2026-10-12.md); never fatal;
rem   4. usos-x86-csmwrap after: boot files on the Windows partition checked,
rem      staging entry removed, "remove the stick" notice, restart.
set "USOS_SETUP=%USOS_SOURCE%\sources\setup.exe"
if not exist "%USOS_SETUP%" exit /b 1
set "USOS_ANSWER=-"
if exist "%~dp0usos-unattend.xml" set "USOS_ANSWER=%~dp0usos-unattend.xml"
if exist "%~dp0usos-unattend.xml" (echo [USOS] User answer file supplied.) else (echo [USOS] No user answer file.)
echo [USOS] phase=x86-csmwrap-before
"%~dp0usos-x86-csmwrap.exe" stick
rem NVMe target: Vista / 2008 / 7 Setup must see a driver for the disk's
rem controller that the new system can take; the helper adds this folder as
rem PnpCustomizationsWinPE DriverPaths for Setup 6.0 / 6.1 only.
set "USOS_NVME_DRIVERS="
find "target_bus=nvme" "%~dp0usos-csmwrap-target.ini" >nul 2>&1
if not errorlevel 1 if exist "%~dp0usosnvme-nt6.sys" if exist "%~dp0usosnvme.inf" (
    md "%SystemDrive%\USOS-nvme" 2>nul
    copy /y "%~dp0usosnvme-nt6.sys" "%SystemDrive%\USOS-nvme\usosnvme.sys" >nul
    copy /y "%~dp0usosnvme.inf" "%SystemDrive%\USOS-nvme\usosnvme.inf" >nul
    set "USOS_NVME_DRIVERS=%SystemDrive%\USOS-nvme"
    echo [USOS] NVMe target: usosnvme staged in %SystemDrive%\USOS-nvme for Setup.
    "%~dp0usos-x86-csmwrap.exe" nodump
)
"%~dp0usos-x86-csmwrap.exe" before "%USOS_ANSWER%" "%~dp0usos-csmwrap-unattend.xml" "%USOS_SETUP%"
if errorlevel 1 exit /b 1
echo [USOS] phase=launch-setup answer=%~dp0usos-csmwrap-unattend.xml
"%~dp0usos-log-x86.exe"
pushd "%USOS_SOURCE%\sources"
"%USOS_SETUP%" /noreboot /installfrom:"%USOS_INSTALL%" /unattend:"%~dp0usos-csmwrap-unattend.xml"
set "USOS_SETUP_RESULT=%errorlevel%"
popd
echo [USOS] phase=setup-returned exit-code=%USOS_SETUP_RESULT%
"%~dp0usos-log-x86.exe"
if not "%USOS_SETUP_RESULT%"=="0" (
    "%~dp0usos-x86-csmwrap.exe" failed
    exit /b %USOS_SETUP_RESULT%
)
call :usb3
call :nt60_gate
call :nt60_usb
call :nvme
echo [USOS] phase=finalize-target-boot
"%~dp0usos-x86-csmwrap.exe" stick
"%~dp0usos-x86-csmwrap.exe" after
set "USOS_FINALIZE_RESULT=%errorlevel%"
"%~dp0usos-log-x86.exe"
if not "%USOS_FINALIZE_RESULT%"=="0" exit /b %USOS_FINALIZE_RESULT%
echo [USOS] phase=reboot-after-success
wpeutil reboot
exit /b 0

rem ---- USB 3 for the installed 32-bit Windows 7 (section 12.3) ------------
rem Windows 7 has no xHCI driver; the X470 has only xHCI ports. From DATA:
rem   Systems\Windows\Windows 7\Updates\windows6.1-kb2864202-x86*.msu (or
rem   kb2685811-x86): KMDF 1.11, which the generic USB 3 package needs;
rem   Systems\Windows\Windows 7\Drivers\x86\: the 32-bit USB 3 package(s).
rem Both go into the installed image with this WinPE's DISM before its first
rem boot. Vista / Server 2008 (NT 6.0): this DISM cannot service them and no
rem 32-bit NT 6.0 xHCI package is known; skipped with a note.
:usb3
echo [USOS] phase=usb3-offline
set "USOS_T="
set "USOS_NT="
set "USOS_WORKDIR="
"%~dp0usos-x86-csmwrap.exe" target "%TEMP%\usos-target.txt"
if errorlevel 1 (echo [USOS] USB3: installed Windows not found; skipped. & exit /b 0)
for /f "usebackq tokens=1,2" %%A in ("%TEMP%\usos-target.txt") do (set "USOS_T=%%A" & set "USOS_NT=%%B")
if not defined USOS_NT (echo [USOS] USB3: no target record; skipped. & exit /b 0)
if "%USOS_NT%"=="6.0" (echo [USOS] USB3: Vista / Server 2008 x86 - no Microsoft-stack USB 3 driver; see the nt60-usb step. & exit /b 0)
rem Windows 8.1 / 10 x86 (profile win-x86-uefi-csmwrap) have their own xHCI driver.
if not "%USOS_NT%"=="6.1" exit /b 0
set "USOS_DATA="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if not defined USOS_DATA if /i not "%%D:"=="%USOS_T%" if exist "%%D:\Systems\Windows\Windows 7\" set "USOS_DATA=%%D:\Systems\Windows\Windows 7"
if not defined USOS_DATA (echo [USOS] USB3: DATA\Systems\Windows\Windows 7 not visible; skipped. & exit /b 0)
set "USOS_DRV=%USOS_DATA%\Drivers\x86"
set "USOS_KMDF_MSU="
for %%M in ("%USOS_DATA%\Updates\*kb2685811-x86*.msu" "%USOS_DATA%\Updates\*kb2864202-x86*.msu") do set "USOS_KMDF_MSU=%%~fM"
set "USOS_HAVE_INF="
if exist "%USOS_DRV%\" for /r "%USOS_DRV%" %%I in (*.inf) do set "USOS_HAVE_INF=1"
if not defined USOS_HAVE_INF (echo [USOS] USB3: no 32-bit package in %USOS_DRV%; skipped. & exit /b 0)
if not defined USOS_KMDF_MSU (echo [USOS] USB3: KMDF 1.11 x86 missing - put windows6.1-kb2864202-x86*.msu into %USOS_DATA%\Updates; skipped. & exit /b 0)
set "USOS_WORKDIR=%USOS_T%\USOS-usb3"
if exist "%USOS_WORKDIR%" rd /s /q "%USOS_WORKDIR%"
md "%USOS_WORKDIR%\cab"
md "%USOS_WORKDIR%\scratch"
expand.exe -F:Windows6.1-KB*-x86.cab "%USOS_KMDF_MSU%" "%USOS_WORKDIR%\cab" >nul
set "USOS_KMDF_CAB="
for %%C in ("%USOS_WORKDIR%\cab\Windows6.1-KB*-x86.cab") do set "USOS_KMDF_CAB=%%~fC"
if not defined USOS_KMDF_CAB (echo [USOS] USB3: no KMDF package inside %USOS_KMDF_MSU%; skipped. & goto usb3_done)
echo [USOS] USB3: KMDF %USOS_KMDF_CAB% into %USOS_T%
dism.exe /English /Image:%USOS_T%\ /ScratchDir:"%USOS_WORKDIR%\scratch" /LogPath:"%USOS_WORKDIR%\dism-kmdf.log" /Add-Package /PackagePath:"%USOS_KMDF_CAB%"
set "USOS_DISM=%errorlevel%"
echo [USOS] USB3: KMDF DISM exit=%USOS_DISM%
if not "%USOS_DISM%"=="0" if not "%USOS_DISM%"=="3010" (echo [USOS] USB3: KMDF not installed, so the USB 3 package would not start; skipped. & goto usb3_done)
echo [USOS] USB3: drivers %USOS_DRV%
dism.exe /English /Image:%USOS_T%\ /ScratchDir:"%USOS_WORKDIR%\scratch" /LogPath:"%USOS_WORKDIR%\dism-drivers.log" /Add-Driver /Driver:"%USOS_DRV%" /Recurse /ForceUnsigned
echo [USOS] USB3: driver DISM exit=%errorlevel%
:usb3_done
"%~dp0usos-log-x86.exe"
if exist "%USOS_WORKDIR%\scratch" rd /s /q "%USOS_WORKDIR%\scratch"
if exist "%USOS_WORKDIR%\cab" rd /s /q "%USOS_WORKDIR%\cab"
exit /b 0

rem ---- Vista / Server 2008 SP2 x86: OOBE gate (section 12.5) ---------------
rem X470 2026-10-11 (Vista SP2 PL x86, RX 560 / 5700X): the OOBE step
rem "Sprawdzanie wydajnosci komputera" = WinSAT's automatic assessment hung in
rem "mem" at 100 % CPU; after a hard reset OOBE ran again and created a second
rem account. The x64 Vista path (USB v11) has run this gate since 2026-09-21.
rem Offline, with this WinPE's reg.exe: WinSAT\MOOBE=2 (winsat moobe exits
rem before any assessment; no score is invented), the gate copied to
rem <Windows>\USOS\oobe.exe and Setup\CmdLine oobe\windeploy.exe replaced by
rem it (the gate itself hands over to windeploy).
:nt60_gate
set "USOS_T="
set "USOS_NT="
set "USOS_BUILD="
"%~dp0usos-x86-csmwrap.exe" target "%TEMP%\usos-target.txt" >nul
if errorlevel 1 exit /b 0
for /f "usebackq tokens=1,2,3" %%A in ("%TEMP%\usos-target.txt") do (set "USOS_T=%%A" & set "USOS_NT=%%B" & set "USOS_BUILD=%%C")
if not "%USOS_NT%"=="6.0" exit /b 0
echo [USOS] phase=nt60-oobe-gate build=%USOS_BUILD%
if not "%USOS_BUILD%"=="6002" (echo [USOS] OOBE gate: only for SP2 builds 6002; WinSAT left as is. & exit /b 0)
if not exist "%~dp0usos-vista-oobe-x86.exe" (echo [USOS] OOBE gate: helper missing; skipped. & exit /b 0)
set "USOS_SYSDRIVE="
reg load HKLM\USOS_SW "%USOS_T%\Windows\System32\config\SOFTWARE" >nul
if errorlevel 1 (echo [USOS] OOBE gate: SOFTWARE hive not loaded; skipped. & exit /b 0)
reg add "HKLM\USOS_SW\Microsoft\Windows NT\CurrentVersion\WinSAT" /v MOOBE /t REG_DWORD /d 2 /f >nul
echo [USOS] OOBE gate: offline WinSAT MOOBE=2 exit=%errorlevel%
for /f "tokens=2,*" %%A in ('reg query "HKLM\USOS_SW\Microsoft\Windows NT\CurrentVersion" /v SystemRoot ^| find /i "SystemRoot"') do set "USOS_SYSDRIVE=%%B"
reg unload HKLM\USOS_SW >nul
if not defined USOS_SYSDRIVE (echo [USOS] OOBE gate: SystemRoot unknown; gate not armed. & exit /b 0)
set "USOS_SYSDRIVE=%USOS_SYSDRIVE:~0,2%"
md "%USOS_T%\USOS" 2>nul
copy /y "%~dp0usos-vista-oobe-x86.exe" "%USOS_T%\USOS\oobe.exe" >nul
if errorlevel 1 (echo [USOS] OOBE gate: copy failed; gate not armed. & exit /b 0)
reg load HKLM\USOS_SYS "%USOS_T%\Windows\System32\config\SYSTEM" >nul
if errorlevel 1 (echo [USOS] OOBE gate: SYSTEM hive not loaded; gate not armed. & exit /b 0)
set "USOS_CMDLINE="
for /f "tokens=2,*" %%A in ('reg query "HKLM\USOS_SYS\Setup" /v CmdLine ^| find /i "CmdLine"') do set "USOS_CMDLINE=%%B"
if /i "%USOS_CMDLINE%"=="oobe\windeploy.exe" (
    reg add "HKLM\USOS_SYS\Setup" /v CmdLine /t REG_SZ /d "%USOS_SYSDRIVE%\USOS\oobe.exe" /f >nul
    reg add "HKLM\USOS_SYS\Setup" /v SetupType /t REG_DWORD /d 2 /f >nul
    echo [USOS] OOBE gate armed: Setup CmdLine = %USOS_SYSDRIVE%\USOS\oobe.exe
) else (
    echo [USOS] OOBE gate: unexpected Setup CmdLine "%USOS_CMDLINE%"; left unchanged.
)
reg unload HKLM\USOS_SYS >nul
"%~dp0usos-log-x86.exe"
exit /b 0

rem ---- Vista / Server 2008 SP2 x86: USB keyboard and mouse (section 12.6) --
rem NT 6.0 x86 has no xHCI driver and no Vista-capable 32-bit package exists;
rem the X470 has only xHCI ports (firmware legacy emulation through i8042
rem ended during OOBE). usosusb.sys (own GPL driver, tools/nt4/usosusb,
rem build-nt6.cmd) takes the xHCI controllers from the firmware (USBLEGSUP),
rem polls root-port HID boot keyboards / mice and feeds kbdclass / mouclass
rem as a legacy keyboard / pointer port. Offline, with this WinPE's reg.exe:
rem the driver into system32\drivers and a system-start "Keyboard Port"
rem service (loads before kbdclass / mouclass). 6.0.6002 only: Windows 7 and
rem later have a Microsoft xHCI stack (usbxhci) that must not meet it.
rem 32-bit Vista does not enforce kernel-mode signatures (x64 only).
:nt60_usb
set "USOS_T="
set "USOS_NT="
set "USOS_BUILD="
"%~dp0usos-x86-csmwrap.exe" target "%TEMP%\usos-target.txt" >nul
if errorlevel 1 exit /b 0
for /f "usebackq tokens=1,2,3" %%A in ("%TEMP%\usos-target.txt") do (set "USOS_T=%%A" & set "USOS_NT=%%B" & set "USOS_BUILD=%%C")
if not "%USOS_NT%"=="6.0" exit /b 0
echo [USOS] phase=nt60-usb build=%USOS_BUILD%
if not "%USOS_BUILD%"=="6002" (echo [USOS] usosusb: only for SP2 builds 6002; skipped. & exit /b 0)
if not exist "%~dp0usosusb-nt6.sys" (echo [USOS] usosusb: driver missing; skipped. & exit /b 0)
copy /y "%~dp0usosusb-nt6.sys" "%USOS_T%\Windows\System32\drivers\usosusb.sys" >nul
if errorlevel 1 (echo [USOS] usosusb: copy failed; skipped. & exit /b 0)
reg load HKLM\USOS_SYS "%USOS_T%\Windows\System32\config\SYSTEM" >nul
if errorlevel 1 (echo [USOS] usosusb: SYSTEM hive not loaded; skipped. & exit /b 0)
set "USOS_CS="
for /f "tokens=3" %%A in ('reg query "HKLM\USOS_SYS\Select" /v Current ^| find /i "Current"') do set /a "USOS_CS=%%A"
if not defined USOS_CS set "USOS_CS=1"
set "USOS_SVC=HKLM\USOS_SYS\ControlSet00%USOS_CS%\Services\usosusb"
reg add "%USOS_SVC%" /v Type /t REG_DWORD /d 1 /f >nul
reg add "%USOS_SVC%" /v Start /t REG_DWORD /d 1 /f >nul
reg add "%USOS_SVC%" /v ErrorControl /t REG_DWORD /d 0 /f >nul
reg add "%USOS_SVC%" /v Group /t REG_SZ /d "Keyboard Port" /f >nul
reg add "%USOS_SVC%" /v ImagePath /t REG_EXPAND_SZ /d "system32\drivers\usosusb.sys" /f >nul
reg add "%USOS_SVC%" /v DisplayName /t REG_SZ /d "USOS USB keyboard and mouse (xHCI)" /f >nul
echo [USOS] usosusb: registered in ControlSet00%USOS_CS% exit=%errorlevel%
reg unload HKLM\USOS_SYS >nul
"%~dp0usos-log-x86.exe"
exit /b 0

rem ---- NVMe target: boot driver for Windows 7 / Vista / Server 2008 x86 -----
rem Only when micro-Linux prepared an NVMe disk (target_bus=nvme): a SATA
rem install never gets a boot-start driver for a controller it may not have
rem (as for XP / NT 4.0). Windows 8.1 / 10 x86 have stornvme inbox.
rem NT 6.1: Microsoft's NVMe update (KB2990941 v3 + KB3087873 v2, x86) when
rem the user put both into DATA Systems\Windows\Windows 7\Updates (DISM, as the
rem USB 3 step); otherwise, and on NT 6.0 (DISM 10 cannot service it), our
rem usosnvme.sys (2KXP build; its imports resolve on the NT 6.0 / 6.1
rem SCSIPORT, 32-bit Windows does not enforce kernel signatures): copied to
rem system32\drivers, service Start 0 "SCSI miniport", PnpInterface\5 and the
rem CriticalDeviceDatabase entry pci#cc_010802 (class SCSIAdapter), so the
rem boot loader loads it and PnP binds the NVMe controller at the first start.
:nvme
find "target_bus=nvme" "%~dp0usos-csmwrap-target.ini" >nul 2>&1
if errorlevel 1 exit /b 0
set "USOS_T="
set "USOS_NT="
set "USOS_BUILD="
"%~dp0usos-x86-csmwrap.exe" target "%TEMP%\usos-target.txt" >nul
if errorlevel 1 (echo [USOS] NVMe: installed Windows not found; skipped. & exit /b 0)
for /f "usebackq tokens=1,2,3" %%A in ("%TEMP%\usos-target.txt") do (set "USOS_T=%%A" & set "USOS_NT=%%B" & set "USOS_BUILD=%%C")
echo [USOS] phase=nvme nt=%USOS_NT% build=%USOS_BUILD%
set "USOS_NVME_MSU="
if not "%USOS_NT%"=="6.0" if not "%USOS_NT%"=="6.1" (echo [USOS] NVMe: Windows %USOS_NT% has its own NVMe driver. & exit /b 0)
if "%USOS_NT%"=="6.1" call :nvme_msu
if "%USOS_NVME_MSU%"=="ok" (echo [USOS] NVMe: Microsoft stornvme installed; usosnvme not needed. & goto nvme_done)
if not exist "%~dp0usosnvme-nt6.sys" (echo [USOS] NVMe: usosnvme driver missing; skipped. & goto nvme_done)
copy /y "%~dp0usosnvme-nt6.sys" "%USOS_T%\Windows\System32\drivers\usosnvme.sys" >nul
if errorlevel 1 (echo [USOS] NVMe: usosnvme copy failed; skipped. & goto nvme_done)
if exist "%~dp0usosnvme.inf" copy /y "%~dp0usosnvme.inf" "%USOS_T%\Windows\inf\usosnvme.inf" >nul
reg load HKLM\USOS_SYS "%USOS_T%\Windows\System32\config\SYSTEM" >nul
if errorlevel 1 (echo [USOS] NVMe: SYSTEM hive not loaded; skipped. & goto nvme_done)
set "USOS_CS="
for /f "tokens=3" %%A in ('reg query "HKLM\USOS_SYS\Select" /v Current ^| find /i "Current"') do set /a "USOS_CS=%%A"
if not defined USOS_CS set "USOS_CS=1"
set "USOS_SVC=HKLM\USOS_SYS\ControlSet00%USOS_CS%\Services\usosnvme"
set "USOS_CDD=HKLM\USOS_SYS\ControlSet00%USOS_CS%\Control\CriticalDeviceDatabase\pci#cc_010802"
reg add "%USOS_SVC%" /v Type /t REG_DWORD /d 1 /f >nul
reg add "%USOS_SVC%" /v Start /t REG_DWORD /d 0 /f >nul
reg add "%USOS_SVC%" /v ErrorControl /t REG_DWORD /d 1 /f >nul
reg add "%USOS_SVC%" /v Group /t REG_SZ /d "SCSI miniport" /f >nul
reg add "%USOS_SVC%" /v ImagePath /t REG_EXPAND_SZ /d "system32\drivers\usosnvme.sys" /f >nul
reg add "%USOS_SVC%" /v DisplayName /t REG_SZ /d "USOS NVM Express Controller" /f >nul
reg add "%USOS_SVC%\Parameters\PnpInterface" /v 5 /t REG_DWORD /d 1 /f >nul
reg add "%USOS_CDD%" /v Service /t REG_SZ /d usosnvme /f >nul
reg add "%USOS_CDD%" /v ClassGUID /t REG_SZ /d "{4D36E97B-E325-11CE-BFC1-08002BE10318}" /f >nul
echo [USOS] NVMe: usosnvme registered in ControlSet00%USOS_CS% exit=%errorlevel%
reg unload HKLM\USOS_SYS >nul
:nvme_done
"%~dp0usos-log-x86.exe"
exit /b 0

rem NT 6.1 x86: both packages or none (KB2990941 adds stornvme, KB3087873
rem fixes it); sets USOS_NVME_MSU=ok only when DISM installed both.
:nvme_msu
set "USOS_NVME_MSU="
set "USOS_DATA="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if not defined USOS_DATA if /i not "%%D:"=="%USOS_T%" if exist "%%D:\Systems\Windows\Windows 7\" set "USOS_DATA=%%D:\Systems\Windows\Windows 7"
if not defined USOS_DATA exit /b 0
set "USOS_MSU1="
set "USOS_MSU2="
for %%M in ("%USOS_DATA%\Updates\*kb2990941*x86*.msu") do set "USOS_MSU1=%%~fM"
for %%M in ("%USOS_DATA%\Updates\*kb3087873*x86*.msu") do set "USOS_MSU2=%%~fM"
if not defined USOS_MSU1 (echo [USOS] NVMe: no windows6.1-kb2990941-v3-x86.msu in %USOS_DATA%\Updates; using usosnvme. & exit /b 0)
if not defined USOS_MSU2 (echo [USOS] NVMe: no windows6.1-kb3087873-v2-x86.msu in %USOS_DATA%\Updates; using usosnvme. & exit /b 0)
set "USOS_WORKDIR=%USOS_T%\USOS-nvme"
if exist "%USOS_WORKDIR%" rd /s /q "%USOS_WORKDIR%"
md "%USOS_WORKDIR%\cab"
md "%USOS_WORKDIR%\scratch"
expand.exe -F:Windows6.1-KB*-x86.cab "%USOS_MSU1%" "%USOS_WORKDIR%\cab" >nul
expand.exe -F:Windows6.1-KB*-x86.cab "%USOS_MSU2%" "%USOS_WORKDIR%\cab" >nul
set "USOS_NVME_OK=0"
for %%C in ("%USOS_WORKDIR%\cab\Windows6.1-KB2990941*-x86.cab" "%USOS_WORKDIR%\cab\Windows6.1-KB3087873*-x86.cab") do (
    echo [USOS] NVMe: %%~nxC into %USOS_T%
    dism.exe /English /Image:%USOS_T%\ /ScratchDir:"%USOS_WORKDIR%\scratch" /LogPath:"%USOS_WORKDIR%\dism-%%~nC.log" /Add-Package /PackagePath:"%%~fC"
    if not errorlevel 1 set /a "USOS_NVME_OK+=1"
    if errorlevel 3010 if not errorlevel 3011 set /a "USOS_NVME_OK+=1"
)
echo [USOS] NVMe: Microsoft packages installed=%USOS_NVME_OK% of 2
if "%USOS_NVME_OK%"=="2" set "USOS_NVME_MSU=ok"
if exist "%USOS_WORKDIR%\scratch" rd /s /q "%USOS_WORKDIR%\scratch"
if exist "%USOS_WORKDIR%\cab" rd /s /q "%USOS_WORKDIR%\cab"
exit /b 0
