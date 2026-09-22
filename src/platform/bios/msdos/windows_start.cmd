@echo off
if exist C:\WINDOWS\WIN.COM goto installed
C:
cd \WINSETUP
SETUP.EXE
if exist C:\WINDOWS\WIN.COM goto installed
echo Windows Setup has not finished. Restart to retry Setup.
goto end
:installed
rem Transfer to a separate batch before replacing AUTOEXEC.BAT.
C:\USOSW3\WINMENU.BAT
:end
