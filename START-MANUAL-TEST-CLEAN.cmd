@echo off
cd /d "%~dp0"
echo UWAGA: ten wariant kasuje tylko poprzedni stan wirtualnego testu manualnego.
echo Nie dotyka zadnego PhysicalDrive ani fizycznego pendrive'a.
pause
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\start_manual_full_flow_qemu.ps1" -Fresh
if errorlevel 1 (
  echo.
  echo [FAIL] Nie udalo sie uruchomic czystego testu.
  pause
  exit /b 1
)
echo.
echo QEMU dziala w osobnym oknie. To okno mozna zamknac.
pause
