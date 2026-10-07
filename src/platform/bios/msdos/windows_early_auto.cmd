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
rem Windows 3.0 (SYSTEM\DOSX.EXE = standard mode present): real mode by
rem default. Under CSMWrap 386 enhanced mode hangs in the BIOS USB code (V86)
rem and standard mode stopped at the logo in QEMU; the menu offers WIN /S.
if not exist C:\WINDOWS\SYSTEM\DOSX.EXE goto plain
if "%CONFIG%"=="WINREAL" goto standard
WIN.COM /R
goto end
:standard
WIN.COM /S
goto end
:plain
WIN.COM
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
