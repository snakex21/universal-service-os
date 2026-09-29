@echo off
rem build.cmd - build xhci98 1.1.1.0-usos1 (x86 and amd64, free/release) with
rem WDK 7.1 (7600.16385.1) from the upstream v1.1.1.0 source plus patches\*.patch.
rem
rem   tools\vendor\xhci98\1.1.1.0-usos1\build.cmd [workdir]
rem
rem Inputs (all local, no network):
rem   tools\vendor\xhci98\1.1.1.0-src\xhci98-7d0dd9d4...tar.gz  (upstream tag)
rem   tools\vendor\xhci98\1.1.1.0-usos1\patches\*.patch           (in order)
rem   tools\WinDDK71 (or %WDKROOT%)  - WDK 7.1 unpacked with msiexec /a from
rem       GRMWDK_EN_7600_1.ISO, see docs\BUILDING.md
rem   git (for "git apply") and Windows 10+ tar.exe (System32)
rem
rem Output: <workdir>\out\release-x86\xhci98.sys, <workdir>\out\release-x64\xhci98.sys
rem and the two INFs. Nothing is copied into the repository; the caller
rem compares hashes and copies (see README in this folder).
rem
rem Both architectures use the WNET (Server 2003, NT 5.2) target of WDK 7.1:
rem USOS stages this driver only for Server 2003 x86 and XP x64 / 2003 x64.
rem Upstream builds x86 with MSVC 6.0 + the Windows 2000 DDK so the same
rem binary also loads on Windows 98; this build does NOT target 98/ME/2000.
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
if "%WORK%"=="" set "WORK=%TEMP%\xhci98-usos1-build"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%" || exit /b 2
set "TARBALL=%REPO%\tools\vendor\xhci98\1.1.1.0-src\xhci98-7d0dd9d440e9716a87e0882f905bf8e99fa443ac.tar.gz"
if not exist "%TARBALL%" (
  echo source tarball missing: "%TARBALL%" - see tools\vendor\xhci98\1.1.1.0\SOURCES.txt
  exit /b 2
)
pushd "%WORK%"
"%SystemRoot%\System32\tar.exe" -xzf "%TARBALL%" || (popd & exit /b 3)
cd xhci98-1.1.1.0
for %%P in ("%HERE%patches\*.patch") do (
  echo applying %%~nxP
  git apply --whitespace=nowarn "%%~fP" || (popd & exit /b 4)
)
set "SRC=%CD%\src"
set "STUB=%CD%\scripts\usbport-lib"

rem usbport import libraries, from the upstream __stdcall stubs
call :stublib x86 "%WDKROOT%\bin\x86\x86" ix86 "DriverEntry@8" usbport.lib || (popd & exit /b 5)
call :stublib amd64 "%WDKROOT%\bin\x86\amd64" x64 DriverEntry usbport_amd64.lib || (popd & exit /b 5)

call :drv "x86 WNET no_oacr" i386 release-x86 || (popd & exit /b 6)
call :drv "x64 WNET no_oacr" amd64 release-x64 || (popd & exit /b 6)
copy /y "%SRC%\xhci98.inf" "%WORK%\out\release-x86\xhci98.inf" >nul
copy /y "%SRC%\xhci98-amd64.inf" "%WORK%\out\release-x64\xhci98.inf" >nul
popd
echo built: %WORK%\out
exit /b 0

:stublib
rem %1 arch  %2 tool dir  %3 machine  %4 entry  %5 lib name
setlocal
set "PATH=%~2;%WDKROOT%\bin\x86;%PATH%"
set "INCLUDE="
set "LIB="
cl /nologo /c /Gz /O1 /GS- /Zl /Fo"%WORK%\stub-%1.obj" "%STUB%\usbport-stub.c" || exit /b 1
link /nologo /dll /noentry /nodefaultlib /machine:%3 /def:"%STUB%\usbport-stub.def" /out:"%WORK%\usbport-%1.sys" /implib:"%SRC%\%~5" "%WORK%\stub-%1.obj" || exit /b 1
endlocal & exit /b 0

:drv
rem %1 setenv args  %2 obj arch dir  %3 output folder
setlocal
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% fre %~1 && set "BUILD_ALT_DIR=fre" && cd /d "%SRC%" && build -cZ"
if not exist "%SRC%\objfre\%2\xhci98.sys" (
  echo build failed for %2 - see %SRC%\buildfre*.log
  type "%SRC%\buildfre_*.err" 2>nul
  type "%SRC%\build*.err" 2>nul
  exit /b 1
)
mkdir "%WORK%\out\%3" 2>nul
copy /y "%SRC%\objfre\%2\xhci98.sys" "%WORK%\out\%3\xhci98.sys" >nul
rmdir /s /q "%SRC%\objfre" 2>nul
endlocal & exit /b 0
