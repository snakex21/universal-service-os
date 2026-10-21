@echo off
rem build.cmd - build usosmpart.sys (USOS USB multi-partition disk filter,
rem free) with WDK 7.1 (7600.16385.1).
rem
rem   tools\nt\usosmpart\build.cmd <x86|amd64|nt6x64|all> [workdir]
rem
rem Needs tools\WinDDK71 (or %WDKROOT%), see docs\BUILDING.md. Output
rem (unsigned): tools\nt\usosmpart\bin\<i386|amd64|NT6\amd64>\usosmpart.sys.
rem   x86     Windows 2000 / XP / Server 2003 / 7 / 8.x x86 ("x86 WXP")
rem   amd64   XP x64 / Server 2003 x64 ("x64 WNET"), bin\amd64
rem   nt6x64  Vista / Server 2008 SP2 x64 in test mode ("x64 WLH"),
rem           bin\NT6\amd64; signed per build with the usosnvme amd64
rem           certificate by tools\build_usosnvme_nt6_signed.py
setlocal
set "HERE=%~dp0"
set "REPO=%HERE%..\..\.."
for %%I in ("%REPO%") do set "REPO=%%~fI"
if "%WDKROOT%"=="" set "WDKROOT=%REPO%\tools\WinDDK71"
if not exist "%WDKROOT%\bin\setenv.bat" (
  echo WDK 7.1 not found at "%WDKROOT%" - see docs\BUILDING.md
  exit /b 2
)
set "ARCH=%~1"
if /i "%ARCH%"=="all" (
  call "%~f0" x86 "%~2" || exit /b 1
  call "%~f0" amd64 "%~2" || exit /b 1
  call "%~f0" nt6x64 "%~2" || exit /b 1
  exit /b 0
)
set "ENVARGS=" & set "OBJ=" & set "OUT="
if /i "%ARCH%"=="x86"    set "ENVARGS=fre x86 WXP no_oacr" & set "OBJ=i386" & set "OUT=i386"
if /i "%ARCH%"=="amd64"  set "ENVARGS=fre x64 WNET no_oacr" & set "OBJ=amd64" & set "OUT=amd64"
if /i "%ARCH%"=="nt6x64" set "ENVARGS=fre x64 WLH no_oacr" & set "OBJ=amd64" & set "OUT=NT6\amd64"
if "%OBJ%"=="" (
  echo usage: build.cmd ^<x86^|amd64^|nt6x64^|all^> [workdir]
  exit /b 1
)
set "WORK=%~2"
if "%WORK%"=="" set "WORK=%TEMP%\usosmpart-build"
set "WORK=%WORK%\%ARCH%"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%" || exit /b 2
xcopy /e /i /q "%HERE%src" "%WORK%\src" >nul || exit /b 3
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% %ENVARGS% && set "BUILD_ALT_DIR=fre" && cd /d "%WORK%\src" && build -cZ"
if not exist "%WORK%\src\objfre\%OBJ%\usosmpart.sys" (
  echo build failed - see %WORK%\src\buildfre*.log
  type "%WORK%\src\buildfre*.err" 2>nul
  type "%WORK%\src\buildfre*.wrn" 2>nul
  exit /b 4
)
mkdir "%HERE%bin\%OUT%" 2>nul
copy /y "%WORK%\src\objfre\%OBJ%\usosmpart.sys" "%HERE%bin\%OUT%\usosmpart.sys" >nul || exit /b 6
echo built: %HERE%bin\%OUT%\usosmpart.sys
exit /b 0
