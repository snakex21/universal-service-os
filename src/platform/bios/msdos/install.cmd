@echo off
echo USOS - installing MS-DOS on the confirmed FAT16 target C:
D:\DOSFILES\SYS.COM D:\ C:
if errorlevel 1 goto failed
call D:\PREPDOS.BAT D:\DOSFILES C:\DOS D:
if not exist C:\DOS\READY.TAG goto failed
copy D:\REBOOT.COM C:\DOS /y >nul
if errorlevel 1 goto failed
copy D:\HIMEMX.EXE C:\DOS /y >nul
if errorlevel 1 goto failed
copy D:\HIMEMX.TXT C:\DOS /y >nul
if errorlevel 1 goto failed
copy D:\HIMEMSRC.ZIP C:\DOS /y >nul
if errorlevel 1 goto failed
copy D:\LICENSE.TXT C:\DOS /y >nul
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
if not exist D:\CSMWRAP.TAG goto csm_dos_done
copy D:\VBMOUSE.EXE C:\DOS /y >nul
if errorlevel 1 goto failed
copy D:\VBADOS.TXT C:\DOS /y >nul
if errorlevel 1 goto failed
copy D:\USOSKEY.COM C:\DOS /y >nul
if errorlevel 1 goto failed
echo C:\DOS\VBMOUSE.EXE>>C:\AUTOEXEC.BAT
echo C:\DOS\USOSKEY.COM>>C:\AUTOEXEC.BAT
:csm_dos_done
if not exist D:\PROGRAMS\nul goto programs_done
md C:\PROGRAMS
C:\DOS\XCOPY.EXE D:\PROGRAMS\*.* C:\PROGRAMS /s /e /v >nul
if errorlevel 2 goto failed
:programs_done
if not exist D:\WINSETUP\SETUP.EXE goto dos_done
md C:\WINSETUP
C:\DOS\XCOPY.EXE D:\WINSETUP\*.* C:\WINSETUP /s /e /v >nul
if errorlevel 1 goto failed
if not exist C:\WINSETUP\SETUP.EXE goto failed
md C:\USOSW3
copy D:\W3START.BAT C:\USOSW3 /y >nul
if errorlevel 1 goto failed
copy D:\WINMENU.BAT C:\USOSW3 /y >nul
if errorlevel 1 goto failed
copy D:\W3CONFIG.SYS C:\USOSW3 /y >nul
if errorlevel 1 goto failed
copy D:\W3AUTO.BAT C:\USOSW3 /y >nul
if errorlevel 1 goto failed
rem CSMWrap: HIMEM /M:2 and VBMOUSE in the start menu, SYSTEM.INI changes.
if not exist D:\CSMWRAP.TAG goto csm_w3_done
copy D:\W3CONFIG.CSM C:\USOSW3\W3CONFIG.SYS /y >nul
if errorlevel 1 goto failed
copy D:\W3AUTO.CSM C:\USOSW3\W3AUTO.BAT /y >nul
if errorlevel 1 goto failed
copy D:\W3INI.BAS C:\USOSW3 /y >nul
if errorlevel 1 goto failed
copy D:\VBMOUSE.DRV C:\USOSW3 /y >nul
if errorlevel 1 goto failed
copy D:\USOSKEY.DRV C:\USOSW3 /y >nul
if errorlevel 1 goto failed
copy D:\USOS.SHH C:\WINSETUP /y >nul
if errorlevel 1 goto failed
:csm_w3_done
rem Windows Setup needs the original DOS XMS manager after a cold restart.
rem Under CSMWrap HIMEM picks A20 handler 3, which leaves A20 off: /M:2.
rem (No IF with a redirection: COMMAND.COM opens the file even when false.)
if exist D:\CSMWRAP.TAG goto himem_csmwrap
echo DEVICE=C:\DOS\HIMEM.SYS /TESTMEM:OFF>C:\CONFIG.SYS
goto himem_done
:himem_csmwrap
echo DEVICE=C:\DOS\HIMEM.SYS /TESTMEM:OFF /M:2>C:\CONFIG.SYS
:himem_done
echo DOS=HIGH>>C:\CONFIG.SYS
echo FILES=40>>C:\CONFIG.SYS
echo BUFFERS=20>>C:\CONFIG.SYS
echo LASTDRIVE=Z>>C:\CONFIG.SYS
echo SHELL=C:\COMMAND.COM C:\ /E:2048 /P>>C:\CONFIG.SYS
echo C:\USOSW3\W3START.BAT>>C:\AUTOEXEC.BAT
cls
echo USOS - stage 1 completed.
echo.
echo DOS and Windows Setup files are ready on the target disk.
echo Remove USOS USB, then press Enter to restart from the target disk.
echo Original Windows Setup will start automatically.
echo After Setup, USOS prepares a Windows and DOS start menu.
echo A final restart will load that menu and its new settings.
goto restart_ready
:dos_done
cls
echo USOS - installation completed.
echo.
echo MS-DOS installation completed.
echo Remove USOS USB, then press Enter to restart from the target disk.
:restart_ready
echo.
echo REBOOT is prepared below. Press Enter when ready, or Esc to clear it.
echo.
prompt $p$g
D:
cd \
D:\REBOOT.COM /P
goto end
:failed
echo.
echo USOS: INSTALLATION FAILED. Do not treat this disk as complete.
echo Review the preceding error and restart from USOS to retry.
:end
