@echo off
rem build.cmd - build usosmpart.sys (USOS USB multi-partition disk filter,
rem free) with WDK 7.1 (7600.16385.1).
rem
rem   tools\nt\usosmpart\build.cmd <x86|amd64|all> [workdir]
rem
rem Needs tools\WinDDK71 (or %WDKROOT%), see docs\BUILDING.md. Output:
rem tools\nt\usosmpart\bin\<i386|amd64>\usosmpart.sys (unsigned; the x64
rem NT 6 package is signed per build by tools\build_usosmpart_nt6_signed.py).
rem   x86    Windows 2000 / XP / Server 2003 / Vista / 7 / 8.x x86 ("x86 WXP")
rem   amd64  XP x64 / Server 2003 x64 / Vista / 7 x64 ("x64 WNET")
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
  exit /b 0
)
set "ENVARGS=" & set "OBJ="
if /i "%ARCH%"=="x86"   set "ENVARGS=fre x86 WXP no_oacr" & set "OBJ=i386"
if /i "%ARCH%"=="amd64" set "ENVARGS=fre x64 WNET no_oacr" & set "OBJ=amd64"
if "%OBJ%"=="" (
  echo usage: build.cmd ^<x86^|amd64^|all^> [workdir]
  exit /b 1
)
set "WORK=%~2"
if "%WORK%"=="" set "WORK=%TEMP%\usosmpart-build"
set "WORK=%WORK%\%OBJ%"
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
mkdir "%HERE%bin\%OBJ%" 2>nul
copy /y "%WORK%\src\objfre\%OBJ%\usosmpart.sys" "%HERE%bin\%OBJ%\usosmpart.sys" >nul || exit /b 6
echo built: %HERE%bin\%OBJ%\usosmpart.sys
exit /b 0
