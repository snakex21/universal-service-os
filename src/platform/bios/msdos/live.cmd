@echo off
echo Preparing MS-DOS tools in RAM...
call C:\PREPDOS.BAT C:\DOSFILES C:\DOS C:
if not exist C:\DOS\READY.TAG goto failed
if not exist C:\TEMP\nul md C:\TEMP
if not exist C:\PROGRAMS\nul md C:\PROGRAMS
set TEMP=C:\TEMP
path C:\DOS;C:\PROGRAMS;C:\
prompt $p$g
cls
ver
echo.
echo USOS - DOS session from USB
echo C: is a RAM disk. Changes disappear when the computer is turned off.
echo Programs copied from USB are in C:\PROGRAMS.
echo Use CD and DIR to select a program, then type its EXE, COM or BAT name.
echo.
cd \PROGRAMS
dir /w
goto end
:failed
echo USOS: DOS tools could not be prepared. See C:\DOS\DOSERR.TAG.
:end
