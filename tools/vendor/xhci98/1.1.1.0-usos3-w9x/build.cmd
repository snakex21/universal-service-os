@echo off
rem build.cmd - build xhci98 1.1.1.0-usos3-w9x (x86, free/release, Windows 98 SE)
rem with WDK 7.1 (7600.16385.1) from the upstream v1.1.1.0 source plus
rem patches\*.patch (0001-0003 = usos3, 0004 = the Windows 98 SE build switch).
rem
rem   tools\vendor\xhci98\1.1.1.0-usos3-w9x\build.cmd [workdir]
rem
rem Inputs (all local, no network):
rem   tools\vendor\xhci98\1.1.1.0-src\xhci98-7d0dd9d4...tar.gz  (upstream tag)
rem   tools\vendor\xhci98\1.1.1.0-usos3-w9x\patches\*.patch       (in order)
rem   tools\WinDDK71 (or %WDKROOT%)  - WDK 7.1 unpacked with msiexec /a from
rem       GRMWDK_EN_7600_1.ISO (toolchain.txt)
rem   git (for "git apply") and Windows 10+ tar.exe (System32)
rem
rem Output: <workdir>\out\release-x86\xhci98.sys. Nothing is copied into the
rem repository; the caller compares hashes and copies. The INF is not built:
rem release-x86\xhci98.inf is the usos3 INF plus usbport.sys (MODIFIED.txt).
rem
rem The WNET target with XHCI_USOS_W9X=1: no /GS cookie, PE subsystem 5.00 and
rem only kernel imports that Windows 98 SE resolves (MODIFIED.txt).
setlocal
set "HERE=%~dp0"
set "REPO=%HERE%..\..\..\.."
for %%I in ("%REPO%") do set "REPO=%%~fI"
if "%WDKROOT%"=="" set "WDKROOT=%REPO%\tools\WinDDK71"
if not exist "%WDKROOT%\bin\setenv.bat" (
  echo WDK 7.1 not found at "%WDKROOT%" - see toolchain.txt
  exit /b 2
)
set "WORK=%~1"
if "%WORK%"=="" set "WORK=%TEMP%\xhci98-usos3-w9x-build"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%" || exit /b 2
set "TARBALL=%REPO%\tools\vendor\xhci98\1.1.1.0-src\xhci98-7d0dd9d440e9716a87e0882f905bf8e99fa443ac.tar.gz"
if not exist "%TARBALL%" (
  echo source tarball missing: "%TARBALL%"
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

rem usbport import library, from the upstream __stdcall stubs
setlocal
set "PATH=%WDKROOT%\bin\x86\x86;%WDKROOT%\bin\x86;%PATH%"
set "INCLUDE="
set "LIB="
cl /nologo /c /Gz /O1 /GS- /Zl /Fo"%WORK%\stub-x86.obj" "%STUB%\usbport-stub.c" || (popd & exit /b 5)
link /nologo /dll /noentry /nodefaultlib /machine:ix86 /def:"%STUB%\usbport-stub.def" /out:"%WORK%\usbport-x86.sys" /implib:"%SRC%\usbport.lib" "%WORK%\stub-x86.obj" || (popd & exit /b 5)
endlocal

set "XHCI_USOS_W9X=1"
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% fre x86 WNET no_oacr && set "BUILD_ALT_DIR=fre" && cd /d "%SRC%" && build -cZ"
if not exist "%SRC%\objfre\i386\xhci98.sys" (
  echo build failed - see %SRC%\buildfre*.log
  type "%SRC%\buildfre_*.err" 2>nul
  popd
  exit /b 6
)
mkdir "%WORK%\out\release-x86" 2>nul
copy /y "%SRC%\objfre\i386\xhci98.sys" "%WORK%\out\release-x86\xhci98.sys" >nul
popd
echo built: %WORK%\out
exit /b 0
