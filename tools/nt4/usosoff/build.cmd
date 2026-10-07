@echo off
rem build.cmd - build usosoff.exe for Windows NT 4.0 (i386, console) with
rem WDK 7.1 (7600.16385.1).
rem
rem   tools\nt4\usosoff\build.cmd [workdir]
rem
rem Needs tools\WinDDK71 (or %WDKROOT%), see docs\BUILDING.md. Compiles in
rem <workdir> (default %TEMP%\usosoff-nt4-build), forces PE OS/subsystem
rem version 4.00 with tools\nt4\pe_nt4_version.py and copies the result to
rem tools\nt4\usosoff\bin\i386\usosoff.exe. No C runtime (/NODEFAULTLIB).
rem tools\tests\test_nt4_usosoff.py checks the image and its imports.
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
if "%WORK%"=="" set "WORK=%TEMP%\usosoff-nt4-build"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%" || exit /b 2
set "LIBDIR=%WDKROOT%\lib\wxp\i386"
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% fre x86 WXP no_oacr >nul && cd /d "%WORK%" && cl /nologo /c /W3 /O1 /Oi- /GS- /Gy /Zl /DWIN32 /D_WIN32_WINNT=0x0400 /DWINVER=0x0400 /I"%WDKROOT%\inc\api" /I"%WDKROOT%\inc\crt" /Fousosoff.obj "%HERE%src\usosoff.c" && link /nologo /NODEFAULTLIB /ENTRY:entry /SUBSYSTEM:CONSOLE /MACHINE:X86 /OPT:REF /RELEASE /FIXED:NO /OUT:usosoff.exe usosoff.obj "%LIBDIR%\kernel32.lib" "%LIBDIR%\advapi32.lib" "%LIBDIR%\user32.lib""
if not exist "%WORK%\usosoff.exe" (
  echo build failed
  exit /b 4
)
python "%REPO%\tools\nt4\pe_nt4_version.py" "%WORK%\usosoff.exe" >nul || exit /b 5
if not exist "%HERE%bin\i386" mkdir "%HERE%bin\i386"
copy /y "%WORK%\usosoff.exe" "%HERE%bin\i386\usosoff.exe" >nul || exit /b 6
echo built: %HERE%bin\i386\usosoff.exe
exit /b 0
