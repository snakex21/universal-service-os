@echo off
rem build-nt6.cmd - build usosusb.sys for Windows Vista / Server 2008 SP2
rem (NT 6.0, i386, free) with WDK 7.1 (7600.16385.1) from the same src\ as
rem build.cmd.
rem
rem   tools\nt4\usosusb\build-nt6.cmd [workdir]
rem
rem Needs tools\WinDDK71 (or %WDKROOT%), see docs\BUILDING.md. Output:
rem tools\nt4\usosusb\bin\nt6\i386\usosusb.sys (WXP environment, PE 5.01).
rem -DUSOSUSB_NT6: PCI configuration through HalGet/SetBusDataByOffset,
rem input sent once kbdclass / mouclass connected, Parameters\Conn value.
rem tools\tests\test_nt60_usosusb.py checks the imports against the
rem Server 2008 SP2 x86 kernels and HALs (export-name fixture).
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
if "%WORK%"=="" set "WORK=%TEMP%\usosusb-nt6-build"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%" || exit /b 2
xcopy /e /i /q "%HERE%src" "%WORK%\src" >nul || exit /b 3
set "C_DEFINES=-DUSOSUSB_NT6"
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% fre x86 WXP no_oacr && set "BUILD_ALT_DIR=fre" && cd /d "%WORK%\src" && build -cZ"
if not exist "%WORK%\src\objfre\i386\usosusb.sys" (
  echo build failed - see %WORK%\src\buildfre*.log
  type "%WORK%\src\buildfre*.err" 2>nul
  exit /b 4
)
mkdir "%HERE%bin\nt6\i386" 2>nul
copy /y "%WORK%\src\objfre\i386\usosusb.sys" "%HERE%bin\nt6\i386\usosusb.sys" >nul || exit /b 6
echo built: %HERE%bin\nt6\i386\usosusb.sys
exit /b 0
