@echo off
prompt $p$g
path C:\DOS;C:\WINDOWS;C:\PROGRAMS
set TEMP=C:\TEMP
rem Windows 1.0x, 2.x, Windows/386 2.x and 3.0 (W1CONFIG.SYS start menu).
rem Default items: USOSV10, VBMOUSE, USOSKBC /R /M, then WIN; no USOSWHER.
rem Diagnostic items only (W1CONFIG.SYS submenu DIAG, from the Windows 2.03
rem logo hang on the X470, fixed by USOSV10 - D6 PASS 2026-10-09): D1
rem default + USOSWHER, D2 without USOSKBC, D4 without HIMEM and VBMOUSE, D5
rem only SETVER + USOSWHER (without USOSV10), D6 = D5 + USOSV10.
rem Log: C:\USOS\DIAG\Dn.TXT.
set UDIAG=
if "%CONFIG%"=="D1WHERE" set UDIAG=D1
if "%CONFIG%"=="D2NOKBC" set UDIAG=D2
if "%CONFIG%"=="D4CLEAN" set UDIAG=D4
if "%CONFIG%"=="D5MIN" set UDIAG=D5
if "%CONFIG%"=="D6V10" set UDIAG=D6
rem USOSV10 first: INT 10h on its own 2 KiB stack. WIN.COM 2.x calls the video
rem BIOS for its logo with about 200 bytes of stack left above its own code;
rem a modern video BIOS (RX 560) needs more and overwrites that code (hang at
rem the logo). D5 leaves it out as the control item.
if "%UDIAG%"=="D5" goto v10_done
if exist C:\DOS\USOSV10.COM C:\DOS\USOSV10.COM
:v10_done
rem Under CSMWrap (files present): VBMOUSE (DOS programs) and USOSKBC /R /M:
rem /R the USB keyboard relayed through the 8042 for KEYBOARD.DRV of Windows
rem 1.0x-3.0 (USOSKEY.DRV needs Windows 3.1); /M the USB mouse for MOUSE.DRV
rem of Windows 2.x/3.0 (PS/2 path: BIOS INT 15h C2xx, INT 74h after each
rem packet, which SeaBIOS delivers from its timer and not as IRQ 12).
rem Windows 1.0x: USOSMS1.DRV (bound as MOUSE.DRV) takes the same INT 74h.
if "%UDIAG%"=="D4" goto kbc_load
if "%UDIAG%"=="D5" goto tsr_done
if "%UDIAG%"=="D6" goto tsr_done
if exist C:\DOS\VBMOUSE.EXE C:\DOS\VBMOUSE.EXE
if "%UDIAG%"=="D2" goto tsr_done
:kbc_load
if exist C:\DOS\USOSKBC.COM C:\DOS\USOSKBC.COM /R /M
:tsr_done
rem Network (C:\NET, staged by INSTALL.BAT): USOSPKT + DHCP before WIN, as
rem in the MS-DOS install, so mTCP works at the DOS prompt and after leaving
rem Windows. About 42 KiB conventional memory; no supported NIC = one line,
rem nothing resident; no DHCP answer = at most about 12 s (Esc skips).
rem The diagnostic items stay without it.
if not "%UDIAG%"=="" goto net_skip
if exist C:\NET\NETSTART.BAT call C:\NET\NETSTART.BAT
:net_skip
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
rem USOSV10 run again only reports (deepest INT 10h stack use so far).
if "%UDIAG%"=="D5" goto v10_log1
C:\DOS\USOSV10.COM>>C:\USOS\DIAG\%UDIAG%.TXT
:v10_log1
echo ==== WIN started (no "WIN returned" below = hang)>>C:\USOS\DIAG\%UDIAG%.TXT
:win_go
rem VGA probe, once per install (C:\USOS\DIAG\VGAREG.TXT): Windows 3.x
rem VGA.DRV reads the VGA registers back when it draws the pointer; the
rem probe logs whether this card returns what was written (X470 redraw).
if exist C:\USOS\DIAG\VGAREG.TXT goto vgar_done
if not exist C:\DOS\USOSVGAR.COM goto vgar_done
if not exist C:\USOS\NUL md C:\USOS
if not exist C:\USOS\DIAG\NUL md C:\USOS\DIAG
C:\DOS\USOSVGAR.COM>C:\USOS\DIAG\VGAREG.TXT
:vgar_done
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
if "%UDIAG%"=="D5" goto v10_log2
C:\DOS\USOSV10.COM>>C:\USOS\DIAG\%UDIAG%.TXT
:v10_log2
echo USOS %UDIAG%: dziennik w C:\USOS\DIAG\%UDIAG%.TXT
:end_msg
echo.
echo Aby ponownie wybrac tryb uruchomienia, zrestartuj komputer.
