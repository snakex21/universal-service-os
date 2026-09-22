@echo off
if not exist %1\*.%3 goto end
copy %1\*.%3 %2 /y >nul
if not errorlevel 1 goto end
echo COPY %3 FAILED>>%2\DOSERR.TAG
:end
