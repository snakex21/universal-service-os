@echo off
setlocal
cd /d "%~dp0"

echo ========================================
echo    Universal Service OS - RESET TESTU
echo ========================================
echo.
echo To usuwa tylko wirtualny dysk z zainstalowanym Windowsem

echo i stan testowej sesji USOS w tools\tests\artifacts\qemu.
echo Fizyczne dyski nie sa dotykane.
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\reset_usos_qemu.ps1"
if errorlevel 1 (
    echo.
    echo [FAIL] Nie udalo sie wyczyscic testu.
    pause
    exit /b 1
)

echo.
echo Gotowe. TEST-USOS.cmd uruchomi nowa czysta instalacje.
pause
