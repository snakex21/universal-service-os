@echo off
rem build.cmd - build AHCINT 1.3.0.0-usos2 (i386, free) with WDK 7.1
rem (7600.16385.1) from src\ in this folder (upstream v1.3.0.0 plus
rem patches\0001-usos1-flush-cache.patch, already applied).
rem
rem   tools\vendor\ahcint\1.3.0.0-usos2\build.cmd [workdir]
rem
rem Needs tools\WinDDK71 (or %WDKROOT%), see docs\BUILDING.md. Output:
rem <workdir>\out\ahcint.sys. Nothing is copied into the repository.
rem
rem Target: WDK 7.1 "x86 WXP" (the oldest x86 target of WDK 7.1). Upstream
rem builds with the Server 2003 SP1 DDK. The binary is only staged for
rem Windows 2000; tools\tests\test_w2k_staging.py checks that every import
rem resolves against the Windows 2000 SP4 kernel and scsiport (forwarders
rem followed) before a build is pinned in manifest.json.
setlocal
set "HERE=%~dp0"
set "REPO=%HERE%..\..\..\.."
for %%I in ("%REPO%") do set "REPO=%%~fI"
if "%WDKROOT%"=="" set "WDKROOT=%REPO%\tools\WinDDK71"
if not exist "%WDKROOT%\bin\setenv.bat" (
  echo WDK 7.1 not found at "%WDKROOT%" - see docs\BUILDING.md
  exit /b 2
)
set "WORK=%~1"
if "%WORK%"=="" set "WORK=%TEMP%\ahcint-usos2-build"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%" || exit /b 2
xcopy /e /i /q "%HERE%src" "%WORK%\src" >nul || exit /b 3
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% fre x86 WXP no_oacr && set "BUILD_ALT_DIR=fre" && cd /d "%WORK%\src\2KXP" && build -cZ"
if not exist "%WORK%\src\2KXP\objfre\i386\ahcint.sys" (
  echo build failed - see %WORK%\src\2KXP\buildfre*.log
  type "%WORK%\src\2KXP\buildfre_*.err" 2>nul
  type "%WORK%\src\2KXP\build*.err" 2>nul
  exit /b 4
)
mkdir "%WORK%\out" 2>nul
copy /y "%WORK%\src\2KXP\objfre\i386\ahcint.sys" "%WORK%\out\ahcint.sys" >nul
echo built: %WORK%\out\ahcint.sys
exit /b 0
