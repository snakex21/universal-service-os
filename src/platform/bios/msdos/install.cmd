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
echo DEVICE=C:\DOS\HIMEMX.EXE /MAX=32768 /X2MAX32>C:\CONFIG.SYS
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
rem Prepared under CSMWrap (UEFI PC without CSM): USB mouse through VBADOS.
if not exist %USRC%\CSMWRAP.TAG goto csm_dos_done
copy %USRC%\VBMOUSE.EXE C:\DOS /y >nul
if errorlevel 1 goto failed
copy %USRC%\VBADOS.TXT C:\DOS /y >nul
if errorlevel 1 goto failed
copy %USRC%\USOSKEY.COM C:\DOS /y >nul
if errorlevel 1 goto failed
echo C:\DOS\VBMOUSE.EXE>>C:\AUTOEXEC.BAT
echo C:\DOS\USOSKEY.COM>>C:\AUTOEXEC.BAT
:csm_dos_done
if not exist %USRC%\PROGRAMS\nul goto programs_done
md C:\PROGRAMS
C:\DOS\XCOPY.EXE %USRC%\PROGRAMS\*.* C:\PROGRAMS /s /e /v >nul
if errorlevel 2 goto failed
:programs_done
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
copy %USRC%\W3START.BAT C:\USOSW3 /y >nul
if errorlevel 1 goto failed
copy %USRC%\WINMENU.BAT C:\USOSW3 /y >nul
if errorlevel 1 goto failed
copy %USRC%\W3CONFIG.SYS C:\USOSW3 /y >nul
if errorlevel 1 goto failed
copy %USRC%\W3AUTO.BAT C:\USOSW3 /y >nul
if errorlevel 1 goto failed
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
copy %USRC%\W1CONFIG.SYS C:\USOSW3\W3CONFIG.SYS /y >nul
if errorlevel 1 goto failed
copy %USRC%\W1AUTO.BAT C:\USOSW3\W3AUTO.BAT /y >nul
if errorlevel 1 goto failed
if not exist %USRC%\CSMWRAP.TAG goto early_done
copy %USRC%\W1CONFIG.CSM C:\USOSW3\W3CONFIG.SYS /y >nul
if errorlevel 1 goto failed
copy %USRC%\W1AUTO.CSM C:\USOSW3\W3AUTO.BAT /y >nul
if errorlevel 1 goto failed
if exist C:\USOSW3\W3INI.BAS del C:\USOSW3\W3INI.BAS
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
%USRC%\REBOOT.COM
goto end
:failed
echo.
echo USOS: INSTALLATION FAILED. Do not treat this disk as complete.
echo Review the preceding error and restart from USOS to retry.
:end
