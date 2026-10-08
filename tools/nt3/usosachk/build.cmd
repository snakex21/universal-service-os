@echo off
rem build.cmd - build usosachk.exe (native, i386) for Windows NT 3.51 with
rem WDK 7.1 (7600.16385.1).
rem
rem   tools\nt3\usosachk\build.cmd [workdir]
rem
rem Needs tools\WinDDK71 (or %WDKROOT%), see docs\BUILDING.md. PE OS and
rem subsystem version forced to 3.10 (tools\nt4\pe_nt4_version.py), result
rem in tools\nt3\usosachk\bin\i386\usosachk.exe. Only import:
rem ntdll!NtTerminateProcess. No C runtime.
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
if "%WORK%"=="" set "WORK=%TEMP%\usosachk-nt3-build"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%" || exit /b 2
set "LIBDIR=%WDKROOT%\lib\wxp\i386"
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% fre x86 WXP no_oacr >nul && cd /d "%WORK%" && cl /nologo /c /W3 /O1 /Oi- /GS- /Gy /Zl /Fousosachk.obj "%HERE%src\usosachk.c" && link /nologo /NODEFAULTLIB /ENTRY:entry /SUBSYSTEM:NATIVE /MACHINE:X86 /OPT:REF /RELEASE /FIXED:NO /OUT:usosachk.exe usosachk.obj "%LIBDIR%\ntdll.lib""
if not exist "%WORK%\usosachk.exe" (
  echo build failed
  exit /b 4
)
python "%REPO%\tools\nt4\pe_nt4_version.py" --version 3.10 "%WORK%\usosachk.exe" >nul || exit /b 5
if not exist "%HERE%bin\i386" mkdir "%HERE%bin\i386"
copy /y "%WORK%\usosachk.exe" "%HERE%bin\i386\usosachk.exe" >nul || exit /b 6
echo built: %HERE%bin\i386\usosachk.exe
exit /b 0
