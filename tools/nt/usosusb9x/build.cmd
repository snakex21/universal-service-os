@echo off
rem build.cmd - build usosusb.mpd (USOS USB disk service SCSI miniport for
rem Windows 95 OSR2 / 98 / 98 SE / Me, i386, free) with WDK 7.1 (7600.16385.1).
rem
rem   tools\nt\usosusb9x\build.cmd w9x [workdir]
rem
rem Needs tools\WinDDK71 (or %WDKROOT%), see docs\BUILDING.md. Output:
rem tools\nt\usosusb9x\bin\W9X\usosusb.mpd (PE 4.00, SCSIPORT.SYS imports
rem only; tools\tests\usb9x\test_usosusb9x.py checks the committed binary).
rem The slot state machine src\platform\bios\win9x\usosuds_slot.c and the ABI
rem header usosuds.h are copied into the work copy next to usosusb.c.
setlocal
set "HERE=%~dp0"
set "REPO=%HERE%..\..\.."
for %%I in ("%REPO%") do set "REPO=%%~fI"
if "%WDKROOT%"=="" set "WDKROOT=%REPO%\tools\WinDDK71"
if not exist "%WDKROOT%\bin\setenv.bat" (
  echo WDK 7.1 not found at "%WDKROOT%" - see docs\BUILDING.md
  exit /b 2
)
if /i not "%~1"=="w9x" (
  echo usage: build.cmd w9x [workdir]
  exit /b 1
)
set "WORK=%~2"
if "%WORK%"=="" set "WORK=%TEMP%\usosusb9x-build"
set "WORK=%WORK%\W9X"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%" || exit /b 2
xcopy /e /i /q "%HERE%src" "%WORK%\src" >nul || exit /b 3
copy /y "%REPO%\src\platform\bios\win9x\usosuds_slot.c" "%WORK%\src\" >nul || exit /b 3
copy /y "%REPO%\src\platform\bios\win9x\usosuds.h" "%WORK%\src\" >nul || exit /b 3
set "C_DEFINES="
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% fre x86 WXP no_oacr && set "BUILD_ALT_DIR=fre" && cd /d "%WORK%\src\W9X" && build -cZ"
if not exist "%WORK%\src\W9X\objfre\i386\usosusb.sys" (
  echo build failed - see %WORK%\src\W9X\buildfre*.log
  type "%WORK%\src\W9X\buildfre*.err" 2>nul
  type "%WORK%\src\W9X\buildfre*.wrn" 2>nul
  exit /b 4
)
type "%WORK%\src\W9X\buildfre*.wrn" 2>nul
python "%REPO%\tools\nt4\pe_nt4_version.py" --version 4.00 "%WORK%\src\W9X\objfre\i386\usosusb.sys" >nul || exit /b 5
mkdir "%HERE%bin\W9X" 2>nul
copy /y "%WORK%\src\W9X\objfre\i386\usosusb.sys" "%HERE%bin\W9X\usosusb.mpd" >nul || exit /b 6
echo built: %HERE%bin\W9X\usosusb.mpd
exit /b 0
