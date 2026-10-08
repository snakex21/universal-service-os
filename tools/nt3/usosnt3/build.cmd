@echo off
rem build.cmd - build usosnt3.exe for Windows NT 3.51 (i386, console) with
rem WDK 7.1 (7600.16385.1).
rem
rem   tools\nt3\usosnt3\build.cmd [workdir]
rem
rem Needs tools\WinDDK71 (or %WDKROOT%), see docs\BUILDING.md. Compiles in
rem <workdir> (default %TEMP%\usosnt3-nt3-build), forces PE OS/subsystem
rem version 3.10 with tools\nt4\pe_nt4_version.py (NT 3.51 refuses programs
rem marked 4.00 or newer) and copies the result to
rem tools\nt3\usosnt3\bin\i386\usosnt3.exe. No C runtime (/NODEFAULTLIB).
rem tools\tests\test_nt3_flow.py checks the image and its imports.
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
if "%WORK%"=="" set "WORK=%TEMP%\usosnt3-nt3-build"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%" || exit /b 2
set "LIBDIR=%WDKROOT%\lib\wxp\i386"
cmd /c "call "%WDKROOT%\bin\setenv.bat" %WDKROOT% fre x86 WXP no_oacr >nul && cd /d "%WORK%" && cl /nologo /c /W3 /O1 /Oi- /GS- /Gy /Zl /DWIN32 /D_WIN32_WINNT=0x0400 /DWINVER=0x0400 /I"%WDKROOT%\inc\api" /I"%WDKROOT%\inc\crt" /Fousosnt3.obj "%HERE%src\usosnt3.c" && link /nologo /NODEFAULTLIB /ENTRY:entry /SUBSYSTEM:CONSOLE /MACHINE:X86 /OPT:REF /RELEASE /FIXED:NO /OUT:usosnt3.exe usosnt3.obj "%LIBDIR%\kernel32.lib" "%LIBDIR%\advapi32.lib""
if not exist "%WORK%\usosnt3.exe" (
  echo build failed
  exit /b 4
)
python "%REPO%\tools\nt4\pe_nt4_version.py" --version 3.10 "%WORK%\usosnt3.exe" >nul || exit /b 5
if not exist "%HERE%bin\i386" mkdir "%HERE%bin\i386"
copy /y "%WORK%\usosnt3.exe" "%HERE%bin\i386\usosnt3.exe" >nul || exit /b 6
echo built: %HERE%bin\i386\usosnt3.exe
exit /b 0
