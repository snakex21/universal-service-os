@echo off
setlocal EnableExtensions EnableDelayedExpansion
title USOS - Starting Windows Setup
set "USOS_NONCE=@USOS_NONCE@"
set "USOS_SETUP_FROM_SOURCE=@USOS_SETUP_FROM_SOURCE@"
wpeinit
set "USOS_SOURCE="
set "USOS_FOUND=0"
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do call :check_source %%D
if !USOS_FOUND! GTR 1 goto ambiguous
if defined USOS_SOURCE goto start_setup

rem WORK may deliberately have no default drive letter. Assign a free letter
rem only to the single WORK-labelled volume, then verify its ownership nonce.
> "%~dp0usos-list.txt" echo list volume
diskpart /s "%~dp0usos-list.txt" > "%~dp0usos-volumes.txt"
set "USOS_VOLUME="
set "USOS_VOLUMES=0"
for /f "usebackq tokens=2,3,4" %%V in ("%~dp0usos-volumes.txt") do (
    if "%%W"=="USOS_WORK" (
        set "USOS_VOLUME=%%V"
        set /a USOS_VOLUMES+=1
    ) else if "%%X"=="USOS_WORK" (
        set "USOS_VOLUME=%%V"
        set /a USOS_VOLUMES+=1
    )
)
if not !USOS_VOLUMES!==1 goto map_removable_source
set "USOS_LETTER="
for %%D in (S T U V W Y Z R Q P O N M L K J I H G F E D) do if not exist %%D:\ if not defined USOS_LETTER set "USOS_LETTER=%%D"
if not defined USOS_LETTER goto map_removable_source
> "%~dp0usos-mount.txt" echo select volume !USOS_VOLUME!
>> "%~dp0usos-mount.txt" echo assign letter=!USOS_LETTER!
diskpart /s "%~dp0usos-mount.txt"
call :check_source !USOS_LETTER!
if defined USOS_SOURCE goto start_setup

:map_removable_source
rem WinPE 3.x cannot enumerate secondary partitions on removable USB media.
rem A signed, temporary WinPE driver exposes only the verified WORK range,
rem read-only. The helper refuses to operate outside WinPE.
set "USOS_ARCH="
if /i "%PROCESSOR_ARCHITECTURE%"=="AMD64" set "USOS_ARCH=x86_64"
if /i "%PROCESSOR_ARCHITECTURE%"=="x86" set "USOS_ARCH=x86"
if not defined USOS_ARCH goto missing
if not exist "%~dp0usos-source-!USOS_ARCH!.exe" goto missing
set "USOS_READER=%~dp0usos-source"
if not exist "!USOS_READER!\" md "!USOS_READER!"
copy /y "%~dp0usos-source-!USOS_ARCH!.exe" "!USOS_READER!\usos-source.exe" >nul
copy /y "%~dp0usos-source.ini" "!USOS_READER!\usos-source.ini" >nul
for %%E in (exe cpl sys) do copy /y "%~dp0imdisk-!USOS_ARCH!.%%E" "!USOS_READER!\imdisk.%%E" >nul
"!USOS_READER!\usos-source.exe" > "!USOS_READER!\source.log" 2>&1
if errorlevel 1 goto missing
set "USOS_FOUND=0"
set "USOS_SOURCE="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do call :check_source %%D
if !USOS_FOUND! GTR 1 goto ambiguous
if not defined USOS_SOURCE goto missing

:start_setup
echo Starting Windows Setup from !USOS_SOURCE!
set "USOS_SETUP=%SYSTEMDRIVE%\sources\setup.exe"
rem Vista needs Setup's adjacent source files even when InstallFrom is explicit.
if "!USOS_SETUP_FROM_SOURCE!"=="1" set "USOS_SETUP=!USOS_SOURCE!\sources\setup.exe"
if not exist "!USOS_SETUP!" goto missing
set "USOS_IMAGE=!USOS_SOURCE!\sources\install.wim"
if not exist "!USOS_IMAGE!" set "USOS_IMAGE=!USOS_SOURCE!\sources\install.esd"
rem A split image: /installfrom takes the first part, install.swm.
if not exist "!USOS_IMAGE!" set "USOS_IMAGE=!USOS_SOURCE!\sources\install.swm"
if exist "!USOS_SOURCE!\Autounattend.xml" (
    "!USOS_SETUP!" /installfrom:"!USOS_IMAGE!" /unattend:"!USOS_SOURCE!\Autounattend.xml"
) else (
    "!USOS_SETUP!" /installfrom:"!USOS_IMAGE!"
)
exit /b !errorlevel!

:check_source
if not exist "%~1:\.usos-work" exit /b
set "USOS_MATCH="
for /f "usebackq delims=" %%L in ("%~1:\.usos-work") do if "%%L"=="nonce=%USOS_NONCE%" set "USOS_MATCH=1"
if not defined USOS_MATCH exit /b
if not exist "%~1:\sources\boot.wim" exit /b
if not exist "%~1:\sources\install.wim" if not exist "%~1:\sources\install.esd" if not exist "%~1:\sources\install.swm" exit /b
set "USOS_SOURCE=%~1:"
set /a USOS_FOUND+=1
exit /b

:ambiguous
echo More than one matching USOS source was found.
goto stopped
:missing
echo The prepared USOS source could not be opened.
if defined USOS_READER if exist "!USOS_READER!\source.log" type "!USOS_READER!\source.log"
:stopped
echo Setup was not started.
exit /b 1
