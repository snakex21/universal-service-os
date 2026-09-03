@echo off
setlocal
set "ROOT=%~1"
set "RESULT=%ROOT%\usos-gpt-result.txt"
echo START>"%RESULT%"
"%ROOT%\usos-gpt-qemu-test.exe" -serial USOS-GPT-TEST -size 42949672960 -out "%RESULT%"
set "RC=%ERRORLEVEL%"
echo EXIT_CODE=%RC%>>"%RESULT%"
wpeutil shutdown
exit /b %RC%
