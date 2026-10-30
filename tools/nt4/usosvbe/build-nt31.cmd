@echo off
rem build-nt31.cmd - build usosvbe.sys (VBE video miniport) for Windows NT 3.1
rem (i386, free) with WDK 7.1 (7600.16385.1) from the same src\mini as build.cmd.
rem
rem   tools\nt4\usosvbe\build-nt31.cmd [workdir]
rem
rem Needs tools\WinDDK71 (or %WDKROOT%), see docs\BUILDING.md. Output:
rem tools\nt4\usosvbe\bin\nt31\i386\usosvbe.sys, marked PE 3.10 by
rem tools\nt4\pe_nt4_version.py. -DUSOSVBE_NT3 -DUSOSVBE_NT31: the NT 3.x build
rem plus the NT 3.1 start mode (Full HD, else 1024x768 / 800x600 first in the
rem mode list; NT 3.1 has no ChangeDisplaySettings). The display driver stays
rem the CD's own framebuf.dll. tools\tests\test_nt3_usosvbe.py checks every
rem import against the NT 3.1 export lists.
setlocal
set "HERE=%~dp0"
set "REPO=%HERE%..\..\.."
for %%I in ("%REPO%") do set "REPO=%%~fI"
if "%WDKROOT%"=="" set "WDKROOT=%REPO%\tools\WinDDK71"
if not exist "%WDKROOT%\bin\setenv.bat" (
  echo WDK 7.1 not found at "%WDKROOT%" - see docs\BUILDING.md
  exit /b 2
)
set "WORK=%~1"
if "%WORK%"=="" set "WORK=%TEMP%\usosvbe-nt31-build"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%" || exit /b 2
xcopy /e /i /q "%HERE%src\mini" "%WORK%\mini" >nul || exit /b 3
copy /y "%REPO%\tools\display_modes.h" "%WORK%\mini\display_modes.h" >nul || exit /b 3
set "SUBSYSTEM_VERSION=4.00"
set "C_DEFINES=-DUSOSVBE_NT3 -DUSOSVBE_NT31"
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% fre x86 WXP no_oacr && set "BUILD_ALT_DIR=fre" && cd /d "%WORK%\mini" && build -cZ"
if not exist "%WORK%\mini\objfre\i386\usosvbe.sys" (
  echo build failed - see %WORK%\mini\buildfre*.log
  type "%WORK%\mini\buildfre*.err" 2>nul
  exit /b 4
)
python "%REPO%\tools\nt4\pe_nt4_version.py" --version 3.10 "%WORK%\mini\objfre\i386\usosvbe.sys" >nul || exit /b 5
mkdir "%HERE%bin\nt31\i386" 2>nul
copy /y "%WORK%\mini\objfre\i386\usosvbe.sys" "%HERE%bin\nt31\i386\usosvbe.sys" >nul || exit /b 6
echo built: %HERE%bin\nt31\i386\usosvbe.sys
exit /b 0
