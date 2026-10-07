@echo off
if exist C:\WINDOWS\WIN.COM goto installed
rem Windows/386 2.x installs WIN386.EXE (default folder C:\WIN386).
if exist C:\WIN386\WIN386.EXE goto installed
if exist C:\WINDOWS\WIN386.EXE goto installed
C:
cd \WINSETUP
rem Windows 1.0x / 2.x / 3.0: W1SETUP.BAT (only copied for them). Windows
rem 3.1 / WfW 3.11 Setup scans the batch files of AUTOEXEC.BAT for programs
rem it does not accept, so this file names none of them.
if exist C:\USOSW3\W1SETUP.BAT goto early_setup
rem Prepared under CSMWrap: batch Setup, no keyboard needed (USB keyboard).
if not exist USOS.SHH goto interactive_setup
SETUP.EXE /H:USOS.SHH
goto setup_done
:interactive_setup
SETUP.EXE
goto setup_done
:early_setup
call C:\USOSW3\W1SETUP.BAT
:setup_done
if exist C:\WINDOWS\WIN.COM goto installed
if exist C:\WIN386\WIN386.EXE goto installed
if exist C:\WINDOWS\WIN386.EXE goto installed
echo Windows Setup has not finished. Restart to retry Setup.
goto end
:installed
rem Transfer to a separate batch before replacing AUTOEXEC.BAT.
C:\USOSW3\WINMENU.BAT
:end
