@echo off
setlocal
set "HERE=%~dp0"
set "WORK=%~1"
if "%WORK%"=="" set "WORK=%HERE%build"
if "%WDKROOT%"=="" set "WDKROOT=%HERE%..\..\WinDDK71"
if not exist "%WDKROOT%\bin\x86\x86\cl.exe" exit /b 2
if not exist "%WORK%" mkdir "%WORK%" || exit /b 3
if not exist "%WORK%\tmp" mkdir "%WORK%\tmp" || exit /b 3
set "TEMP=%WORK%\tmp"
set "TMP=%TEMP%"
set "PATH=%WDKROOT%\bin\x86\x86;%WDKROOT%\bin\x86;%PATH%"
"%WDKROOT%\bin\x86\x86\cl.exe" /nologo /c /TP /O1 /GS- /W3 /Zl /GR- /D_X86_=1 /Di386=1 /DWIN32 /DWINVER=0x0501 /I"%WDKROOT%\inc\api" /I"%WDKROOT%\inc\crt" /Fo"%WORK%\posrlog.obj" "%HERE%posrlog.c" || exit /b 4
if not exist "%HERE%bin\i386" mkdir "%HERE%bin\i386" || exit /b 3
"%WDKROOT%\bin\x86\x86\link.exe" /nologo /NODEFAULTLIB /ENTRY:PosrMain /SUBSYSTEM:CONSOLE,5.01 /OSVERSION:5.1 /FIXED:NO /OUT:"%HERE%bin\i386\posrlog.exe" "%WORK%\posrlog.obj" "%WDKROOT%\lib\wxp\i386\kernel32.lib" "%WDKROOT%\lib\wxp\i386\advapi32.lib" || exit /b 5
exit /b 0
