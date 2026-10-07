@echo off
rem build.cmd - build usosvbe.sys (VBE video miniport) and usosvbe.dll
rem (frame buffer display driver) for Windows NT 4.0 (i386, free) with
rem WDK 7.1 (7600.16385.1).
rem
rem   tools\nt4\usosvbe\build.cmd [workdir]
rem
rem Needs tools\WinDDK71 (or %WDKROOT%), see docs\BUILDING.md. Output:
rem tools\nt4\usosvbe\bin\i386\usosvbe.sys and usosvbe.dll. WDK 7.1 has no
rem NT4 target, so the WXP environment is used and tools\nt4\pe_nt4_version.py
rem marks both images as PE 4.00. tools\tests\check_nt4_driver_imports.py
rem checks every import against NT 4.0 RTM and SP6a.
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
if "%WORK%"=="" set "WORK=%TEMP%\usosvbe-nt4-build"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%" || exit /b 2
xcopy /e /i /q "%HERE%src" "%WORK%\src" >nul || exit /b 3
set "SUBSYSTEM_VERSION=4.00"
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% fre x86 WXP no_oacr && set "BUILD_ALT_DIR=fre" && cd /d "%WORK%\src" && build -cZ"
if not exist "%WORK%\src\mini\objfre\i386\usosvbe.sys" goto failed
if not exist "%WORK%\src\disp\objfre\i386\usosvbe.dll" goto failed
python "%REPO%\tools\nt4\pe_nt4_version.py" "%WORK%\src\mini\objfre\i386\usosvbe.sys" >nul || exit /b 5
python "%REPO%\tools\nt4\pe_nt4_version.py" "%WORK%\src\disp\objfre\i386\usosvbe.dll" >nul || exit /b 5
mkdir "%HERE%bin\i386" 2>nul
copy /y "%WORK%\src\mini\objfre\i386\usosvbe.sys" "%HERE%bin\i386\usosvbe.sys" >nul || exit /b 6
copy /y "%WORK%\src\disp\objfre\i386\usosvbe.dll" "%HERE%bin\i386\usosvbe.dll" >nul || exit /b 6
echo built: %HERE%bin\i386\usosvbe.sys %HERE%bin\i386\usosvbe.dll
exit /b 0
:failed
echo build failed - see %WORK%\src\buildfre*.log
type "%WORK%\src\buildfre*.err" 2>nul
exit /b 4
