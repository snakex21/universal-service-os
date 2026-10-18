@ECHO OFF
REM Two modes. BIOS Core (MEMDISK RAM disk A: with DOS, Setup folder and
REM helpers): U9ENV.BAT is on A:. Disk mode (U9DISK=1, prepared from UEFI by
REM tools/w9x_csmwrap_target.sh): A: is the CD boot floppy, the Setup folder
REM and the helpers are already on C:, its AUTOEXEC.BAT called U9ENV.BAT.
IF NOT "%U9DISK%"=="1" CALL A:\U9ENV.BAT
IF "%U9T%"=="" SET U9T=A:
PATH=A:\;%U9T%\;A:\%U9SRC%
CLS
ECHO USOS - Windows %U9SYS%
ECHO Przygotowanie wybranego dysku. Nie wylaczaj komputera.
REM 98/Me startup floppies keep SYS/ATTRIB in EBD.CAB; 95 disks have them loose.
REM U9X: where they are (the 1.44 MB floppy of the disk mode has no room).
SET U9X=A:
IF NOT EXIST A:\EBD.CAB GOTO EBDDONE
IF NOT "%U9DISK%"=="1" GOTO EBDRAM
MD C:\USOS9X\EBD
SET U9X=C:\USOS9X\EBD
:EBDRAM
A:\EXTRACT.EXE /Y /E /L %U9X%\ A:\EBD.CAB >NUL
IF ERRORLEVEL 1 GOTO FAILED
:EBDDONE
REM The Me SYS only repairs an installed C: (it refuses a new disk); Me Setup
REM makes C: bootable itself (and writes its own MSDOS.SYS).
IF "%U9SYS%"=="ME" GOTO SYSDONE
%U9X%\SYS.COM C:
IF ERRORLEVEL 1 GOTO FAILED
REM Text boot instead of the logo (Setup keeps the line): start messages stay
REM visible, and the logo hangs QEMU's SMM path. SYS wrote MSDOS.SYS.
%U9X%\ATTRIB.EXE -H -S -R C:\MSDOS.SYS
ECHO [Options]>>C:\MSDOS.SYS
ECHO Logo=0>>C:\MSDOS.SYS
REM No forced startup menu on normal boots (Windows still shows it by itself
REM after an unclean shutdown or a failed start).
ECHO BootMenu=0>>C:\MSDOS.SYS
REM After a failed start the menu defaults to Normal, not Safe mode: safe
REM mode loads HIMEM without /M:2 and hangs under CSMWrap.
ECHO BootMenuDefault=1>>C:\MSDOS.SYS
%U9X%\ATTRIB.EXE +H +S +R C:\MSDOS.SYS
:SYSDONE
REM Disk mode: the one-time syslinux start goes (98/95: SYS replaced its boot
REM sector; Me Setup writes its own).
IF NOT "%U9DISK%"=="1" GOTO SLDONE
%U9X%\ATTRIB.EXE -H -S -R C:\LDLINUX.SYS
DEL C:\LDLINUX.SYS
%U9X%\ATTRIB.EXE -H -S -R C:\LDLINUX.C32
DEL C:\LDLINUX.C32
DEL C:\SYSLINUX.CFG
GOTO COPYDONE
:SLDONE
MD C:\%U9SRC%
ECHO Kopiowanie plikow instalacyjnych na dysk...
COPY /Y A:\%U9SRC%\*.* C:\%U9SRC% >NUL
IF ERRORLEVEL 1 GOTO FAILED
MD C:\USOS9X
COPY /Y A:\U9FIX.COM C:\USOS9X >NUL
IF ERRORLEVEL 1 GOTO FAILED
COPY /Y A:\U9FIX.TXT C:\USOS9X >NUL
IF ERRORLEVEL 1 GOTO FAILED
COPY /Y A:\VMDISP9X.TXT C:\USOS9X >NUL
FOR %%F IN (USOSKEY.COM USOSKEY.DRV USOSMOUS.DRV VBMOUSE.EXE VBMOUSE.DRV VBADOS.TXT CREGFIX.SYS) DO COPY /Y A:\%%F C:\USOS9X >NUL
:COPYDONE
REM Step markers for a hang on real hardware: the last line shows the step.
ECHO start %U9SYS% (U9CSM=%U9CSM% U9DISK=%U9DISK% U9VM=%U9VM%)>>C:\USOS9X\INSTALL.LOG
IF NOT EXIST C:\%U9SRC%\SETUP.EXE GOTO FAILED
COPY /Y %U9T%\MSBATCH.INF C:\%U9SRC%\MSBATCH.INF >NUL
IF ERRORLEVEL 1 GOTO FAILED
REM VESA display driver (vmdisp9x, MIT) next to Setup: DevicePath=1 finds it.
FOR %%F IN (USOSVESA.INF VESAMINI.DRV VESAMINI.VXD VMHAL9X.DLL) DO COPY /Y %U9T%\%%F C:\%U9SRC% >NUL
FOR %%F IN (VMHAL486.DLL VMDISP9X.DLL) DO COPY /Y %U9T%\%%F C:\%U9SRC% >NUL
IF NOT EXIST C:\%U9SRC%\VMDISP9X.DLL GOTO FAILED
REM Hardware IDs of this PC's display cards: they outrank Standard VGA.
%U9T%\U9FIX.COM /VGA C:\%U9SRC%\USOSVESA.INF
REM 98 SE under CSMWrap: native USB keyboard and mouse through xhci98 (USOS
REM build, polling) on the user's USB 2.0 stack (DATA Drivers\Windows 98
REM SE\USB: the NUSB installer, whose cabinet the UEFI preparation saved as
REM C:\USOS9X\USB\STACK.CAB). XHCI98.INF takes usbport.sys/usbhub20.sys from
REM that cabinet (LZX: Setup unpacks it, DOS EXTRACT cannot) and binds the
REM controller and the USB 2.0 root hub, so Setup's device detection installs
REM them and the HID devices without a prompt. No stack: bridge only.
REM Opt-in (U9USB=1, EFI\USOS\win9x\xhci98.flag): on the X470 xhci98 takes
REM the controller from SeaBIOS, the bridge dies and native HID does not
REM work yet. Default: bridge only, XHCI98.* never reaches the Setup folder.
IF NOT "%U9USB%"=="1" GOTO USBDONE
IF NOT "%U9CSM%"=="1" GOTO USBDONE
IF NOT "%U9SYS%"=="98SE" GOTO USBDONE
IF NOT EXIST C:\USOS9X\USB\STACK.CAB GOTO USBDONE
IF NOT EXIST %U9T%\XHCI98.SYS GOTO USBDONE
ECHO Natywne USB (xhci98 + stos USB 2.0)...
FOR %%F IN (XHCI98.SYS XHCI98.INF USB\STACK.CAB) DO COPY /Y %U9T%\%%F C:\%U9SRC% >NUL
:USBDONE
REM NVMe target with usosnvme chosen (U9NVME=1, tools/w9x_nvme.sh): the 9x
REM miniport next to Setup. A Setup that sees the controller binds it here;
REM after a VM phase 1 the UEFI side copies both into C:\WINDOWS and this
REM folder is the INF's copy source at the first start on the real PC.
IF NOT "%U9NVME%"=="1" GOTO NVMEDONE
IF NOT EXIST %U9T%\USOSNVME.MPD GOTO NVMEDONE
FOR %%F IN (USOSNVME.INF USOSNVME.MPD) DO COPY /Y %U9T%\%%F C:\%U9SRC% >NUL
:NVMEDONE
REM Under CSMWrap HIMEM needs A20 through port 92h (/M:2), else DOS=HIGH hangs.
REM Setup keeps the lines. C:\WINDOWS\HIMEM.SYS exists from Setup's first
REM restart on; until then (a restart before Setup got that far) the copy of
REM the boot floppy's HIMEM in C:\USOS9X loads instead, so RESUME.BAT can run
REM Setup again (Setup needs XMS). Once the first one loaded, the second one
REM only reports that an XMS driver is already there.
REM U9VM=1 (phase 1 in USOS's QEMU): C: first boots after that phase wrote
REM C:\WINDOWS\HIMEM.SYS, and Setup turns the C:\USOS9X line into a second
REM C:\WINDOWS\HIMEM.SYS line, so that path gets no fallback line.
REM CREGFIX.SYS (mintsuki, 0BSD) comes first: it cleans CR0/CR2/CR3/CR4/EFER
REM after CSMWrap at every start (Setup's mini-Windows, the installed system).
REM (No IF with a redirection: COMMAND.COM opens the file even when false.)
IF NOT "%U9CSM%"=="1" GOTO NOCSM
IF NOT EXIST C:\USOS9X\CREGFIX.SYS GOTO FAILED
IF EXIST A:\HIMEM.SYS COPY /Y A:\HIMEM.SYS C:\USOS9X >NUL
ECHO DEVICE=C:\USOS9X\CREGFIX.SYS>C:\CONFIG.SYS
ECHO DEVICE=C:\WINDOWS\HIMEM.SYS /TESTMEM:OFF /M:2>>C:\CONFIG.SYS
IF "%U9VM%"=="1" GOTO NOCSM
IF NOT EXIST C:\USOS9X\HIMEM.SYS GOTO NOCSM
ECHO DEVICE=C:\USOS9X\HIMEM.SYS /TESTMEM:OFF /M:2>>C:\CONFIG.SYS
:NOCSM
REM Every Windows start: MaxPhysPage / MaxFileCache in SYSTEM.INI (U9FIX.TXT).
REM Windows 95: U9FIX /95 caps the RAM at 480 MiB (MaxPhysPage=1E000; 95 is
REM unstable above ~480 MB) and replaces MSBATCH.INF's 40000.
IF "%U9CSM%"=="1" GOTO CSMAUTO
IF "%U9SYS%"=="95" GOTO FIX95
ECHO @C:\USOS9X\U9FIX.COM C:\WINDOWS\SYSTEM.INI>C:\AUTOEXEC.BAT
GOTO FIXDONE
:FIX95
ECHO @C:\USOS9X\U9FIX.COM /95 C:\WINDOWS\SYSTEM.INI>C:\AUTOEXEC.BAT
:FIXDONE
ECHO @IF NOT EXIST C:\WINDOWS\WIN.COM IF EXIST C:\USOS9X\RESUME.BAT CALL C:\USOS9X\RESUME.BAT>>C:\AUTOEXEC.BAT
GOTO AUTODONE
:CSMAUTO
REM No firmware CSM: USB keyboard (USOSKEY bridge) in Windows through the
REM SeaBIOS services; U9FIX /CSM adds its driver. No VBADOS mouse: VBMOUSE.EXE
REM next to the PS/2 mouse VxD of the installed system stops Windows.
REM USB mouse: USOSMOUS.DRV (mouse.drv=) on USOSKEY.COM's mouse ring, 98 SE,
REM 98, 95 and Me (same 16-bit Windows 4.x mouse.drv interface; on Me
REM USOSKEY.DRV installs the bridge copy, see the Me block below).
REM U9FIX /CSM names it once it is in C:\WINDOWS\SYSTEM, so the drivers are
REM copied before U9FIX runs.
IF NOT EXIST C:\USOS9X\USOSKEY.DRV GOTO FAILED
IF "%U9SYS%"=="98SE" GOTO MOUSEOK
IF "%U9SYS%"=="98" GOTO MOUSEOK
IF "%U9SYS%"=="95" GOTO MOUSEOK
IF "%U9SYS%"=="ME" GOTO MOUSEOK
IF EXIST C:\USOS9X\USOSMOUS.DRV DEL C:\USOS9X\USOSMOUS.DRV
:MOUSEOK
ECHO @IF NOT EXIST C:\WINDOWS\SYSTEM\NUL GOTO USOSDRV>C:\AUTOEXEC.BAT
ECHO @IF NOT EXIST C:\WINDOWS\SYSTEM\USOSKEY.DRV COPY C:\USOS9X\*.DRV C:\WINDOWS\SYSTEM>>C:\AUTOEXEC.BAT
ECHO @IF NOT EXIST C:\WINDOWS\SYSTEM\USOSMOUS.DRV IF EXIST C:\USOS9X\USOSMOUS.DRV COPY C:\USOS9X\USOSMOUS.DRV C:\WINDOWS\SYSTEM>>C:\AUTOEXEC.BAT
ECHO :USOSDRV>>C:\AUTOEXEC.BAT
IF "%U9SYS%"=="95" GOTO CSMFIX95
ECHO @C:\USOS9X\U9FIX.COM /CSM C:\WINDOWS\SYSTEM.INI>>C:\AUTOEXEC.BAT
GOTO CSMFIXOK
:CSMFIX95
ECHO @C:\USOS9X\U9FIX.COM /95 /CSM C:\WINDOWS\SYSTEM.INI>>C:\AUTOEXEC.BAT
:CSMFIXOK
REM 95/98/98 SE with the USOS default answer: C:\USOS9X\TZFIX.BAT (tools/w9x_tzfix.sh)
REM presets the time zone once and drops the first-boot Date/Time step.
ECHO @IF EXIST C:\USOS9X\TZFIX.BAT CALL C:\USOS9X\TZFIX.BAT>>C:\AUTOEXEC.BAT
REM Windows 95: C:\USOS9X\VESA95.BAT (tools/w9x_vesa95.sh) moves the display
REM from Standard VGA to the VESA driver once (95 never enumerates PCI here).
ECHO @IF EXIST C:\USOS9X\VESA95.BAT CALL C:\USOS9X\VESA95.BAT>>C:\AUTOEXEC.BAT
REM A restart before Setup copied Windows (hang, power loss): RESUME.BAT,
REM written once Patcher9x succeeded, starts Setup again.
ECHO @IF NOT EXIST C:\WINDOWS\WIN.COM IF EXIST C:\USOS9X\RESUME.BAT CALL C:\USOS9X\RESUME.BAT>>C:\AUTOEXEC.BAT
ECHO @C:\USOS9X\USOSKEY.COM>>C:\AUTOEXEC.BAT
REM Real-hardware report before every Windows start (C:\USOS9X\DIAG.LOG):
REM off by default, only with EFI\USOS\win9x\diag.flag (U9DIAG=1).
IF NOT "%U9DIAG%"=="1" GOTO DIAGDONE
ECHO @IF EXIST C:\USOS9X\USOSDIAG.COM C:\USOS9X\USOSDIAG.COM BOOT>>C:\AUTOEXEC.BAT
:DIAGDONE
REM The DOS KEYB TSR that Setup adds at the end of AUTOEXEC.BAT stops the
REM installed Windows with a protection error next to the bridge (QEMU
REM OVMF bisect): it is renamed to KEYB.USO before it would load. Windows
REM keeps its own keyboard layout; only DOS prompts lose the national layout.
ECHO @IF EXIST C:\WINDOWS\COMMAND\KEYB.COM REN C:\WINDOWS\COMMAND\KEYB.COM KEYB.USO>>C:\AUTOEXEC.BAT
REM Me starts no real-mode program from AUTOEXEC.BAT and has no WINSTART.BAT:
REM USOSKEY.DRV installs the bridge itself (in DOS memory of the system VM).
REM The driver goes to SYSTEM before Setup; MSBATCH.INF [USOS.Csm] names it.
IF NOT "%U9SYS%"=="ME" GOTO CSMREG
MD C:\WINDOWS
MD C:\WINDOWS\SYSTEM
COPY /Y C:\USOS9X\USOSKEY.DRV C:\WINDOWS\SYSTEM >NUL
REM USB mouse on Me: USOSMOUS.DRV in SYSTEM before Setup, not named in
REM SYSTEM.INI (v2: nothing writes mouse.drv= on Me; the user sets
REM [boot] mouse.drv=usosmous.drv, docs section 4g). Keyboard only by default.
COPY /Y C:\USOS9X\USOSMOUS.DRV C:\WINDOWS\SYSTEM >NUL
REM A user's own answer file is copied 1:1 (it ends with its own section).
IF "%U9ANS%"=="USER" GOTO AUTODONE
ECHO system.ini,boot,drivers,,usoskey.drv>>C:\%U9SRC%\MSBATCH.INF
GOTO AUTODONE
:CSMREG
REM 98/98 SE: no PCI bus without this. SeaBIOS has a $PnP header but gives no
REM PnP BIOS device nodes, and Setup's detection (SYSDETMG DetectBus) adds the
REM PCI bus (*PNP0A03) only when it finds neither ACPI (refused: BIOS date
REM before ACPICheckDate) nor a PnP BIOS. IgnorePnPBIOS makes it skip $PnP
REM (docs/win9x-modern-2026-09-30.md 4c). [Install] names USOS.CsmReg.
IF "%U9SYS%"=="98SE" GOTO CSMREG2
IF NOT "%U9SYS%"=="98" GOTO AUTODONE
:CSMREG2
IF "%U9ANS%"=="USER" GOTO AUTODONE
ECHO [USOS.CsmReg]>>C:\%U9SRC%\MSBATCH.INF
ECHO HKLM,"Software\Microsoft\Windows\CurrentVersion\Detect",IgnorePnPBIOS,,"1">>C:\%U9SRC%\MSBATCH.INF
:AUTODONE
ECHO Poprawki zgodnosci (Patcher9x: TLB, CPU, RAM, rejestry CPU)...
REM CWSDPMI stays resident (-p) for Patcher9x and is unloaded (-u) right
REM after it: no DPMI host self-unload on program exit in the path (on the
REM X470 the chain stopped after Patcher9x's last message). -s-: no swap file.
ECHO CWSDPMI -p>>C:\USOS9X\INSTALL.LOG
%U9T%\CWSDPMI.EXE -p -s-
ECHO PATCH9X start>>C:\USOS9X\INSTALL.LOG
%U9T%\PATCH9X.EXE -auto -select all C:\%U9SRC%
IF ERRORLEVEL 1 GOTO FAILED
ECHO PATCH9X ok>>C:\USOS9X\INSTALL.LOG
ECHO Patcher9x zakonczony. Zwalnianie pamieci DPMI...
%U9T%\CWSDPMI.EXE -u
ECHO CWSDPMI -u>>C:\USOS9X\INSTALL.LOG
REM /IS no ScanDisk, /IE no startup disk, /NM no RAM/CPU check (MEMDISK).
REM Windows 95 Setup knows only /IS of these (and ignored the batch file
REM with the 98 switches in QEMU): MSBATCH.INF first, then /IS, and /IW: no
REM licence page (SUWIN.EXE looks for /IW on its command line; the licence
REM runs in Setup's own mini-Windows, before any USB keyboard bridge, and in
REM the phase-1 VM nobody can answer it). /P I below ignores the PnP BIOS.
SET U9SW=/IS /IE /NM
IF "%U9SYS%"=="95" SET U9SW=/IS /IW
REM Windows 95 NVMe opt-in: ignore the empty SeaBIOS PnP BIOS device list.
REM /P I exists in 95 too (Microsoft KB152064); test PCI detection here.
IF "%U9SYS%"=="95" IF "%U9NVME%"=="1" SET U9SW=/IS /IW /P I
REM U9VM=1: this Setup runs in USOS's QEMU (ACPI off) for its phase 1, the
REM rest on the real PC under CSMWrap: /P I keeps Windows off ACPI (APM/legacy).
IF "%U9SYS%"=="95" GOTO VMSWOK
IF "%U9VM%"=="1" SET U9SW=%U9SW% /P I
:VMSWOK
REM Resume hook: C:\AUTOEXEC.BAT calls it while C:\WINDOWS\WIN.COM is missing.
ECHO @ECHO OFF>C:\USOS9X\RESUME.BAT
ECHO ECHO Wznawianie Instalatora Windows %U9SYS%...>>C:\USOS9X\RESUME.BAT
ECHO C:>>C:\USOS9X\RESUME.BAT
ECHO CD \%U9SRC%>>C:\USOS9X\RESUME.BAT
ECHO C:\%U9SRC%\SETUP.EXE C:\%U9SRC%\MSBATCH.INF %U9SW%>>C:\USOS9X\RESUME.BAT
C:
CD \%U9SRC%
ECHO Uruchamianie Instalatora Windows %U9SYS%...
ECHO SETUP start %U9SW%>>C:\USOS9X\INSTALL.LOG
C:\%U9SRC%\SETUP.EXE C:\%U9SRC%\MSBATCH.INF %U9SW%
ECHO SETUP returned>>C:\USOS9X\INSTALL.LOG
GOTO STOP
:FAILED
ECHO Przygotowanie dysku nie powiodlo sie. Instalator nie zostanie uruchomiony.
:STOP
ECHO Uruchom ponownie komputer, aby wrocic do USOS.
PAUSE >NUL
GOTO STOP
