@echo off
if exist C:\WINDOWS\WIN.COM goto have_win
rem Windows 3.0 after W1AUTO.BAT renamed WIN.COM (C:\WINDOWS\WIN.BAT).
if exist C:\WINDOWS\WIN30.COM goto have_win
if exist C:\WIN386\WIN386.EXE goto have_win
if exist C:\WINDOWS\WIN386.EXE goto have_win
goto missing
:have_win
if not exist C:\USOSW3\W3CONFIG.SYS goto missing
if not exist C:\USOSW3\W3AUTO.BAT goto missing
if exist C:\USOSW3\MENU.TAG goto ready
rem Keep the startup files written by the original Windows installer.
if exist C:\USOSW3\CONFIG.OLD goto auto_backup
copy C:\CONFIG.SYS C:\USOSW3\CONFIG.OLD /y >nul
if errorlevel 1 goto failed
:auto_backup
if exist C:\USOSW3\AUTOEXEC.OLD goto install
copy C:\AUTOEXEC.BAT C:\USOSW3\AUTOEXEC.OLD /y >nul
if errorlevel 1 goto failed
:install
rem CSMWrap: VBMOUSE.DRV, USOSKEY.DRV and SYSTEM.INI once, with a backup.
if not exist C:\USOSW3\W3INI.BAS goto ini_done
if exist C:\USOSW3\W3INI.OK goto ini_done
copy C:\USOSW3\VBMOUSE.DRV C:\WINDOWS\SYSTEM /y >nul
if errorlevel 1 goto failed
copy C:\USOSW3\USOSKEY.DRV C:\WINDOWS\SYSTEM /y >nul
if errorlevel 1 goto failed
if exist C:\USOSW3\SYSTEM.NEW del C:\USOSW3\SYSTEM.NEW
C:\DOS\QBASIC.EXE /RUN C:\USOSW3\W3INI.BAS
if not exist C:\USOSW3\SYSTEM.NEW goto failed
if not exist C:\USOSW3\SYSTEM.OLD copy C:\WINDOWS\SYSTEM.INI C:\USOSW3\SYSTEM.OLD /y >nul
copy C:\USOSW3\SYSTEM.NEW C:\WINDOWS\SYSTEM.INI /y >nul
if errorlevel 1 goto failed
C:\DOS\FC.EXE /b C:\USOSW3\SYSTEM.NEW C:\WINDOWS\SYSTEM.INI >nul
if errorlevel 1 goto failed
echo SYSTEM.INI updated for CSMWrap>C:\USOSW3\W3INI.OK
:ini_done
copy C:\USOSW3\W3CONFIG.SYS C:\CONFIG.SYS /y >nul
if errorlevel 1 goto failed
copy C:\USOSW3\W3AUTO.BAT C:\AUTOEXEC.BAT /y >nul
if errorlevel 1 goto failed
C:\DOS\FC.EXE /b C:\USOSW3\W3CONFIG.SYS C:\CONFIG.SYS >nul
if errorlevel 1 goto failed
C:\DOS\FC.EXE /b C:\USOSW3\W3AUTO.BAT C:\AUTOEXEC.BAT >nul
if errorlevel 1 goto failed
echo Windows 3.x start menu installed>C:\USOSW3\MENU.TAG
if not exist C:\USOSW3\MENU.TAG goto failed
:ready
rem Setup may have enabled write-behind caching in this boot.
if exist C:\WINDOWS\SMARTDRV.EXE C:\WINDOWS\SMARTDRV.EXE /C
cls
echo.
echo USOS - Windows 3.x start menu is ready.
echo One final restart is required to load the new settings.
echo Windows standard mode will start automatically after 8 seconds.
echo Previous configuration: C:\USOSW3\*.OLD
echo.
if not exist C:\DOS\REBOOT.COM goto manual_restart
path C:\DOS;C:\WINDOWS;C:\PROGRAMS
prompt $p$g
C:
cd \
if not exist C:\DOS\CHOICE.COM goto prefill_reboot
echo R - restart now (automatic after 5 seconds)
echo A - stay in MS-DOS (type REBOOT later to restart)
echo.
C:\DOS\CHOICE.COM /C:RA /T:R,5 Restart now
if errorlevel 2 goto stay_dos
C:\DOS\REBOOT.COM
goto end
:stay_dos
echo Type REBOOT and press Enter to restart. Do not run WIN in this session.
goto end
:prefill_reboot
echo REBOOT is prepared below. Press Enter when ready, or Esc to clear it.
echo.
C:\DOS\REBOOT.COM /P
goto end
:manual_restart
echo Restart the computer to open the menu. Do not run WIN in this session.
goto end
:missing
echo USOS: Windows files or the menu are missing. The configuration was not changed.
goto end
:failed
if exist C:\USOSW3\MENU.TAG del C:\USOSW3\MENU.TAG
echo USOS: writing the menu failed. Restoring the configuration.
if exist C:\USOSW3\CONFIG.OLD copy C:\USOSW3\CONFIG.OLD C:\CONFIG.SYS /y
if exist C:\USOSW3\AUTOEXEC.OLD copy C:\USOSW3\AUTOEXEC.OLD C:\AUTOEXEC.BAT /y
if exist C:\USOSW3\W3INI.OK goto restore_done
if exist C:\USOSW3\SYSTEM.OLD copy C:\USOSW3\SYSTEM.OLD C:\WINDOWS\SYSTEM.INI /y
:restore_done
if exist C:\WINDOWS\SMARTDRV.EXE C:\WINDOWS\SMARTDRV.EXE /C
echo Check for write errors. Restart the computer to try again.
:end
