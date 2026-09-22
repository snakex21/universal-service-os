@echo off
rem PE10 uses its own USB stack. The Vista stack is copied only to the new OS.
if /i not "%PROCESSOR_ARCHITECTURE%"=="AMD64" exit /b 2
if exist "%~dp0usos-unattend.xml" (
    echo Vista USB v1 requires manual edition and target selection; answer files are not supported.
    exit /b 2
)
echo [USOS] Vista SP2 installation from USB. Keep CSM enabled for the installed system.
echo [USOS] Mouse and keyboard use PE10 drivers; target USB v11 is prepared before reboot.
echo [USOS] Setup installs Microsoft KMDF 1.11 before restart; USOS checks both framework files.
echo [USOS] Select the intended target disk. You may delete all its partitions and install into unallocated space.
"%~dp0usos-log-x86_64.exe"
"%~dp0usos-vista-install.exe"
set "USOS_VISTA_RESULT=%errorlevel%"
echo [USOS] Vista installer/finalizer exit=%USOS_VISTA_RESULT%
"%~dp0usos-log-x86_64.exe"
if not "%USOS_VISTA_RESULT%"=="0" exit /b %USOS_VISTA_RESULT%
echo [USOS] Vista USB support prepared. Restarting into the installed system.
wpeutil reboot
exit /b 0
