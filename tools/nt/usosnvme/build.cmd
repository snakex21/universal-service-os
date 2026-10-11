@echo off
rem build.cmd - build usosnvme.sys (USOS NVMe SCSI miniport, i386, free)
rem with WDK 7.1 (7600.16385.1).
rem
rem   tools\nt\usosnvme\build.cmd <2kxp|nt4|nt351|nt31|all> [workdir]
rem
rem Needs tools\WinDDK71 (or %WDKROOT%), see docs\BUILDING.md. Output:
rem tools\nt\usosnvme\bin\<VARIANT>\i386\usosnvme.sys.
rem   2kxp   Windows 2000 / XP / Server 2003 x86, PnP ScsiPort (src\2KXP)
rem   nt4    Windows NT 4.0 (src\NT4, -DUSOSNVME_NT4, PE 4.00)
rem   nt351  Windows NT 3.5 / 3.51 (+ -DUSOSNVME_NT351: CF8h/CFCh PCI
rem          config, Isa registration, PE 3.51)
rem   nt31   Windows NT 3.1 (+ -DUSOSNVME_NT31: 0x40-byte init data, no
rem          SlotNumber, EISA bus master, PE 3.10)
rem tools\tests\check_nt4_driver_imports.py checks the imports per version
rem (tools\tests\test_usosnvme.py runs it for every committed binary).
setlocal
set "HERE=%~dp0"
set "REPO=%HERE%..\..\.."
for %%I in ("%REPO%") do set "REPO=%%~fI"
if "%WDKROOT%"=="" set "WDKROOT=%REPO%\tools\WinDDK71"
if not exist "%WDKROOT%\bin\setenv.bat" (
  echo WDK 7.1 not found at "%WDKROOT%" - see docs\BUILDING.md
  exit /b 2
)
set "VARIANT=%~1"
if /i "%VARIANT%"=="all" (
  for %%V in (2kxp nt4 nt351 nt31) do (
    call "%~f0" %%V "%~2" || exit /b 1
  )
  exit /b 0
)
set "DIR=" & set "DEFS=" & set "PEVER=" & set "OUT="
if /i "%VARIANT%"=="2kxp"  set "DIR=2KXP" & set "OUT=2KXP"
if /i "%VARIANT%"=="nt4"   set "DIR=NT4" & set "OUT=NT4" & set "PEVER=4.00"
if /i "%VARIANT%"=="nt351" set "DIR=NT4" & set "OUT=NT351" & set "PEVER=3.51" & set "DEFS=-DUSOSNVME_NT351"
if /i "%VARIANT%"=="nt31"  set "DIR=NT4" & set "OUT=NT31" & set "PEVER=3.10" & set "DEFS=-DUSOSNVME_NT351 -DUSOSNVME_NT31"
if "%DIR%"=="" (
  echo usage: build.cmd ^<2kxp^|nt4^|nt351^|nt31^|all^> [workdir]
  exit /b 1
)
set "WORK=%~2"
if "%WORK%"=="" set "WORK=%TEMP%\usosnvme-build"
set "WORK=%WORK%\%OUT%"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%" || exit /b 2
xcopy /e /i /q "%HERE%src" "%WORK%\src" >nul || exit /b 3
set "C_DEFINES=%DEFS%"
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% fre x86 WXP no_oacr && set "BUILD_ALT_DIR=fre" && cd /d "%WORK%\src\%DIR%" && build -cZ"
if not exist "%WORK%\src\%DIR%\objfre\i386\usosnvme.sys" (
  echo build failed - see %WORK%\src\%DIR%\buildfre*.log
  type "%WORK%\src\%DIR%\buildfre*.err" 2>nul
  type "%WORK%\src\%DIR%\buildfre*.wrn" 2>nul
  exit /b 4
)
if not "%PEVER%"=="" (
  python "%REPO%\tools\nt4\pe_nt4_version.py" --version %PEVER% "%WORK%\src\%DIR%\objfre\i386\usosnvme.sys" >nul || exit /b 5
)
mkdir "%HERE%bin\%OUT%\i386" 2>nul
copy /y "%WORK%\src\%DIR%\objfre\i386\usosnvme.sys" "%HERE%bin\%OUT%\i386\usosnvme.sys" >nul || exit /b 6
echo built: %HERE%bin\%OUT%\i386\usosnvme.sys
exit /b 0
