@echo off
rem build-nt31.cmd - build usosusb.sys for Windows NT 3.1 (i386, free) with
rem WDK 7.1 (7600.16385.1) from the same src\ as build.cmd.
rem
rem   tools\nt4\usosusb\build-nt31.cmd [workdir]
rem
rem Needs tools\WinDDK71 (or %WDKROOT%), see docs\BUILDING.md. Output:
rem <workdir>\out\usosusb.sys. Nothing is copied into the repository.
rem -DUSOSUSB_NT31: IoCompleteRequest, KeRaiseIrql and KeLowerIrql as the
rem NT 3.1 kernel and HAL export them (no IofCompleteRequest, no
rem KfRaiseIrql / KfLowerIrql there). PE version 3.10.
rem tools\tests\check_nt4_driver_imports.py --exports
rem tools\tests\data\nt31_exports.txt checks every import.
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
if "%WORK%"=="" set "WORK=%TEMP%\usosusb-nt31-build"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%" || exit /b 2
xcopy /e /i /q "%HERE%src" "%WORK%\src" >nul || exit /b 3
set "SUBSYSTEM_VERSION=4.00"
set "C_DEFINES=-DUSOSUSB_NT31"
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% fre x86 WXP no_oacr && set "BUILD_ALT_DIR=fre" && cd /d "%WORK%\src" && build -cZ"
if not exist "%WORK%\src\objfre\i386\usosusb.sys" (
  echo build failed - see %WORK%\src\buildfre*.log
  type "%WORK%\src\buildfre*.err" 2>nul
  exit /b 4
)
mkdir "%WORK%\out" 2>nul
copy /y "%WORK%\src\objfre\i386\usosusb.sys" "%WORK%\out\usosusb.sys" >nul
python "%REPO%\tools\nt4\pe_nt4_version.py" --version 3.10 "%WORK%\out\usosusb.sys" >nul || exit /b 5
echo built: %WORK%\out\usosusb.sys
exit /b 0
