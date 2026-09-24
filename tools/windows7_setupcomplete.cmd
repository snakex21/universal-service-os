@echo off
rem USOS: installs the user's DATA\Drivers\Windows 7 packages once Windows 7 is
rem installed (Setup runs %WINDIR%\Setup\Scripts\SetupComplete.cmd as SYSTEM
rem before the first logon). USOS writes this file only when Setup ran without
rem an answer file, i.e. without the DriverPaths entry (docs/drivers.md), and
rem only when the installed image has no SetupComplete.cmd of its own.
setlocal EnableExtensions DisableDelayedExpansion
set "USOS_DRV=%SystemDrive%\USOS\Drivers"
set "USOS_LOG=%USOS_DRV%\usos-pnputil.log"
if not exist "%USOS_DRV%\" exit /b 0
echo [USOS] SetupComplete: pnputil -i -a for the packages in %USOS_DRV%>>"%USOS_LOG%"
for %%C in (Storage USB Other) do if exist "%USOS_DRV%\%%C\" for /r "%USOS_DRV%\%%C" %%I in (*.inf) do (
    echo [USOS] %%I>>"%USOS_LOG%"
    "%SystemRoot%\System32\pnputil.exe" -i -a "%%I" >>"%USOS_LOG%" 2>&1
)
echo [USOS] SetupComplete: done>>"%USOS_LOG%"
exit /b 0
