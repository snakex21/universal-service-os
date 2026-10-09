@echo off
prompt $p$g
path C:\DOS;C:\WINDOWS;C:\PROGRAMS
set TEMP=C:\TEMP
rem Windows 1.0x, 2.x, Windows/386 2.x and 3.0 (W1CONFIG.SYS start menu).
rem Diagnostic items (W1CONFIG.SYS submenu DIAG; Windows 2.03 hangs at its
rem logo on the X470): D1 default + USOSWHER, D2 without USOSKBC, D4 without
rem HIMEM and VBMOUSE, D5 only SETVER + USOSWHER. Log: C:\USOS\DIAG\Dn.TXT.
set UDIAG=
if "%CONFIG%"=="D1WHERE" set UDIAG=D1
if "%CONFIG%"=="D2NOKBC" set UDIAG=D2
if "%CONFIG%"=="D4CLEAN" set UDIAG=D4
if "%CONFIG%"=="D5MIN" set UDIAG=D5
rem Under CSMWrap (files present): VBMOUSE (DOS programs) and USOSKBC /R,
rem the USB keyboard relayed through the 8042 for KEYBOARD.DRV of Windows
rem 1.0x-3.0 (USOSKEY.DRV needs Windows 3.1).
if "%UDIAG%"=="D4" goto kbc_load
if "%UDIAG%"=="D5" goto tsr_done
if exist C:\DOS\VBMOUSE.EXE C:\DOS\VBMOUSE.EXE
if "%UDIAG%"=="D2" goto tsr_done
:kbc_load
if exist C:\DOS\USOSKBC.COM C:\DOS\USOSKBC.COM /R
:tsr_done
if "%CONFIG%"=="DOSONLY" goto dos
if "%UDIAG%"=="" goto win_go
rem USOSWHER last, so its INT 15h/21h hooks see the calls of the other
rem TSRs; /G draws CS:IP also over the graphical logo.
if "%UDIAG%"=="D2" goto diag_log
if "%UDIAG%"=="D4" goto diag_log
if exist C:\DOS\USOSWHER.COM C:\DOS\USOSWHER.COM /G
:diag_log
if not exist C:\USOS\NUL md C:\USOS
if not exist C:\USOS\DIAG\NUL md C:\USOS\DIAG
echo ==== USOS %UDIAG% (%CONFIG%): start>>C:\USOS\DIAG\%UDIAG%.TXT
ver>>C:\USOS\DIAG\%UDIAG%.TXT
rem Load addresses: WIN.COM takes the first free block of this list;
rem USOSWHER shows the current PSP and its owner name live.
C:\DOS\MEM.EXE /D>>C:\USOS\DIAG\%UDIAG%.TXT
C:\DOS\MEM.EXE /C>>C:\USOS\DIAG\%UDIAG%.TXT
echo ==== WIN started (no "WIN returned" below = hang)>>C:\USOS\DIAG\%UDIAG%.TXT
:win_go
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
if "%UDIAG%"=="" goto end_msg
echo ==== WIN returned>>C:\USOS\DIAG\%UDIAG%.TXT
echo USOS %UDIAG%: dziennik w C:\USOS\DIAG\%UDIAG%.TXT
:end_msg
echo.
echo Aby ponownie wybrac tryb uruchomienia, zrestartuj komputer.
