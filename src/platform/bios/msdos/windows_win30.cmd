@echo off
rem USOS, Windows 3.0: W1AUTO.BAT copies this file to C:\WINDOWS\WIN.BAT and
rem renames C:\WINDOWS\WIN.COM to WIN30.COM, so WIN typed anywhere runs
rem C:\USOSW3\WINRUN.BAT (already-running guard, start mode, VBMOUSE, log
rem C:\USOSW3\WINRUN.LOG), also in a DOS window of the running Windows, which
rem has no DOSKEY macro when Windows came from the start menu (X470
rem 2026-10-24: a second Windows started inside the DOS window).
C:\USOSW3\WINRUN.BAT %1 %2 %3 %4 %5 %6 %7 %8 %9
