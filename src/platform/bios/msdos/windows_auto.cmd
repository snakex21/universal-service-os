@echo off
prompt $p$g
path C:\DOS;C:\WINDOWS;C:\PROGRAMS
set TEMP=C:\TEMP
if "%CONFIG%"=="DOSONLY" goto dos
if "%CONFIG%"=="WINSET" goto settings
if not exist C:\WINDOWS\WIN.COM goto missing
C:
cd \WINDOWS
if "%CONFIG%"=="WIN386" goto enhanced
echo Windows 3.x - tryb standardowy, bez cache dysku.
WIN.COM /S /B
goto end
:enhanced
echo Windows 3.x - test trybu rozszerzonego 386.
echo Jesli Windows nie startuje, po restarcie wybierz tryb standardowy.
WIN.COM /3 /B
goto end
:settings
if not exist C:\WINDOWS\SETUP.EXE goto missing
rem Maintenance Setup may not locate compressed drivers in the flat source.
rem Supply the original PS/2 driver only when no installed copy exists.
if exist C:\WINDOWS\SYSTEM\MOUSE.DRV goto mouse_ready
if not exist C:\WINSETUP\MOUSE.DRV goto compressed_mouse
copy C:\WINSETUP\MOUSE.DRV C:\WINDOWS\SYSTEM\MOUSE.DRV /y >nul
if errorlevel 1 goto mouse_failed
goto mouse_ready
:compressed_mouse
if not exist C:\WINSETUP\MOUSE.DR_ goto mouse_failed
C:\DOS\EXPAND.EXE C:\WINSETUP\MOUSE.DR_ C:\WINDOWS\SYSTEM\MOUSE.DRV
if errorlevel 1 goto mouse_failed
:mouse_ready
C:
cd \WINDOWS
echo Dla myszy PS/2 wybierz w Setup: Microsoft lub IBM PS/2.
echo Jesli Setup pyta o istniejacy MOUSE.DRV, zachowaj go klawiszem Enter.
pause
SETUP.EXE
goto end
:mouse_failed
echo Nie udalo sie przygotowac sterownika myszy z C:\WINSETUP.
echo Sprawdz pliki zrodla i wolne miejsce na dysku.
goto end
:dos
ver
echo Programy DOS sa w C:\PROGRAMS.
goto end
:missing
echo Brakuje plikow Windows w C:\WINDOWS.
:end
echo.
echo Aby ponownie wybrac tryb uruchomienia, zrestartuj komputer.
