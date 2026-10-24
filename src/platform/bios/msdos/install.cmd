@echo off
rem Two modes. BIOS Core: everything on the RAM disk D:, booted from it.
rem Disk mode (UDISK=1, prepared from UEFI by tools/dos_csmwrap_target.sh):
rem A: is the MS-DOS boot floppy (MEMDISK), the sources are in C:\USOSDOS.
if "%USRC%"=="" set USRC=D:
if "%USYS%"=="" set USYS=D:\
echo USOS - installing MS-DOS on the confirmed FAT16 target C:
%USRC%\DOSFILES\SYS.COM %USYS% C:
if errorlevel 1 goto failed
rem Disk mode: the one-time syslinux start goes (SYS replaced its boot sector).
if not "%UDISK%"=="1" goto sl_done
%USRC%\DOSFILES\ATTRIB.EXE -r -h -s C:\LDLINUX.SYS
del C:\LDLINUX.SYS
%USRC%\DOSFILES\ATTRIB.EXE -r -h -s C:\LDLINUX.C32
del C:\LDLINUX.C32
del C:\SYSLINUX.CFG
:sl_done
call %USRC%\PREPDOS.BAT %USRC%\DOSFILES C:\DOS %USRC%
if not exist C:\DOS\READY.TAG goto failed
rem C:\DOS as MS-DOS 6.22 Setup leaves it (docs/dos-setup-parity-2026-10-24.md):
rem a COMMAND.COM copy, none of the Supplemental Disk installer files (they
rem work only from that diskette; SETUP.BAT, 720ID0x.BAT), and the volume
rem label Setup gives the drive.
copy C:\COMMAND.COM C:\DOS /y >nul
for %%f in (SETUP.BAT SETUP.MSG SD6COPY.BAT 360ID01.BAT 360ID02.BAT) do if exist C:\DOS\%%f del C:\DOS\%%f
for %%f in (720ID01.BAT 720ID02.BAT) do if exist C:\DOS\%%f del C:\DOS\%%f
if exist C:\DOS\LABEL.EXE C:\DOS\LABEL.EXE C:MS-DOS_6
rem WINA20.386 in the root of the boot drive, as MS-DOS Setup places it
rem (DOSSETUP.INI [dif-path]: beside COMMAND.COM, plain attributes). The DOS
rem 5.0/6.x kernel asks Windows 3.0 enhanced mode (WIN, WIN /3) to load it;
rem without it WIN stops with "You must have the file WINA20.386 in the root
rem of your boot drive". Windows 3.1 and later ignore it. PREPDOS expanded it
rem from WINA20.38_ of the user's MS-DOS media into C:\DOS; media without it
rem = logged and skipped. Log: C:\DOS\USOSDOS.LOG.
if exist C:\WINA20.386 goto wina20_have
if not exist C:\DOS\WINA20.386 goto wina20_none
copy C:\DOS\WINA20.386 C:\ /y >nul
if errorlevel 1 goto wina20_none
if not exist C:\WINA20.386 goto wina20_none
echo WINA20.386: copied from C:\DOS to C:\>>C:\DOS\USOSDOS.LOG
goto wina20_done
:wina20_have
echo WINA20.386: already in C:\>>C:\DOS\USOSDOS.LOG
goto wina20_done
:wina20_none
echo WINA20.386: not on the MS-DOS media - Windows 3.0 needs WIN /S or /R>>C:\DOS\USOSDOS.LOG
:wina20_done
copy %USRC%\REBOOT.COM C:\DOS /y >nul
if errorlevel 1 goto failed
copy %USRC%\HIMEMX.EXE C:\DOS /y >nul
if errorlevel 1 goto failed
copy %USRC%\HIMEMX.TXT C:\DOS /y >nul
if errorlevel 1 goto failed
copy %USRC%\HIMEMSRC.ZIP C:\DOS /y >nul
if errorlevel 1 goto failed
copy %USRC%\LICENSE.TXT C:\DOS /y >nul
if errorlevel 1 goto failed
md C:\TEMP
rem SETVER first, as MS-DOS Setup writes it (programs that ask for an older
rem DOS version); the same driver the X470-proven Windows 1.x-3.0 menu loads.
rem No SMARTDRV and no EMM386 (EMM386 breaks the USOSPKT MMIO fallback).
echo DEVICE=C:\DOS\SETVER.EXE>C:\CONFIG.SYS
echo DEVICE=C:\DOS\HIMEMX.EXE /MAX=32768 /X2MAX32>>C:\CONFIG.SYS
echo DOS=HIGH>>C:\CONFIG.SYS
echo FILES=40>>C:\CONFIG.SYS
echo BUFFERS=20>>C:\CONFIG.SYS
echo LASTDRIVE=Z>>C:\CONFIG.SYS
echo SHELL=C:\COMMAND.COM C:\ /E:2048 /P>>C:\CONFIG.SYS
echo @echo off>C:\AUTOEXEC.BAT
echo prompt $p$g>>C:\AUTOEXEC.BAT
echo path C:\DOS;C:\WINDOWS;C:\PROGRAMS>>C:\AUTOEXEC.BAT
echo set TEMP=C:\TEMP>>C:\AUTOEXEC.BAT
echo ver>>C:\AUTOEXEC.BAT
rem INT 10h on a private stack for WIN.COM of Windows 1.x/2.x (W1AUTO.BAT),
rem also with CSM: the video BIOS stack depth does not depend on CSMWrap.
if not exist %USRC%\USOSV10.COM goto v10_done
copy %USRC%\USOSV10.COM C:\DOS /y >nul
if errorlevel 1 goto failed
:v10_done
rem VGA readback/latch probe for C:\DOS, run on demand only
rem (C:\DOS\USOSVGAR.COM>C:\USOS\DIAG\VGAREG.TXT); missing file = skipped.
if not exist %USRC%\USOSVGAR.COM goto vgar_done
copy %USRC%\USOSVGAR.COM C:\DOS /y >nul
if errorlevel 1 goto failed
:vgar_done
rem Prepared under CSMWrap (UEFI PC without CSM): USB mouse through VBADOS.
if not exist %USRC%\CSMWRAP.TAG goto csm_dos_done
copy %USRC%\VBMOUSE.EXE C:\DOS /y >nul
if errorlevel 1 goto failed
copy %USRC%\VBADOS.TXT C:\DOS /y >nul
if errorlevel 1 goto failed
copy %USRC%\USOSKEY.COM C:\DOS /y >nul
if errorlevel 1 goto failed
if not exist %USRC%\USOSKBC.COM goto kbc_done
copy %USRC%\USOSKBC.COM C:\DOS /y >nul
if errorlevel 1 goto failed
:kbc_done
rem CS:IP locator for the early-Windows diagnostic start items (W1AUTO.BAT).
if not exist %USRC%\USOSWHER.COM goto where_done
copy %USRC%\USOSWHER.COM C:\DOS /y >nul
if errorlevel 1 goto failed
:where_done
rem CTTY NUL around VBMOUSE: its VirtualBox/VMware probe lines go to
rem stderr, which COMMAND.COM cannot redirect; a failure is still reported.
echo ctty nul>>C:\AUTOEXEC.BAT
echo C:\DOS\VBMOUSE.EXE>>C:\AUTOEXEC.BAT
echo ctty con>>C:\AUTOEXEC.BAT
echo if errorlevel 1 echo USOS: the DOS mouse driver (VBMOUSE) did not load.>>C:\AUTOEXEC.BAT
echo C:\DOS\USOSKEY.COM>>C:\AUTOEXEC.BAT
:csm_dos_done
if not exist %USRC%\PROGRAMS\nul goto programs_done
md C:\PROGRAMS
C:\DOS\XCOPY.EXE %USRC%\PROGRAMS\*.* C:\PROGRAMS /s /e /v >nul
if errorlevel 2 goto failed
:programs_done
rem Network (C:\NET): own packet driver USOSPKT for Intel I211/I210/82576
rem and mTCP (GPL-3.0, source MTCPSRC.ZIP); NETSTART.BAT loads it and runs
rem DHCP at every start, and returns at once when no such NIC is present.
rem Windows 1.x-3.x: staged too, but not called in the Setup stage (this
rem AUTOEXEC.BAT); their start menus (W1AUTO.BAT / W3AUTO.BAT) call
rem NETSTART.BAT before WIN, so the driver is resident under Windows and
rem mTCP works at the DOS prompt and after leaving Windows.
if not exist %USRC%\USOSPKT.COM goto net_done
if not exist C:\NET\NUL md C:\NET
for %%f in (USOSPKT.COM NETSTART.BAT MTCP.DEF MTCP.TXT MTCPSRC.ZIP) do copy %USRC%\%%f C:\NET /y >nul
for %%f in (DHCP PING HTGET FTP TELNET SNTP NC DNSTEST PKTTOOL) do copy %USRC%\%%f.EXE C:\NET /y >nul
if not exist C:\NET\NETSTART.BAT goto failed
if not exist C:\NET\DHCP.EXE goto failed
if not exist C:\NET\PKTTOOL.EXE goto failed
copy C:\NET\MTCP.DEF C:\NET\MTCP.CFG /y >nul
if exist %USRC%\WINSETUP\SETUP.EXE goto net_done
echo call C:\NET\NETSTART.BAT>>C:\AUTOEXEC.BAT
:net_done
if not exist %USRC%\WINSETUP\SETUP.EXE goto dos_done
md C:\WINSETUP
C:\DOS\XCOPY.EXE %USRC%\WINSETUP\*.* C:\WINSETUP /s /e /v >nul
if errorlevel 1 goto failed
if not exist C:\WINSETUP\SETUP.EXE goto failed
rem Central European editions (Polish 3.1): Setup would put the code page 852
rem helper (ADD852.EXE /A) into Autostart. It rewrites CONFIG.SYS and
rem AUTOEXEC.BAT and so replaces the start menu. W3INF.BAS writes SETUP.NEW
rem without that one entry; no SETUP.NEW = nothing to change.
if exist C:\WINSETUP\SETUP.NEW del C:\WINSETUP\SETUP.NEW
C:\DOS\QBASIC.EXE /RUN %USRC%\W3INF.BAS
if not exist C:\WINSETUP\SETUP.NEW goto inf_done
copy C:\WINSETUP\SETUP.NEW C:\WINSETUP\SETUP.INF /y >nul
if errorlevel 1 goto failed
del C:\WINSETUP\SETUP.NEW
:inf_done
md C:\USOSW3
rem Setup answers for USOSKBC (dos_csmwrap_target.sh picks the script).
if not exist %USRC%\SETUP.KEY goto setup_key_done
copy %USRC%\SETUP.KEY C:\USOSW3 /y >nul
if errorlevel 1 goto failed
:setup_key_done
copy %USRC%\W3START.BAT C:\USOSW3 /y >nul
if errorlevel 1 goto failed
copy %USRC%\WINMENU.BAT C:\USOSW3 /y >nul
if errorlevel 1 goto failed
copy %USRC%\W3CONFIG.SYS C:\USOSW3 /y >nul
if errorlevel 1 goto failed
copy %USRC%\W3AUTO.BAT C:\USOSW3 /y >nul
if errorlevel 1 goto failed
rem WIN typed at the DOS prompt = the menu's mode (DOSKEY macro, W3AUTO.BAT).
if not exist %USRC%\WINRUN.BAT goto winrun_done
copy %USRC%\WINRUN.BAT C:\USOSW3 /y >nul
if errorlevel 1 goto failed
:winrun_done
rem CSMWrap: HIMEM /M:2 and VBMOUSE in the start menu, SYSTEM.INI changes.
if not exist %USRC%\CSMWRAP.TAG goto csm_w3_done
copy %USRC%\W3CONFIG.CSM C:\USOSW3\W3CONFIG.SYS /y >nul
if errorlevel 1 goto failed
copy %USRC%\W3AUTO.CSM C:\USOSW3\W3AUTO.BAT /y >nul
if errorlevel 1 goto failed
copy %USRC%\W3INI.BAS C:\USOSW3 /y >nul
if errorlevel 1 goto failed
copy %USRC%\VBMOUSE.DRV C:\USOSW3 /y >nul
if errorlevel 1 goto failed
copy %USRC%\USOSKEY.DRV C:\USOSW3 /y >nul
if errorlevel 1 goto failed
copy %USRC%\USOS.SHH C:\WINSETUP /y >nul
if errorlevel 1 goto failed
:csm_w3_done
rem Windows 1.0x-3.0 (EARLY.TAG): Setup from A: (W3START.BAT), own start
rem menu (no DOS=HIGH, SETVER, WIN386), no SYSTEM.INI changes.
if not exist %USRC%\EARLY.TAG goto early_done
copy %USRC%\EARLY.TAG C:\USOSW3 /y >nul
if errorlevel 1 goto failed
copy %USRC%\W1SETUP.BAT C:\USOSW3 /y >nul
if errorlevel 1 goto failed
rem Windows 3.0: W1AUTO.BAT puts it into C:\WINDOWS as WIN.BAT (WIN.COM -> WIN30.COM).
if not exist %USRC%\W30WIN.BAT goto w30win_done
copy %USRC%\W30WIN.BAT C:\USOSW3\WIN.BAT /y >nul
if errorlevel 1 goto failed
:w30win_done
copy %USRC%\W1CONFIG.SYS C:\USOSW3\W3CONFIG.SYS /y >nul
if errorlevel 1 goto failed
copy %USRC%\W1AUTO.BAT C:\USOSW3\W3AUTO.BAT /y >nul
if errorlevel 1 goto failed
if not exist %USRC%\CSMWRAP.TAG goto early_setver
copy %USRC%\W1CONFIG.CSM C:\USOSW3\W3CONFIG.SYS /y >nul
if errorlevel 1 goto failed
copy %USRC%\W1AUTO.CSM C:\USOSW3\W3AUTO.BAT /y >nul
if errorlevel 1 goto failed
if exist C:\USOSW3\W3INI.BAS del C:\USOSW3\W3INI.BAS
rem Windows 1.0x (dos_csmwrap_target.sh stages USOSMS1.DRV only for them):
rem none of its mouse drivers uses the BIOS, the USB mouse exists only as
rem the BIOS pointing device. USOSMS1.DRV takes the place of MOUSE.DRV, the
rem "Microsoft Mouse" answer of W101/W104.KEY; Setup binds it into WIN100.BIN.
if not exist %USRC%\USOSMS1.DRV goto early_setver
copy %USRC%\USOSMS1.DRV C:\WINSETUP\MOUSE.DRV /y >nul
if errorlevel 1 goto failed
:early_setver
rem The SETVER table of MS-DOS 6.22 lists WIN200.BIN (Windows 2.x) but not
rem WIN100.BIN: the Windows 1.0x kernel then fails its DOS check and prints
rem "Incorrect DOS version" plus memory garbage at every start.
if exist C:\DOS\SETVER.EXE C:\DOS\SETVER.EXE C:\DOS WIN100.BIN 3.40 >nul
:early_done
rem Windows Setup needs the original DOS XMS manager after a cold restart.
rem Under CSMWrap HIMEM picks A20 handler 3, which leaves A20 off: /M:2.
rem (No IF with a redirection: COMMAND.COM opens the file even when false.)
if exist %USRC%\CSMWRAP.TAG goto himem_csmwrap
echo DEVICE=C:\DOS\HIMEM.SYS /TESTMEM:OFF>C:\CONFIG.SYS
goto himem_done
:himem_csmwrap
echo DEVICE=C:\DOS\HIMEM.SYS /TESTMEM:OFF /M:2>C:\CONFIG.SYS
:himem_done
rem Windows 2.x needs the HMA free and SETVER (WIN.COM: "Incorrect DOS
rem version" on MS-DOS 6.22).
if exist %USRC%\EARLY.TAG goto conf_early
echo DOS=HIGH>>C:\CONFIG.SYS
goto conf_common
:conf_early
echo DEVICE=C:\DOS\SETVER.EXE>>C:\CONFIG.SYS
:conf_common
echo FILES=40>>C:\CONFIG.SYS
echo BUFFERS=20>>C:\CONFIG.SYS
echo LASTDRIVE=Z>>C:\CONFIG.SYS
echo SHELL=C:\COMMAND.COM C:\ /E:2048 /P>>C:\CONFIG.SYS
echo C:\USOSW3\W3START.BAT>>C:\AUTOEXEC.BAT
cls
echo USOS - stage 1 completed.
echo.
echo DOS and Windows Setup files are ready on the target disk.
if "%UDISK%"=="1" goto s1_disk
echo Remove USOS USB, then press Enter to restart from the target disk.
goto s1_text
:s1_disk
echo The computer restarts from the target disk automatically.
:s1_text
echo Original Windows Setup will start automatically.
echo After Setup, USOS prepares a Windows and DOS start menu.
echo A final restart will load that menu and its new settings.
goto reboot_prompt
:dos_done
rem Regional settings of the answer profile (dos_csmwrap_target.sh, DOS.INI):
rem COUNTRY and DISPLAY.SYS / MODE CON CODEPAGE (and KEYB when chosen), as a
rem localized MS-DOS Setup writes them. The Windows start menus carry the
rem same lines; no file = US defaults as before.
if not exist %USRC%\REGCFG.SYS goto regcfg_done
type %USRC%\REGCFG.SYS>>C:\CONFIG.SYS
:regcfg_done
if not exist %USRC%\REGAUTO.BAT goto regauto_done
type %USRC%\REGAUTO.BAT>>C:\AUTOEXEC.BAT
:regauto_done
cls
echo USOS - installation completed.
echo.
echo MS-DOS installation completed.
if "%UDISK%"=="1" goto done_disk
echo Remove USOS USB, then press Enter to restart from the target disk.
goto reboot_prompt
:done_disk
echo The computer restarts from the target disk automatically.
rem MS-DOS compares only the first 8 characters of a label, so every label
rem must differ within them (tools/tests/test_dos_batch_labels.py).
:reboot_prompt
prompt $p$g
if "%UDISK%"=="1" goto auto_restart
echo.
echo REBOOT is prepared below. Press Enter when ready, or Esc to clear it.
echo.
D:
cd \
D:\REBOOT.COM /P
goto end
:auto_restart
echo.
if not exist C:\DOS\CHOICE.COM goto restart_go
C:\DOS\CHOICE.COM /C:R /T:R,8 Restarting in 8 seconds. Press R to restart now
:restart_go
echo Restarting from the target disk...
rem MS-DOS only: C:\USOSDOS (media copy, MEMDISK, helpers) goes like the Setup
rem disks; a batch outside it removes it (this one is read line by line).
if exist C:\WINSETUP\SETUP.EXE goto finreboot
if not exist C:\DOS\DELTREE.EXE goto finreboot
if not exist C:\DOS\REBOOT.COM goto finreboot
echo @echo off>C:\TEMP\USOSFIN.BAT
echo C:\DOS\DELTREE.EXE /Y C:\USOSDOS>>C:\TEMP\USOSFIN.BAT
echo C:\DOS\REBOOT.COM>>C:\TEMP\USOSFIN.BAT
C:\TEMP\USOSFIN.BAT
:finreboot
%USRC%\REBOOT.COM
goto end
:failed
echo.
echo USOS: INSTALLATION FAILED. Do not treat this disk as complete.
echo Review the preceding error and restart from USOS to retry.
:end
