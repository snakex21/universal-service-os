@echo off
prompt $p$g
path C:\DOS;C:\WINDOWS;C:\PROGRAMS
set TEMP=C:\TEMP
rem Windows 1.0x, 2.x, Windows/386 2.x and 3.0 (W1CONFIG.SYS start menu).
if "%CONFIG%"=="DOSONLY" goto dos
C:
if exist C:\WIN386\WIN386.EXE goto w386dir
if exist C:\WINDOWS\WIN386.EXE goto w386win
if not exist C:\WINDOWS\WIN.COM goto missing
cd \WINDOWS
if "%CONFIG%"=="WINREAL" goto real
WIN.COM
goto end
:real
WIN.COM /R
goto end
:w386dir
cd \WIN386
WIN386.EXE
goto end
:w386win
cd \WINDOWS
WIN386.EXE
goto end
:dos
ver
echo Programy DOS sa w C:\PROGRAMS.
goto end
:missing
echo Brakuje plikow Windows w C:\WINDOWS.
:end
echo.
echo Aby ponownie wybrac tryb uruchomienia, zrestartuj komputer.
