@echo off
if exist C:\WINDOWS\WIN.COM goto installed
C:
cd \WINSETUP
rem Prepared under CSMWrap: batch Setup, no keyboard needed (USB keyboard).
if not exist USOS.SHH goto interactive_setup
SETUP.EXE /H:USOS.SHH
goto setup_done
:interactive_setup
SETUP.EXE
:setup_done
if exist C:\WINDOWS\WIN.COM goto installed
echo Windows Setup has not finished. Restart to retry Setup.
goto end
:installed
rem Transfer to a separate batch before replacing AUTOEXEC.BAT.
C:\USOSW3\WINMENU.BAT
:end
