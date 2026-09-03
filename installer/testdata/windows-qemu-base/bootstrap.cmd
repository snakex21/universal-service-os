@echo off
setlocal EnableExtensions
set "CFG="
for %%D in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%D:\USOS_QEMU_TEST.TAG" set "CFG=%%D:"
)
if not defined CFG (
    echo USOS QEMU config drive not found>"C:\USOS_TEST\bootstrap-failed.txt"
    shutdown.exe /s /t 0 /f
    exit /b 2
)
set "RESULT=%CFG%\usos-installer-e2e-result.txt"
echo START>"%RESULT%"
"%CFG%\usos-installer-qemu-e2e.exe" -serial USOS-GPT-TEST -size 42949672960 -out "%RESULT%" -installer "%CFG%\USOS Installer.exe"
set "RC=%ERRORLEVEL%"
echo EXIT_CODE=%RC%>>"%RESULT%"
shutdown.exe /s /t 0 /f
exit /b %RC%
