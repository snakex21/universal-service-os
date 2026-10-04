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
FOR %%F IN (USOSKEY.COM USOSKEY.DRV VBMOUSE.EXE VBMOUSE.DRV VBADOS.TXT) DO COPY /Y A:\%%F C:\USOS9X >NUL
:COPYDONE
IF NOT EXIST C:\%U9SRC%\SETUP.EXE GOTO FAILED
COPY /Y %U9T%\MSBATCH.INF C:\%U9SRC%\MSBATCH.INF >NUL
IF ERRORLEVEL 1 GOTO FAILED
REM VESA display driver (vmdisp9x, MIT) next to Setup: DevicePath=1 finds it.
FOR %%F IN (USOSVESA.INF VESAMINI.DRV VESAMINI.VXD VMHAL9X.DLL) DO COPY /Y %U9T%\%%F C:\%U9SRC% >NUL
FOR %%F IN (VMHAL486.DLL VMDISP9X.DLL) DO COPY /Y %U9T%\%%F C:\%U9SRC% >NUL
IF NOT EXIST C:\%U9SRC%\VMDISP9X.DLL GOTO FAILED
REM Hardware IDs of this PC's display cards: they outrank Standard VGA.
%U9T%\U9FIX.COM /VGA C:\%U9SRC%\USOSVESA.INF
REM Under CSMWrap HIMEM needs A20 through port 92h (/M:2), else DOS=HIGH hangs.
REM Setup keeps the line; the file exists from its first restart on.
REM (No IF with a redirection: COMMAND.COM opens the file even when false.)
IF NOT "%U9CSM%"=="1" GOTO NOCSM
ECHO DEVICE=C:\WINDOWS\HIMEM.SYS /TESTMEM:OFF /M:2>C:\CONFIG.SYS
:NOCSM
REM Every Windows start: MaxPhysPage / MaxFileCache in SYSTEM.INI (U9FIX.TXT).
IF "%U9CSM%"=="1" GOTO CSMAUTO
ECHO @C:\USOS9X\U9FIX.COM C:\WINDOWS\SYSTEM.INI>C:\AUTOEXEC.BAT
GOTO AUTODONE
:CSMAUTO
REM No firmware CSM: USB keyboard (USOSKEY bridge) in Windows through the
REM SeaBIOS services; U9FIX /CSM adds its driver. No VBADOS mouse: VBMOUSE.EXE
REM next to the PS/2 mouse VxD of the installed system stops Windows.
IF NOT EXIST C:\USOS9X\USOSKEY.DRV GOTO FAILED
ECHO @C:\USOS9X\U9FIX.COM /CSM C:\WINDOWS\SYSTEM.INI>C:\AUTOEXEC.BAT
ECHO @IF NOT EXIST C:\WINDOWS\SYSTEM\NUL GOTO USOSDRV>>C:\AUTOEXEC.BAT
ECHO @IF NOT EXIST C:\WINDOWS\SYSTEM\USOSKEY.DRV COPY C:\USOS9X\*.DRV C:\WINDOWS\SYSTEM>>C:\AUTOEXEC.BAT
ECHO :USOSDRV>>C:\AUTOEXEC.BAT
ECHO @C:\USOS9X\USOSKEY.COM>>C:\AUTOEXEC.BAT
REM Me starts no real-mode program from AUTOEXEC.BAT and has no WINSTART.BAT:
REM USOSKEY.DRV installs the bridge itself (in DOS memory of the system VM).
REM The driver goes to SYSTEM before Setup; MSBATCH.INF [USOS.Csm] names it.
IF NOT "%U9SYS%"=="ME" GOTO AUTODONE
MD C:\WINDOWS
MD C:\WINDOWS\SYSTEM
COPY /Y C:\USOS9X\USOSKEY.DRV C:\WINDOWS\SYSTEM >NUL
REM A user's own answer file is copied 1:1 (it ends with its own section).
IF "%U9ANS%"=="USER" GOTO AUTODONE
ECHO system.ini,boot,drivers,,usoskey.drv>>C:\%U9SRC%\MSBATCH.INF
:AUTODONE
ECHO Poprawki zgodnosci (Patcher9x: TLB, CPU, RAM, rejestry CPU)...
%U9T%\CWSDPMI.EXE -s-
%U9T%\PATCH9X.EXE -auto -select all C:\%U9SRC%
IF ERRORLEVEL 1 GOTO FAILED
C:
CD \%U9SRC%
REM /IS no ScanDisk, /IE no startup disk, /NM no RAM/CPU check (MEMDISK).
REM Windows 95 Setup knows only /IS of these (and ignored the batch file
REM with the 98 switches in QEMU): MSBATCH.INF first, then /IS.
IF "%U9SYS%"=="95" GOTO SETUP95
C:\%U9SRC%\SETUP.EXE C:\%U9SRC%\MSBATCH.INF /IS /IE /NM
GOTO STOP
:SETUP95
C:\%U9SRC%\SETUP.EXE C:\%U9SRC%\MSBATCH.INF /IS
GOTO STOP
:FAILED
ECHO Przygotowanie dysku nie powiodlo sie. Instalator nie zostanie uruchomiony.
:STOP
ECHO Uruchom ponownie komputer, aby wrocic do USOS.
PAUSE >NUL
GOTO STOP
