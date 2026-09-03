@echo off
setlocal
cd /d "%~dp0"

echo ========================================
echo        Universal Service OS - TEST
echo ========================================
echo.
echo Ten test uruchamia aktualny USOS w QEMU.
echo Za kazdym razem dostajesz czysty stan, wiec nie zapetli sie

echo na poprzedniej probie. Fizyczne dyski nie sa przekazywane do QEMU.
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\test_usos_qemu.ps1"
if errorlevel 1 (
    echo.
    echo [FAIL] Test USOS nie wystartowal.
    pause
    exit /b 1
)

exit /b 0
