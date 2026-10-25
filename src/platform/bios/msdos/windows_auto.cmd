@echo off
prompt $p$g
path C:\DOS;C:\WINDOWS;C:\PROGRAMS
set TEMP=C:\TEMP
rem Network (C:\NET, staged by INSTALL.BAT): USOSPKT + DHCP before WIN, as
rem in the MS-DOS install (mTCP at the DOS prompt and after leaving Windows).
if exist C:\NET\NETSTART.BAT call C:\NET\NETSTART.BAT
if "%CONFIG%"=="DOSONLY" goto dos
if "%CONFIG%"=="WINSET" goto settings
if not exist C:\WINDOWS\WIN.COM goto missing
C:
cd \WINDOWS
rem USOSWIN=1 while Windows runs (WINRUN.BAT: WIN in its DOS window).
set USOSWIN=1
if "%CONFIG%"=="WIN386" goto enhanced
rem Windows for Workgroups 3.11 runs in 386 enhanced mode only.
if exist C:\WINSETUP\WFWSETUP.DL_ goto enhanced
echo Windows 3.x - standard mode, no disk cache.
WIN.COM /S /B
goto end
:enhanced
echo Windows 3.x - 386 enhanced mode test.
echo If Windows does not start, restart and choose standard mode.
WIN.COM /3 /B
goto end
:settings
if not exist C:\WINDOWS\SETUP.EXE goto missing
rem Maintenance Setup may not locate compressed drivers in the flat source.
rem Supply the original PS/2 driver only when no installed copy exists.
if exist C:\WINDOWS\SYSTEM\MOUSE.DRV goto mouse_ready
if not exist C:\WINSETUP\MOUSE.DRV goto compressed_mouse
copy C:\WINSETUP\MOUSE.DRV C:\WINDOWS\SYSTEM\MOUSE.DRV /y >nul
if errorlevel 1 goto mouse_failed
goto mouse_ready
:compressed_mouse
if not exist C:\WINSETUP\MOUSE.DR_ goto mouse_failed
C:\DOS\EXPAND.EXE C:\WINSETUP\MOUSE.DR_ C:\WINDOWS\SYSTEM\MOUSE.DRV
if errorlevel 1 goto mouse_failed
:mouse_ready
C:
cd \WINDOWS
echo For a PS/2 mouse choose Microsoft or IBM PS/2 in Setup.
echo If Setup asks about the existing MOUSE.DRV, keep it with Enter.
pause
SETUP.EXE
goto end
:mouse_failed
echo Could not prepare the mouse driver from C:\WINSETUP.
echo Check the source files and the free disk space.
goto end
:dos
ver
echo DOS programs are in C:\PROGRAMS.
goto end
:missing
echo Windows files are missing in C:\WINDOWS.
:end
set USOSWIN=
rem WIN typed at the DOS prompt from now on: the mode of the default menu item
rem (C:\USOSW3\WINRUN.BAT; WIN /3 and other arguments unchanged). DOSKEY
rem (about 4 KiB conventional memory) only after Windows or the menu item, so
rem Windows started from the menu runs without it.
if not exist C:\USOSW3\WINRUN.BAT goto macro_ok
if not exist C:\DOS\DOSKEY.COM goto macro_ok
C:\DOS\DOSKEY.COM win=C:\USOSW3\WINRUN.BAT $* >nul
:macro_ok
echo.
echo To choose the start mode again, restart the computer.
