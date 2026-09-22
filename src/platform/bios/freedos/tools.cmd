@echo off
cls
echo USOS - FreeDOS tools
echo.
echo Files from USB: Utilities\FreeDOS\Programs
echo Available here: C:\PROGRAMS
echo C: is a RAM disk. Files created here disappear after a restart.
echo.
echo File manager: arrows and Enter select a folder or run a program.
echo Ctrl+Enter puts the selected filename on the command line.
echo Add any required arguments there, then press Enter to run it.
echo F3 views a file. F10 closes the file manager to the DOS prompt.
echo.
pause
cd \PROGRAMS
C:\DZ.EXE /T /CC:\DZCFG C:\PROGRAMS
echo.
echo Type TOOLS to reopen the file manager, or REBOOT to return to USOS.
