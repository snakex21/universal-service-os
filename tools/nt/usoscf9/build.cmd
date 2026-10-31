@echo off
rem build.cmd - build usoscf9.sys (i386, free) with WDK 7.1 (7600.16385.1)
rem from src\ in this folder (docs\nvme-nt6-2026-10-12.md section 21.3).
rem
rem   tools\nt\usoscf9\build.cmd [workdir]
rem
rem Needs tools\WinDDK71 (or %WDKROOT%), see docs\BUILDING.md. Output:
rem <workdir>\out\usoscf9.sys; the pinned copy is bin\i386\usoscf9.sys.
rem Target: WDK 7.1 "x86 WIN7" environment (loaded in the Windows 8 / 8.1 /
rem 10 x86 WinPE).
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
if "%WORK%"=="" set "WORK=%TEMP%\usoscf9-build"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%" || exit /b 2
xcopy /e /i /q "%HERE%src" "%WORK%\src" >nul || exit /b 3
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% fre x86 WIN7 no_oacr && set "BUILD_ALT_DIR=fre" && cd /d "%WORK%\src" && build -cZ"
if not exist "%WORK%\src\objfre\i386\usoscf9.sys" (
  echo build failed - see %WORK%\src\buildfre*.log
  type "%WORK%\src\buildfre*.err" 2>nul
  exit /b 4
)
mkdir "%WORK%\out" 2>nul
copy /y "%WORK%\src\objfre\i386\usoscf9.sys" "%WORK%\out\usoscf9.sys" >nul
echo built: %WORK%\out\usoscf9.sys
exit /b 0
