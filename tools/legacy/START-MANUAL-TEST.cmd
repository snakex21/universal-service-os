@echo off
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\start_manual_full_flow_qemu.ps1"
if errorlevel 1 (
  echo.
  echo [FAIL] Nie udalo sie uruchomic testu.
  pause
  exit /b 1
)
echo.
echo QEMU dziala w osobnym oknie. To okno mozna zamknac.
pause
