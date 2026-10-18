@ECHO OFF
REM DOSMOUSE.BAT - USB mouse for DOS programs in MS-DOS mode of Windows
REM 95/98/98 SE under CSMWrap (docs/dos-mouse-2026-10-18.md).
REM Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
REM VBADOS VBMOUSE.EXE (INT 33h; reads the USB mouse through the SeaBIOS
REM PS/2 BIOS services INT 15h C2xxh) for one DOS session, unloaded again
REM before Windows starts: VBMOUSE next to the Windows 9x mouse stops
REM Windows, and in Windows USOSMOUS.DRV owns the BIOS mouse (C207h).
REM   DOSMOUSE        mouse on, a DOS prompt; EXIT unloads the driver and
REM                   leaves (in MS-DOS mode: back to Windows)
REM   DOSMOUSE SETUP  AUTOEXEC.BAT: CALL line at the end of DOSSTART.BAT
REM                   (Windows runs it for "Restart in MS-DOS mode")
IF "%1"=="SETUP" GOTO SETUP
C:\USOS9X\INWIN.COM
IF ERRORLEVEL 1 GOTO INWIN
C:\USOS9X\VBMOUSE.EXE
IF ERRORLEVEL 1 GOTO NOMOUSE
ECHO.
ECHO USOS: USB mouse for DOS programs is on (VBMOUSE).
ECHO Type EXIT to switch it off (in MS-DOS mode: and return to Windows).
:SHELL
%COMSPEC%
C:\USOS9X\VBMOUSE.EXE UNINSTALL
IF ERRORLEVEL 1 GOTO STUCK
EXIT
GOTO END
:STUCK
ECHO USOS: VBMOUSE could not be unloaded (INT 33h/2Fh hooked by another program).
ECHO Do not start Windows from here: restart the PC with Ctrl+Alt+Del.
GOTO SHELL
:NOMOUSE
ECHO USOS: VBMOUSE found no mouse (no USB mouse on the BIOS services).
GOTO END
:INWIN
ECHO USOS: DOSMOUSE runs only in MS-DOS mode, not in a window of Windows.
GOTO END
:SETUP
IF NOT EXIST C:\WINDOWS\COMMAND\FIND.EXE GOTO END
IF NOT EXIST C:\WINDOWS\DOSSTART.BAT GOTO ADD
C:\WINDOWS\COMMAND\FIND.EXE /I "DOSMOUSE" C:\WINDOWS\DOSSTART.BAT >NUL
IF NOT ERRORLEVEL 1 GOTO END
:ADD
ECHO.>>C:\WINDOWS\DOSSTART.BAT
ECHO CALL C:\USOS9X\DOSMOUSE.BAT>>C:\WINDOWS\DOSSTART.BAT
:END
