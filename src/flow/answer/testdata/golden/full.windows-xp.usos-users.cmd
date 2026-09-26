@echo off
rem USOS: local administrator accounts from usos-xp.ini, run hidden by pae.exe at setup end.
set USOS_LOG=%SystemRoot%usos-users.log
net user "Tester" "Test123!" /add >> "%USOS_LOG%" 2>&1
for %%G in (Administrators Administratorzy Administratoren Administrateurs Administradores Administratori) do net localgroup %%G "Tester" /add >> "%USOS_LOG%" 2>&1
net user "Drugi" "Test123!" /add >> "%USOS_LOG%" 2>&1
for %%G in (Administrators Administratorzy Administratoren Administrateurs Administradores Administratori) do net localgroup %%G "Drugi" /add >> "%USOS_LOG%" 2>&1
exit /b 0
