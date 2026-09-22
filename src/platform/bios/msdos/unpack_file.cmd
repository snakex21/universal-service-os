@echo off
%3 %1 %2 >nul
if not errorlevel 1 goto end
echo EXPAND %1 FAILED>>%2\DOSERR.TAG
:end
