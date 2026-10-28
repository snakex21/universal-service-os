@echo off
rem build.cmd - build usosnvme.sys (USOS NVMe SCSI miniport, i386, free)
rem with WDK 7.1 (7600.16385.1).
rem
rem   tools\nt\usosnvme\build.cmd <2kxp|nt6|nt6x64|nt4|nt351|nt31|w9x|all> [workdir]
rem
rem Needs tools\WinDDK71 (or %WDKROOT%), see docs\BUILDING.md. Output:
rem tools\nt\usosnvme\bin\<VARIANT>\i386\usosnvme.sys.
rem   2kxp   Windows 2000 / XP / Server 2003 x86, PnP ScsiPort (src\2KXP)
rem   nt6    Windows Vista / 7 / 2008 x86 and the Win10 x86 WinPE (src\2KXP,
rem          -DUSOSNVME_NT6: no HwInterrupt, MSI / MSI-X masked)
rem   nt6x64 Vista / 2008 x64, the same polled code (fre x64 WLH),
rem          bin\NT6\amd64; production signing remains a separate decision
rem   nt4    Windows NT 4.0 (src\NT4, -DUSOSNVME_NT4, PE 4.00)
rem   nt351  Windows NT 3.5 / 3.51 (+ -DUSOSNVME_NT351: CF8h/CFCh PCI
rem          config, Isa registration, PE 3.51)
rem   nt31   Windows NT 3.1 (+ -DUSOSNVME_NT31: 0x40-byte init data, no
rem          SlotNumber, EISA bus master, PE 3.10)
rem   w9x    Windows 95 OSR2 / 98 / 98 SE / Me SCSIPORT.PDR miniport (src\W9X,
rem          -DUSOSNVME_W9X, PE 4.00) -> bin\W9X\usosnvme.mpd
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
  for %%V in (2kxp nt6 nt6x64 nt4 nt351 nt31 w9x) do (
    call "%~f0" %%V "%~2" || exit /b 1
  )
  exit /b 0
)
set "DIR=" & set "DEFS=" & set "PEVER=" & set "OUT="
set "ARCH=x86" & set "OBJ=i386" & set "ENVOS=WXP" & set "WORKVAR="
if /i "%VARIANT%"=="2kxp"  set "DIR=2KXP" & set "OUT=2KXP"
if /i "%VARIANT%"=="nt6"   set "DIR=2KXP" & set "OUT=NT6" & set "DEFS=-DUSOSNVME_NT6"
if /i "%VARIANT%"=="nt6x64" set "DIR=NT6X64" & set "OUT=NT6" & set "ARCH=x64" & set "OBJ=amd64" & set "ENVOS=WLH" & set "WORKVAR=NT6X64"
if /i "%VARIANT%"=="nt4"   set "DIR=NT4" & set "OUT=NT4" & set "PEVER=4.00"
if /i "%VARIANT%"=="nt351" set "DIR=NT4" & set "OUT=NT351" & set "PEVER=3.51" & set "DEFS=-DUSOSNVME_NT351"
if /i "%VARIANT%"=="nt31"  set "DIR=NT4" & set "OUT=NT31" & set "PEVER=3.10" & set "DEFS=-DUSOSNVME_NT351 -DUSOSNVME_NT31"
if /i "%VARIANT%"=="w9x"   set "DIR=W9X" & set "OUT=W9X" & set "PEVER=4.00"
if "%DIR%"=="" (
  echo usage: build.cmd ^<2kxp^|nt6^|nt6x64^|nt4^|nt351^|nt31^|w9x^|all^> [workdir]
  exit /b 1
)
set "WORK=%~2"
if "%WORK%"=="" set "WORK=%HERE%build"
if "%WORKVAR%"=="" set "WORKVAR=%OUT%"
set "WORK=%WORK%\%WORKVAR%"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%" || exit /b 2
xcopy /e /i /q "%HERE%src" "%WORK%\src" >nul || exit /b 3
set "C_DEFINES=%DEFS%"
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% fre %ARCH% %ENVOS% no_oacr && set "BUILD_ALT_DIR=fre" && cd /d "%WORK%\src\%DIR%" && build -cZ"
if not exist "%WORK%\src\%DIR%\objfre\%OBJ%\usosnvme.sys" (
  echo build failed - see %WORK%\src\%DIR%\buildfre*.log
  type "%WORK%\src\%DIR%\buildfre*.err" 2>nul
  type "%WORK%\src\%DIR%\buildfre*.wrn" 2>nul
  exit /b 4
)
if not "%PEVER%"=="" (
  python "%REPO%\tools\nt4\pe_nt4_version.py" --version %PEVER% "%WORK%\src\%DIR%\objfre\%OBJ%\usosnvme.sys" >nul || exit /b 5
)
if /i "%OUT%"=="W9X" (
  mkdir "%HERE%bin\W9X" 2>nul
  copy /y "%WORK%\src\%DIR%\objfre\i386\usosnvme.sys" "%HERE%bin\W9X\usosnvme.mpd" >nul || exit /b 6
  echo built: %HERE%bin\W9X\usosnvme.mpd
  exit /b 0
)
mkdir "%HERE%bin\%OUT%\%OBJ%" 2>nul
copy /y "%WORK%\src\%DIR%\objfre\%OBJ%\usosnvme.sys" "%HERE%bin\%OUT%\%OBJ%\usosnvme.sys" >nul || exit /b 6
echo built: %HERE%bin\%OUT%\%OBJ%\usosnvme.sys
exit /b 0
