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
rem   3e. Windows 7 / 8.x / 10 before 1703 x86 (NT 6.1 to 10.0.14393):
rem      usosmpart.sys (own GPL USB multi-partition disk filter,
rem      tools/nt/usosmpart) copied to system32\drivers and registered offline
rem      as a boot-start disk class lower filter, so every partition of a USB
rem      stick gets a letter (Windows before 10 1703 mounts only the first
rem      one of removable media); never fatal (:mpart);
rem   0. NVMe target (target_bus=nvme in usos-csmwrap-target.ini), Setup 6.0 /
rem      6.1: Setup runs from a copy of the media's sources folder whose
rem      hwcompat.txt lists PCI\CC_010802 (:nvme_setup);
rem   3d. NVMe target, Windows
rem      7 / Vista / Server 2008 x86 only: the installed system gets an NVMe
rem      boot driver before its first start (Setup itself ran in the PE10
rem      donor, whose stornvme service runs usosnvme on an NVMe target):
rem      usosnvme.sys (own GPL SCSIPORT miniport, tools/nt/usosnvme)
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
rem NVMe target, Setup 6.0 / 6.1 (Vista / 2008 / 7): see :nvme_setup.
set "USOS_NVME_TARGET="
find "target_bus=nvme" "%~dp0usos-csmwrap-target.ini" >nul 2>&1 && set "USOS_NVME_TARGET=1"
rem NVMe target: the WinPE must not use RAM above 4 GiB (corrupt image apply
rem through stornvme, QEMU 2026-10-13); "lowmem" limits the staging BCD and
rem the WinPE restarts once (docs/nvme-nt6-2026-10-12.md section 10).
if defined USOS_NVME_TARGET call :nvme_pe_driver
if defined USOS_NVME_TARGET call :nvme_lowmem
if defined USOS_NVME_TARGET if "%USOS_LOWMEM%"=="10" exit /b 0
if defined USOS_NVME_TARGET call :nvme_setup
if defined USOS_NVME_TARGET if errorlevel 1 exit /b 1
"%~dp0usos-x86-csmwrap.exe" before "%USOS_ANSWER%" "%~dp0usos-csmwrap-unattend.xml" "%USOS_SETUP%"
set "USOS_BEFORE_RESULT=%errorlevel%"
if "%USOS_BEFORE_RESULT%"=="4" call :disk_report
if not "%USOS_BEFORE_RESULT%"=="0" exit /b 1
echo [USOS] phase=launch-setup answer=%~dp0usos-csmwrap-unattend.xml
"%~dp0usos-log-x86.exe"
for %%S in ("%USOS_SETUP%") do pushd "%%~dpS"
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
call :mpart
echo [USOS] phase=finalize-target-boot
"%~dp0usos-x86-csmwrap.exe" stick
"%~dp0usos-x86-csmwrap.exe" after
set "USOS_FINALIZE_RESULT=%errorlevel%"
"%~dp0usos-log-x86.exe"
if not "%USOS_FINALIZE_RESULT%"=="0" exit /b %USOS_FINALIZE_RESULT%
echo [USOS] phase=reboot-after-success
wpeutil reboot
exit /b 0

rem ---- the prepared disk was not found ("before" exit 4) -------------------
rem X470 2026-10-13 (B261013-184439, Windows 7 x86 to an NVMe disk): the log
rem said only "disks with the prepared MBR signature=0". Read-only report into
rem the startup log (EFI\USOS\Logs on the stick): diskpart's disk and volume
rem lists, and the storage controllers and disks with their PnP state and
rem problem codes (pnputil /enum-devices, Windows 10 2004+ PE; wmic when the
rem PE has it). Nothing is selected or changed.
:disk_report
echo [USOS] phase=x86-csmwrap-disk-report
set "USOS_DP_SCRIPT=%TEMP%\usos-diskpart-list.txt"
> "%USOS_DP_SCRIPT%" echo list disk
>> "%USOS_DP_SCRIPT%" echo list volume
echo [USOS] diskpart: list disk, list volume
diskpart /s "%USOS_DP_SCRIPT%"
set "USOS_PNPUTIL=%SystemRoot%\System32\pnputil.exe"
if not exist "%USOS_PNPUTIL%" echo [USOS] pnputil.exe is not in this WinPE.
if exist "%USOS_PNPUTIL%" for %%C in (SCSIAdapter HDC DiskDrive) do (
    echo [USOS] pnputil /enum-devices /class %%C
    "%USOS_PNPUTIL%" /enum-devices /class %%C
)
if exist "%USOS_PNPUTIL%" echo [USOS] pnputil /enum-devices /problem
if exist "%USOS_PNPUTIL%" "%USOS_PNPUTIL%" /enum-devices /problem
set "USOS_WMIC=%SystemRoot%\System32\wbem\wmic.exe"
if not exist "%USOS_WMIC%" goto disk_report_done
echo [USOS] wmic: storage controllers, disks and devices with a problem code
"%USOS_WMIC%" path Win32_PnPEntity where "PNPClass='SCSIAdapter' or PNPClass='HDC' or PNPClass='DiskDrive' or ConfigManagerErrorCode<>0" get Name,PNPClass,Service,ConfigManagerErrorCode,DeviceID /format:list
:disk_report_done
rem stornvme / StorPort / disk events of this WinPE boot (resets, timeouts,
rem controller fatal status, surprise removal; X470 2026-10-13 had none in
rem the log), oldest first, when the PE has wevtutil.
set "USOS_WEVTUTIL=%SystemRoot%\System32\wevtutil.exe"
if not exist "%USOS_WEVTUTIL%" echo [USOS] wevtutil.exe is not in this WinPE.
if exist "%USOS_WEVTUTIL%" echo [USOS] wevtutil: System log, stornvme / storport / disk
if exist "%USOS_WEVTUTIL%" "%USOS_WEVTUTIL%" qe System /q:"*[System[Provider[@Name='stornvme' or @Name='storport' or @Name='disk' or @Name='Microsoft-Windows-StorPort']]]" /f:text /c:50
"%~dp0usos-log-x86.exe"
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

rem ---- NVMe target: which driver runs the controller in this WinPE ---------
rem micro-Linux (vista_csmwrap_target.sh, NVMe target, NT6 x86 donor) put
rem usosnvme (polled, own GPL SCSIPORT miniport) into the PE image as
rem drivers\stornvme.sys, so the boot-start stornvme service of the PE runs
rem usosnvme from the first boot and Microsoft's stornvme never touches the
rem controller (X470 2026-10-13: 433 + controller off PCI). The service and
rem its INF stay stornvme.inf for Setup's hwcompat check (:nvme_setup), so
rem nothing is injected or migrated. Logged here: file sizes (equal = the
rem replacement is in place) and the controller's PnP state; the crash-dump
rem stack (dump_stornvme = this image) is switched off first.
:nvme_pe_driver
"%~dp0usos-x86-csmwrap.exe" nodump
set "USOS_PE_NVME=%SystemRoot%\System32\drivers\stornvme.sys"
set "USOS_PE_NVME_SIZE="
set "USOS_OWN_NVME_SIZE="
for %%F in ("%USOS_PE_NVME%") do set "USOS_PE_NVME_SIZE=%%~zF"
for %%F in ("%~dp0usosnvme-nt6.sys") do set "USOS_OWN_NVME_SIZE=%%~zF"
if "%USOS_PE_NVME_SIZE%"=="%USOS_OWN_NVME_SIZE%" (echo [USOS] NVMe target: the WinPE stornvme service runs usosnvme ^(stornvme.sys = usosnvme-nt6.sys, %USOS_PE_NVME_SIZE% bytes^).) else (echo [USOS] NVMe target: WARNING the WinPE stornvme.sys is not usosnvme ^(%USOS_PE_NVME_SIZE% vs %USOS_OWN_NVME_SIZE% bytes^): Microsoft stornvme runs the controller.)
if exist "%SystemRoot%\System32\pnputil.exe" "%SystemRoot%\System32\pnputil.exe" /enum-devices /class SCSIAdapter
"%~dp0usos-log-x86.exe"
exit /b 0

rem ---- NVMe target: WinPE below 4 GiB --------------------------------------
rem Result: 0 nothing to do (no RAM above 4 GiB, or the limit is already in
rem the BCD: the second boot), 10 limit written (restart), 1 error, 4 the
rem prepared disk was not found (stornvme without a usable disk, X470
rem 2026-10-13): the disk report then runs here too, before nodump and the
rem Setup copy, and again after "before" (two snapshots for the log).
:nvme_lowmem
"%~dp0usos-x86-csmwrap.exe" lowmem
set "USOS_LOWMEM=%errorlevel%"
echo [USOS] NVMe target: lowmem result=%USOS_LOWMEM%
if "%USOS_LOWMEM%"=="4" call :disk_report
"%~dp0usos-log-x86.exe"
if not "%USOS_LOWMEM%"=="10" exit /b 0
echo [USOS] phase=reboot-lowmem
wpeutil reboot
exit /b 0

rem ---- NVMe target: Setup 6.0 / 6.1 disk check (before Setup) --------------
rem Vista / 2008 / 7 Setup looks up the disk's controller (PCI\CC_010802, run
rem by the donor's inbox stornvme) in sources\hwcompat.txt of the media, which
rem predates NVMe, and refuses the disk ("Windows needs the driver for
rem [Standard NVM Express controller]"). A driver injected into the PE to pass
rem the check (PnpCustomizationsWinPE) must then be migrated by Setup through
rem the Windows 10 offline driver store, which refuses NT 6.0 / 6.1 images
rem (0x80070032, QEMU 2026-10-12; docs/nvme-nt6-2026-10-12.md). Instead Setup
rem runs from a copy of the media's sources folder (install.wim stays on the
rem ISO, /installfrom) in the WinPE RAM disk whose hwcompat.txt also lists
rem the NVMe class code; nothing is injected or migrated, and the installed
rem system gets its NVMe boot driver in :nvme after Setup. The copy is reached
rem through a SUBST drive: Vista Setup started from the system drive (X:)
rem treats itself as booted Setup media, looks for a DVD and asks for a
rem "CD/DVD driver" (QEMU 2026-10-13, Server 2008 SP2 x86); it also needs
rem sources\boot.wim next to setup.exe (copied, ~140 MB; WinPE has no
rem symbolic links on X:).
:nvme_setup
"%~dp0usos-x86-csmwrap.exe" setupver "%USOS_SETUP%"
set "USOS_SETUPVER=%errorlevel%"
if not "%USOS_SETUPVER%"=="60" if not "%USOS_SETUPVER%"=="61" (echo [USOS] NVMe target: Setup version code %USOS_SETUPVER%, no hwcompat change needed. & exit /b 0)
set "USOS_SRC=%SystemDrive%\USOS-src"
if exist "%USOS_SRC%" rd /s /q "%USOS_SRC%"
echo [USOS] NVMe target: copying the Setup files (without install.wim) to %USOS_SRC%
robocopy "%USOS_SOURCE%\sources" "%USOS_SRC%\sources" /e /r:1 /w:1 /xf install.wim install.esd install.swm /njh /njs /nfl /ndl /np >nul
if errorlevel 8 (echo [USOS] NVMe target: copying the Setup files to %USOS_SRC% failed; Setup would refuse the NVMe disk. & exit /b 1)
if not exist "%USOS_SRC%\sources\setup.exe" (echo [USOS] NVMe target: %USOS_SRC%\sources\setup.exe missing after the copy. & exit /b 1)
attrib -r -h -s "%USOS_SRC%\sources\hwcompat.txt" >nul 2>&1
>>"%USOS_SRC%\sources\hwcompat.txt" echo.
>>"%USOS_SRC%\sources\hwcompat.txt" echo stornvme.inf:
>>"%USOS_SRC%\sources\hwcompat.txt" echo PCI\CC_010802
find /i "PCI\CC_010802" "%USOS_SRC%\sources\hwcompat.txt" >nul 2>&1
if errorlevel 1 (echo [USOS] NVMe target: hwcompat.txt could not be extended. & exit /b 1)
rem Setup 6.1 runs from X:\USOS-src itself: from the SUBST drive Windows 7
rem Setup hit an access violation in WinSetup.dll right after the image
rem apply (QEMU 2026-10-13); from X: it went on through "Installing
rem features". Vista / 2008 (6.0) need the SUBST drive (see above).
set "USOS_SETUP=%USOS_SRC%\sources\setup.exe"
if "%USOS_SETUPVER%"=="61" goto nvme_setup_ready
set "USOS_SUBST="
for %%L in (Z Y W V U R Q P O N M L K J I H) do if not defined USOS_SUBST if not exist %%L:\ (subst %%L: "%USOS_SRC%" >nul 2>&1 && set "USOS_SUBST=%%L:")
if not defined USOS_SUBST (echo [USOS] NVMe target: no free drive letter for the Setup copy. & exit /b 1)
if not exist "%USOS_SUBST%\sources\setup.exe" (echo [USOS] NVMe target: %USOS_SUBST% does not show the Setup copy. & exit /b 1)
set "USOS_SETUP=%USOS_SUBST%\sources\setup.exe"
:nvme_setup_ready
rem The donor booted from the NVMe staging partition, so its crash-dump
rem stack (dump_stornvme) is armed for the controller; once Setup works on
rem the disk it bugchecked there (KMODE_EXCEPTION_NOT_HANDLED, "What failed:
rem dump_stornvme.sys", QEMU 2026-10-13 Windows 7 + Server 2008 x86). Off.
"%~dp0usos-x86-csmwrap.exe" nodump
echo [USOS] NVMe target: Setup %USOS_SETUPVER% runs from %USOS_SETUP% = %USOS_SRC% (hwcompat.txt + PCI\CC_010802)
"%~dp0usos-log-x86.exe"
exit /b 0

rem ---- NVMe target: boot driver for Windows 7 / Vista / Server 2008 x86 -----
rem Only when micro-Linux prepared an NVMe disk (target_bus=nvme): a SATA
rem install never gets a boot-start driver for a controller it may not have
rem (as for XP / NT 4.0). Windows 8.1 / 10 x86 have stornvme inbox.
rem NT 6.0 / 6.1: usosnvme.sys (2KXP build; its imports resolve on the NT 6.0 /
rem 6.1 SCSIPORT, 32-bit Windows does not enforce kernel signatures; the same
rem driver ran the controller in the PE, :nvme_pe_driver): copied to
rem system32\drivers, service Start 0 "SCSI miniport", PnpInterface\5 and the
rem CriticalDeviceDatabase entry pci#cc_010802 (class SCSIAdapter), so the
rem boot loader loads it and PnP binds the NVMe controller at the first start;
rem the signed package is staged for specialize (6.0: OOBE gate, 6.1: DISM).
rem The KB2990941 / KB3087873 x86 MSUs are not used (user decision 2026-10-14).
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
rem User decision 2026-10-14: no Microsoft stornvme for 32-bit NT6 on NVMe
rem (it failed on the X470 Micron in the PE, docs/nvme-nt6-2026-10-12.md
rem section 12); the polled usosnvme serves the disk in the PE and in the
rem installed system. :nvme_msu (KB2990941 / KB3087873 x86) stays, unused.
if not exist "%~dp0usosnvme-nt6.sys" (echo [USOS] NVMe: usosnvme driver missing; skipped. & goto nvme_done)
copy /y "%~dp0usosnvme-nt6.sys" "%USOS_T%\Windows\System32\drivers\usosnvme.sys" >nul
if errorlevel 1 (echo [USOS] NVMe: usosnvme copy failed; skipped. & goto nvme_done)
rem The signed package (per-build certificate, key destroyed at build time)
rem for the driver store: on 6.0 the OOBE gate trusts usosnvme.cer (machine
rem Root + TrustedPublisher) and stages it with pnputil before specialize, so
rem specialize installs usosnvme instead of the NULL driver (STOP 0x7B
rem otherwise, docs/nvme-nt6-2026-10-12.md sections 8-9). Not in
rem Windows\inf: an unstaged INF there is skipped anyway.
md "%USOS_T%\USOS\nvme" 2>nul
for %%F in (usosnvme.inf usosnvme.cat usosnvme.cer) do if exist "%~dp0%%F" copy /y "%~dp0%%F" "%USOS_T%\USOS\nvme\%%F" >nul
copy /y "%~dp0usosnvme-nt6.sys" "%USOS_T%\USOS\nvme\usosnvme.sys" >nul
if exist "%USOS_T%\USOS\nvme\usosnvme.cat" (echo [USOS] NVMe: signed usosnvme package in %USOS_T%\USOS\nvme for the driver store.) else (echo [USOS] NVMe: usosnvme catalog missing; specialize may install the NULL driver.)
rem NT 6.1 has no OOBE gate: the package goes into the offline driver store
rem with this WinPE's DISM (it services 6.1 images, as in the USB 3 step), so
rem specialize finds a published usosnvme.inf for the controller instead of
rem installing the NULL driver (the NT 6.0 0x7B of section 8). Windows 7 has
rem no inbox NVMe driver, so usosnvme is the only match. The service and CDD
rem entries below are written either way.
if "%USOS_NT%"=="6.1" call :nvme_dism
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
goto nvme_done
rem KB2990941 brings stornvme; the first start must load it for the
rem controller before PnP runs. DISM's offline driver install normally adds
rem the CriticalDeviceDatabase entry for a boot-critical class; if it is
rem missing, add it and make stornvme boot-start (logged either way).
:nvme_stornvme
reg load HKLM\USOS_SYS "%USOS_T%\Windows\System32\config\SYSTEM" >nul
if errorlevel 1 (echo [USOS] NVMe: SYSTEM hive not loaded; stornvme boot entry not checked. & goto nvme_done)
set "USOS_CS="
for /f "tokens=3" %%A in ('reg query "HKLM\USOS_SYS\Select" /v Current ^| find /i "Current"') do set /a "USOS_CS=%%A"
if not defined USOS_CS set "USOS_CS=1"
set "USOS_SVC=HKLM\USOS_SYS\ControlSet00%USOS_CS%\Services\stornvme"
set "USOS_CDD=HKLM\USOS_SYS\ControlSet00%USOS_CS%\Control\CriticalDeviceDatabase\pci#cc_010802"
set "USOS_START="
for /f "tokens=3" %%A in ('reg query "%USOS_SVC%" /v Start 2^>nul ^| find /i "Start"') do set "USOS_START=%%A"
echo [USOS] NVMe: stornvme service Start=%USOS_START%
reg query "%USOS_CDD%" /v Service >nul 2>&1
if not errorlevel 1 (echo [USOS] NVMe: CriticalDeviceDatabase pci#cc_010802 present. & goto nvme_stornvme_done)
reg add "%USOS_CDD%" /v Service /t REG_SZ /d stornvme /f >nul
reg add "%USOS_CDD%" /v ClassGUID /t REG_SZ /d "{4D36E97B-E325-11CE-BFC1-08002BE10318}" /f >nul
reg add "%USOS_SVC%" /v Start /t REG_DWORD /d 0 /f >nul
echo [USOS] NVMe: CriticalDeviceDatabase pci#cc_010802 -^> stornvme added, Start=0 exit=%errorlevel%
:nvme_stornvme_done
reg unload HKLM\USOS_SYS >nul
:nvme_done
"%~dp0usos-log-x86.exe"
exit /b 0

:nvme_dism
set "USOS_WORKDIR=%USOS_T%\USOS-nvme"
if exist "%USOS_WORKDIR%" rd /s /q "%USOS_WORKDIR%"
md "%USOS_WORKDIR%\scratch"
dism.exe /English /Image:%USOS_T%\ /ScratchDir:"%USOS_WORKDIR%\scratch" /LogPath:"%USOS_T%\USOS\nvme\dism-usosnvme.log" /Add-Driver /Driver:"%USOS_T%\USOS\nvme\usosnvme.inf" /ForceUnsigned
echo [USOS] NVMe: usosnvme.inf into the offline driver store (DISM) exit=%errorlevel%
dism.exe /English /Image:%USOS_T%\ /ScratchDir:"%USOS_WORKDIR%\scratch" /Get-Drivers | find /i "usosnvme"
if exist "%USOS_WORKDIR%" rd /s /q "%USOS_WORKDIR%"
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

rem ---- Windows 7 / 8.x / 10 before 1703 x86: every USB stick partition ------
rem Windows before 10 1703 mounts only the first partition of a disk that
rem reports removable media (most sticks; the USOS stick shows only its ESP).
rem usosmpart.sys (own GPL disk class lower filter, tools/nt/usosmpart)
rem attaches only to USBSTOR disks and lets a stick with more than one
rem partition start like a USB hard disk; hot plug, safe removal and the
rem quick-removal write policy stay (tools/nt/usosmpart/README.md). Offline,
rem with this WinPE's reg.exe: the file into system32\drivers, a boot-start
rem service (group "Filter") and usosmpart appended to the disk class
rem LowerFilters (Windows 7+ already lists EhStorClass there). Vista / 2008
rem x86 (NT 6.0) are skipped: usosusb owns their xHCI and mounts every
rem partition itself. 32-bit Windows does not enforce kernel signatures.
:mpart
set "USOS_T="
set "USOS_NT="
set "USOS_BUILD="
"%~dp0usos-x86-csmwrap.exe" target "%TEMP%\usos-target.txt" >nul
if errorlevel 1 exit /b 0
for /f "usebackq tokens=1,2,3" %%A in ("%TEMP%\usos-target.txt") do (set "USOS_T=%%A" & set "USOS_NT=%%B" & set "USOS_BUILD=%%C")
if not "%USOS_NT%"=="6.1" if not "%USOS_NT%"=="6.2" if not "%USOS_NT%"=="6.3" if not "%USOS_NT%"=="10.0" exit /b 0
if "%USOS_NT%"=="10.0" if "%USOS_BUILD%"=="" exit /b 0
if "%USOS_NT%"=="10.0" if %USOS_BUILD% GEQ 15063 (echo [USOS] usosmpart: Windows 10 build %USOS_BUILD% mounts every USB stick partition itself; skipped. & exit /b 0)
echo [USOS] phase=mpart nt=%USOS_NT% build=%USOS_BUILD%
if not exist "%~dp0usosmpart-x86.sys" (echo [USOS] usosmpart: driver missing; skipped. & exit /b 0)
copy /y "%~dp0usosmpart-x86.sys" "%USOS_T%\Windows\System32\drivers\usosmpart.sys" >nul
if errorlevel 1 (echo [USOS] usosmpart: copy failed; skipped. & exit /b 0)
rem Readback through the helper: this WinPE has no fc.exe (nor findstr).
"%~dp0usos-x86-csmwrap.exe" samefile "%~dp0usosmpart-x86.sys" "%USOS_T%\Windows\System32\drivers\usosmpart.sys" >nul
if errorlevel 1 (echo [USOS] usosmpart: readback mismatch; not registered. & del "%USOS_T%\Windows\System32\drivers\usosmpart.sys" & exit /b 0)
reg load HKLM\USOS_SYS "%USOS_T%\Windows\System32\config\SYSTEM" >nul
if errorlevel 1 (echo [USOS] usosmpart: SYSTEM hive not loaded; skipped. & exit /b 0)
set "USOS_CS="
for /f "tokens=3" %%A in ('reg query "HKLM\USOS_SYS\Select" /v Current ^| find /i "Current"') do set /a "USOS_CS=%%A"
if not defined USOS_CS set "USOS_CS=1"
set "USOS_SVC=HKLM\USOS_SYS\ControlSet00%USOS_CS%\Services\usosmpart"
set "USOS_CLS=HKLM\USOS_SYS\ControlSet00%USOS_CS%\Control\Class\{4D36E967-E325-11CE-BFC1-08002BE10318}"
call :mpart_reg
reg unload HKLM\USOS_SYS >nul
"%~dp0usos-log-x86.exe"
exit /b 0

rem The registry rows of :mpart (USOS_SVC, USOS_CLS set by the caller; also
rem usable on a running system with HKLM\SYSTEM\CurrentControlSet paths).
:mpart_reg
reg add "%USOS_SVC%" /v Type /t REG_DWORD /d 1 /f >nul
reg add "%USOS_SVC%" /v Start /t REG_DWORD /d 0 /f >nul
reg add "%USOS_SVC%" /v ErrorControl /t REG_DWORD /d 1 /f >nul
reg add "%USOS_SVC%" /v Group /t REG_SZ /d "Filter" /f >nul
reg add "%USOS_SVC%" /v ImagePath /t REG_EXPAND_SZ /d "system32\drivers\usosmpart.sys" /f >nul
reg add "%USOS_SVC%" /v DisplayName /t REG_SZ /d "USOS USB multi-partition disk filter" /f >nul
set "USOS_LF="
for /f "tokens=2,*" %%A in ('reg query "%USOS_CLS%" /v LowerFilters 2^>nul ^| find /i "LowerFilters"') do set "USOS_LF=%%B"
echo [USOS] usosmpart: disk class LowerFilters before: "%USOS_LF%"
echo "\0%USOS_LF%\0" | find /i "\0usosmpart\0" >nul
if not errorlevel 1 goto mpart_listed
if defined USOS_LF (reg add "%USOS_CLS%" /v LowerFilters /t REG_MULTI_SZ /d "%USOS_LF%\0usosmpart" /f >nul) else (reg add "%USOS_CLS%" /v LowerFilters /t REG_MULTI_SZ /d "usosmpart" /f >nul)
:mpart_listed
set "USOS_LF="
for /f "tokens=2,*" %%A in ('reg query "%USOS_CLS%" /v LowerFilters 2^>nul ^| find /i "LowerFilters"') do set "USOS_LF=%%B"
echo [USOS] usosmpart: service registered, disk class LowerFilters now: "%USOS_LF%"
exit /b 0
