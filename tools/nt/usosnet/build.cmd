@echo off
rem build.cmd - build usosnet.sys (USOS NDIS 5.0 Ethernet miniport, i386,
rem free) with WDK 7.1 (7600.16385.1).
rem
rem   tools\nt\usosnet\build.cmd [workdir]
rem
rem Needs tools\WinDDK71 (or %WDKROOT%), see docs\BUILDING.md. Output:
rem tools\nt\usosnet\bin\i386\usosnet.sys - one binary for Windows 98 /
rem 98 SE / Me (NDIS.VXD) and Windows 2000 / XP / Server 2003 x86 (PE 4.00).
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
if "%WORK%"=="" set "WORK=%TEMP%\usosnet-build"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%" || exit /b 2
xcopy /e /i /q "%HERE%src" "%WORK%\src" >nul || exit /b 3
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% fre x86 WXP no_oacr && set "BUILD_ALT_DIR=fre" && cd /d "%WORK%\src" && build -cZ"
if not exist "%WORK%\src\objfre\i386\usosnet.sys" (
  echo build failed - see %WORK%\src\buildfre*.log
  type "%WORK%\src\buildfre*.err" 2>nul
  type "%WORK%\src\buildfre*.wrn" 2>nul
  exit /b 4
)
python "%REPO%\tools\nt4\pe_nt4_version.py" --version 4.00 "%WORK%\src\objfre\i386\usosnet.sys" >nul || exit /b 5
mkdir "%HERE%bin\i386" 2>nul
copy /y "%WORK%\src\objfre\i386\usosnet.sys" "%HERE%bin\i386\usosnet.sys" >nul || exit /b 6
echo built: %HERE%bin\i386\usosnet.sys
exit /b 0
