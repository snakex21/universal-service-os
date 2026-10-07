@echo off
rem USOS: Setup of Windows 1.0x, 2.x, Windows/386 2.x and 3.0 (W3START.BAT).
rem It reads its diskettes from drive A: only (label files such as
rem SETUP.LBL). A: becomes C:\WINSETUP, which holds the files of every
rem diskette, so each "insert disk" prompt is already satisfied. Setup asks
rem its questions itself (keyboard through the BIOS, also a USB keyboard
rem under CSMWrap); docs/windows-early-2026-10-07.md.
rem USOSKBC: the answers from SETUP.KEY (typed when their page is on the
rem screen) and the USB keyboard through the 8042 for Setup's Windows part.
if not exist C:\USOSW3\SETUP.KEY goto keys_done
if exist C:\DOS\USOSKBC.COM C:\DOS\USOSKBC.COM /R C:\USOSW3\SETUP.KEY
:keys_done
C:\DOS\SUBST.EXE A: C:\WINSETUP
if errorlevel 1 goto failed
A:
SETUP.EXE
C:
cd \
C:\DOS\SUBST.EXE A: /D
goto end
:failed
echo USOS: SUBST A: C:\WINSETUP failed; Setup needs it for its diskettes.
:end
