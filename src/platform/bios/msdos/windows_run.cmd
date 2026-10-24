@echo off
rem USOS: WIN typed at the DOS prompt (DOSKEY macro win=C:\USOSW3\WINRUN.BAT $*,
rem loaded by the start menu W3AUTO.BAT once Windows or the menu item is done).
rem A macro is expanded before COMMAND.COM searches the current directory, so
rem it also wins in C:\WINDOWS, where WIN.COM itself would start first.
rem Without arguments: the mode of the menu's default item. Under CSMWrap the
rem keyboard and mouse of 386 enhanced mode go through the BIOS USB code and
rem lag or stop; standard mode has them. With arguments: unchanged, so
rem WIN /3 still starts 386 enhanced mode and WIN PROGMAN works.
rem Windows 3.0 (W1AUTO.BAT, EARLY.TAG): real mode, as the menu default;
rem its standard mode (WIN /S, DOSX) resets the X470 (2026-10-24).
if exist C:\USOSW3\EARLY.TAG goto early
if not "%1"=="" goto pass
rem Windows for Workgroups 3.11 runs in 386 enhanced mode only.
if exist C:\WINSETUP\WFWSETUP.DL_ goto enhanced
C:\WINDOWS\WIN.COM /S /B
goto end
:enhanced
C:\WINDOWS\WIN.COM /3 /B
goto end
:early
rem Windows 3.0 without VBMOUSE: real-mode WINOLDAP resets INT 33h around
rem DOS programs and VBMOUSE would take the INT 15h C207h callback from
rem MOUSE.DRV (dead Windows mouse after the DOS prompt, X470 2026-10-24).
rem W1AUTO.BAT loads VBMOUSE last, so "uninstall" works; reloaded after
rem WIN only when it was unloaded here. CTTY NUL: its stderr lines.
set USOSVBM=
if not exist C:\DOS\VBMOUSE.EXE goto e_win
ctty nul
C:\DOS\VBMOUSE.EXE uninstall
ctty con
if not errorlevel 1 set USOSVBM=1
:e_win
if not "%1"=="" goto e_pass
C:\WINDOWS\WIN.COM /R
goto e_back
:e_pass
C:\WINDOWS\WIN.COM %1 %2 %3 %4 %5 %6 %7 %8 %9
:e_back
if not "%USOSVBM%"=="1" goto end
set USOSVBM=
ctty nul
C:\DOS\VBMOUSE.EXE
ctty con
if not errorlevel 1 goto end
echo USOS: the DOS mouse driver (VBMOUSE) did not load.
goto end
:pass
C:\WINDOWS\WIN.COM %1 %2 %3 %4 %5 %6 %7 %8 %9
:end
