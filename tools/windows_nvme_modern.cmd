@echo off
setlocal
rem Opt-in 8.1/10 x86 only. All writes are to Setup's already selected image.
set "T=%~1"
call :supported_nt "%~2" "%~3"
if errorlevel 1 exit /b 1
if not exist "%T%\Windows\System32\config\SYSTEM" exit /b 1
set "P=%T%\USOS\nvme-modern"
md "%P%\scratch" 2>nul
for %%F in (usosnvme.inf usosnvme.sys usosnvme.cat usosnvme.cer) do (
    copy /y "%~dp0modern-%%F" "%P%\%%F" >nul
    if errorlevel 1 exit /b 1
)
echo [USOS] Modern NVMe: owned file, boot service stornvme, trusted exact-ID package.
rem DISM may rewrite a shared service while staging boot-critical drivers.
rem Configure and verify our image path AFTER staging, immediately before boot.
dism.exe /English /Image:%T%\ /ScratchDir:"%P%\scratch" /LogPath:"%P%\dism-installed.log" /Add-Driver /Driver:"%P%\usosnvme.inf" /ForceUnsigned
if errorlevel 1 (echo [USOS] Modern NVMe: driver-store staging failed; restart refused. & exit /b 1)
"%~dp0usos-nvme-modern.exe" "%P%" "%T%\Windows"
echo [USOS] Modern NVMe: helper exit=%errorlevel%
if errorlevel 1 (echo [USOS] Modern NVMe: offline configuration failed; restart refused. & exit /b 1)
rem Recovery is a separate OS and must receive the same boot driver.
set "RE=%T%\Windows\System32\Recovery\winre.wim"
if not exist "%RE%" (echo [USOS] Modern NVMe: winre.wim missing; restart refused. & exit /b 1)
md "%P%\winre-mount" 2>nul
dism.exe /English /Mount-Image /ImageFile:"%RE%" /Index:1 /MountDir:"%P%\winre-mount" /ScratchDir:"%P%\scratch" /LogPath:"%P%\dism-recovery.log"
if errorlevel 1 exit /b 1
dism.exe /English /Image:"%P%\winre-mount" /ScratchDir:"%P%\scratch" /LogPath:"%P%\dism-recovery-driver.log" /Add-Driver /Driver:"%P%\usosnvme.inf" /ForceUnsigned
if errorlevel 1 goto re_failed
"%~dp0usos-nvme-modern.exe" "%P%" "%P%\winre-mount\Windows"
if errorlevel 1 goto re_failed
dism.exe /English /Unmount-Image /MountDir:"%P%\winre-mount" /Commit /ScratchDir:"%P%\scratch" /LogPath:"%P%\dism-recovery.log"
if errorlevel 1 exit /b 1
echo [USOS] Modern NVMe: installed system and WinRE configured PASS.
exit /b 0
:re_failed
dism.exe /English /Unmount-Image /MountDir:"%P%\winre-mount" /Discard /ScratchDir:"%P%\scratch" /LogPath:"%P%\dism-recovery.log"
echo [USOS] Modern NVMe: recovery configuration failed; restart refused.
exit /b 1

rem ntoskrnl's fixed version can report 6.2 even for build 9600/19041.
rem Match the build as well; do not admit Windows 8 or Windows 11.
:supported_nt
if "%~1"=="6.3" if "%~2"=="9600" exit /b 0
if not "%~1"=="6.2" if not "%~1"=="10.0" exit /b 1
if "%~1"=="6.2" if "%~2"=="9600" exit /b 0
if "%~2"=="" exit /b 1
for /f "delims=0123456789" %%B in ("%~2") do exit /b 1
if %~2 LSS 10240 exit /b 1
if %~2 GEQ 22000 exit /b 1
exit /b 0
