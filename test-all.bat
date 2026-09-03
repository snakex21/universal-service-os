@echo off
setlocal
cd /d "%~dp0"

call test.bat
if errorlevel 1 exit /b %errorlevel%

call selftest.bat
if errorlevel 1 exit /b %errorlevel%

call qemu-test-x86_64.bat
if errorlevel 1 exit /b %errorlevel%

call qemu-test-aarch64.bat
if errorlevel 1 exit /b %errorlevel%

echo [PASS] All host and boot tests passed
exit /b 0
