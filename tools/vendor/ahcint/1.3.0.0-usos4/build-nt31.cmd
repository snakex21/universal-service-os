@echo off
rem build-nt31.cmd - build AHCINT 1.3.0.0-usos4 for Windows NT 3.1 (i386,
rem free, AHCI_NT4 + AHCI_NT351 + AHCI_NT31) with WDK 7.1 (7600.16385.1)
rem from src\ in this folder.
rem
rem   tools\vendor\ahcint\1.3.0.0-usos4\build-nt31.cmd [workdir]
rem
rem Needs tools\WinDDK71 (or %WDKROOT%), see docs\BUILDING.md. Output:
rem <workdir>\out\ahcint.sys. Nothing is copied into the repository.
rem
rem The NT 3.51 build (build-nt351.cmd) plus -DAHCI_NT31 (patch 0010): the
rem NT 3.1 ScsiPort structure sizes, an EISA bus master, no
rem KeRegisterBugCheckCallback and an own memset (the 3.1 kernel exports
rem neither) and PE version 3.10. tools\tests\check_nt4_driver_imports.py
rem --exports tools\tests\data\nt31_exports.txt checks every import.
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
if "%WORK%"=="" set "WORK=%TEMP%\ahcint-usos4-nt31-build"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%" || exit /b 2
xcopy /e /i /q "%HERE%src" "%WORK%\src" >nul || exit /b 3
set "C_DEFINES=-DAHCI_NT351 -DAHCI_NT31"
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% fre x86 WXP no_oacr && set "BUILD_ALT_DIR=fre" && cd /d "%WORK%\src\NT4WDK" && build -cZ"
if not exist "%WORK%\src\NT4WDK\objfre\i386\ahcint.sys" (
  echo build failed - see %WORK%\src\NT4WDK\buildfre*.log
  type "%WORK%\src\NT4WDK\buildfre_*.err" 2>nul
  type "%WORK%\src\NT4WDK\build*.err" 2>nul
  exit /b 4
)
mkdir "%WORK%\out" 2>nul
copy /y "%WORK%\src\NT4WDK\objfre\i386\ahcint.sys" "%WORK%\out\ahcint.sys" >nul
python "%REPO%\tools\nt4\pe_nt4_version.py" --version 3.10 "%WORK%\out\ahcint.sys" >nul || exit /b 5
echo built: %WORK%\out\ahcint.sys
exit /b 0
