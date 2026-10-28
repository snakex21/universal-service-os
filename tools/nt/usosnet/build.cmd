@echo off
rem build.cmd - build usosnet.sys (USOS NDIS 5.0 Ethernet miniport, i386,
rem free) and usosnet4.sys (its NDIS 4.0 build) with WDK 7.1 (7600.16385.1).
rem
rem   tools\nt\usosnet\build.cmd [workdir]
rem
rem Needs tools\WinDDK71 (or %WDKROOT%), see docs\BUILDING.md. Output:
rem tools\nt\usosnet\bin\i386\usosnet.sys - one binary for Windows 98 /
rem 98 SE / Me (NDIS.VXD) and Windows 2000 / XP / Server 2003 x86 (PE 4.00),
rem tools\nt\usosnet\bin\i386\usosnet4.sys - the same source built as an
rem NDIS 4.0 miniport (src4) for Windows 95 OSR2 and Windows NT 4.0.
rem USOSNET_ONLY=5 builds only usosnet.sys, USOSNET_ONLY=4 only usosnet4.sys.
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
rem src4 = the src files + its own sources / usosnet4.rc (build takes no ..\ paths)
xcopy /e /i /q "%HERE%src" "%WORK%\src4" >nul || exit /b 3
xcopy /e /i /q /y "%HERE%src4" "%WORK%\src4" >nul || exit /b 3
mkdir "%HERE%bin\i386" 2>nul
if not "%USOSNET_ONLY%"=="4" call :one src usosnet || exit /b
if not "%USOSNET_ONLY%"=="5" call :one src4 usosnet4 || exit /b
exit /b 0

:one
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% fre x86 WXP no_oacr && set "BUILD_ALT_DIR=fre" && cd /d "%WORK%\%1" && build -cZ"
if not exist "%WORK%\%1\objfre\i386\%2.sys" (
  echo build failed - see %WORK%\%1\buildfre*.log
  type "%WORK%\%1\buildfre*.err" 2>nul
  type "%WORK%\%1\buildfre*.wrn" 2>nul
  exit /b 4
)
python "%REPO%\tools\nt4\pe_nt4_version.py" --version 4.00 "%WORK%\%1\objfre\i386\%2.sys" >nul || exit /b 5
copy /y "%WORK%\%1\objfre\i386\%2.sys" "%HERE%bin\i386\%2.sys" >nul || exit /b 6
echo built: %HERE%bin\i386\%2.sys
exit /b 0
