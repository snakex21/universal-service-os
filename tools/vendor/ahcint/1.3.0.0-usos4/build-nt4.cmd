@echo off
rem build-nt4.cmd - build AHCINT 1.3.0.0-usos4 for Windows NT 4.0 (i386,
rem free, AHCI_NT4) with WDK 7.1 (7600.16385.1) from src\ in this folder.
rem
rem   tools\vendor\ahcint\1.3.0.0-usos4\build-nt4.cmd [workdir]
rem
rem Needs tools\WinDDK71 (or %WDKROOT%), see docs\BUILDING.md. Output:
rem <workdir>\out\ahcint.sys. Nothing is copied into the repository.
rem
rem Same source as build.cmd; src\NT4WDK\sources adds -DAHCI_NT4 (the
rem upstream non-PnP ScsiPort path: no HBA reset, access range claimed,
rem INTx from config space) and _NT_TARGET_VERSION NT4 (PE subsystem 4.00).
rem Upstream builds this variant with Visual C++ 4.0 + NT4 DDK
rem (src\NT\build.bat). tools\tests\check_nt4_driver_imports.py checks
rem every import against the NT 4.0 SP6a kernel, HAL and scsiport.
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
if "%WORK%"=="" set "WORK=%TEMP%\ahcint-usos4-nt4-build"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%" || exit /b 2
xcopy /e /i /q "%HERE%src" "%WORK%\src" >nul || exit /b 3
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% fre x86 WXP no_oacr && set "BUILD_ALT_DIR=fre" && cd /d "%WORK%\src\NT4WDK" && build -cZ"
if not exist "%WORK%\src\NT4WDK\objfre\i386\ahcint.sys" (
  echo build failed - see %WORK%\src\NT4WDK\buildfre*.log
  type "%WORK%\src\NT4WDK\buildfre_*.err" 2>nul
  type "%WORK%\src\NT4WDK\build*.err" 2>nul
  exit /b 4
)
mkdir "%WORK%\out" 2>nul
copy /y "%WORK%\src\NT4WDK\objfre\i386\ahcint.sys" "%WORK%\out\ahcint.sys" >nul
python "%REPO%\tools\nt4\pe_nt4_version.py" "%WORK%\out\ahcint.sys" >nul || exit /b 5
echo built: %WORK%\out\ahcint.sys
exit /b 0
