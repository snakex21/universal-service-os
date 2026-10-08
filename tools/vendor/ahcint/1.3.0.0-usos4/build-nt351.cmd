@echo off
rem build-nt351.cmd - build AHCINT 1.3.0.0-usos4 for Windows NT 3.51 (i386,
rem free, AHCI_NT4 + AHCI_NT351) with WDK 7.1 (7600.16385.1) from src\ in
rem this folder.
rem
rem   tools\vendor\ahcint\1.3.0.0-usos4\build-nt351.cmd [workdir]
rem
rem Needs tools\WinDDK71 (or %WDKROOT%), see docs\BUILDING.md. Output:
rem <workdir>\out\ahcint.sys. Nothing is copied into the repository.
rem
rem The NT 4.0 build (build-nt4.cmd, src\NT4WDK) plus -DAHCI_NT351 (patch
rem 0007: no KiBugCheckData, which the NT 3.51 kernel does not export) and
rem PE version 3.51. Upstream AHCINT supports NT 3.5 to 4.0 with the same
rem non-PnP ScsiPort path. tools\tests\check_nt4_driver_imports.py --exports
rem tools\tests\data\nt351_exports.txt checks every import.
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
if "%WORK%"=="" set "WORK=%TEMP%\ahcint-usos4-nt351-build"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%" || exit /b 2
xcopy /e /i /q "%HERE%src" "%WORK%\src" >nul || exit /b 3
set "C_DEFINES=-DAHCI_NT351"
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% fre x86 WXP no_oacr && set "BUILD_ALT_DIR=fre" && cd /d "%WORK%\src\NT4WDK" && build -cZ"
if not exist "%WORK%\src\NT4WDK\objfre\i386\ahcint.sys" (
  echo build failed - see %WORK%\src\NT4WDK\buildfre*.log
  type "%WORK%\src\NT4WDK\buildfre_*.err" 2>nul
  type "%WORK%\src\NT4WDK\build*.err" 2>nul
  exit /b 4
)
mkdir "%WORK%\out" 2>nul
copy /y "%WORK%\src\NT4WDK\objfre\i386\ahcint.sys" "%WORK%\out\ahcint.sys" >nul
python "%REPO%\tools\nt4\pe_nt4_version.py" --version 3.51 "%WORK%\out\ahcint.sys" >nul || exit /b 5
echo built: %WORK%\out\ahcint.sys
exit /b 0
