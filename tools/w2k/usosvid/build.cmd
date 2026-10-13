@echo off
rem build.cmd - build bootvid.dll (i386, free) with WDK 7.1 (7600.16385.1)
rem from src\ in this folder.
rem
rem   tools\w2k\usosvid\build.cmd [workdir]
rem
rem Needs tools\WinDDK71 (or %WDKROOT%), see docs\BUILDING.md. Output:
rem <workdir>\out\bootvid.dll. Nothing is copied into the repository.
rem Target: WDK 7.1 "x86 WXP" environment;
rem tools\tests\test_w2k_staging.py checks that every import of
rem the pinned binary resolves on the Windows 2000 SP4 kernel (EXPORT_DRIVER: the
rem linker names it bootvid.sys; it is copied out as bootvid.dll).
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
if "%WORK%"=="" set "WORK=%TEMP%\usosvid-build"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%" || exit /b 2
xcopy /e /i /q "%HERE%src" "%WORK%\src" >nul || exit /b 3
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% fre x86 WXP no_oacr && set "BUILD_ALT_DIR=fre" && cd /d "%WORK%\src" && build -cZ"
if not exist "%WORK%\src\objfre\i386\bootvid.sys" (
  echo build failed - see %WORK%\src\buildfre*.log
  type "%WORK%\src\buildfre*.err" 2>nul
  exit /b 4
)
mkdir "%WORK%\out" 2>nul
copy /y "%WORK%\src\objfre\i386\bootvid.sys" "%WORK%\out\bootvid.dll" >nul
echo built: %WORK%\out\bootvid.dll
exit /b 0
