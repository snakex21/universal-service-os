@ECHO OFF
PATH=A:\;A:\WIN98
CLS
ECHO USOS - Windows 98 SE
ECHO Przygotowanie wybranego dysku. Nie wylaczaj komputera.
A:\EXTRACT.EXE /Y /E /L A:\ A:\EBD.CAB >NUL
IF ERRORLEVEL 1 GOTO FAILED
A:\SYS.COM C:
IF ERRORLEVEL 1 GOTO FAILED
MD C:\WIN98
ECHO Kopiowanie plikow instalacyjnych na dysk...
COPY /Y A:\WIN98\*.* C:\WIN98 >NUL
IF ERRORLEVEL 1 GOTO FAILED
IF NOT EXIST C:\WIN98\SETUP.EXE GOTO FAILED
ECHO Dodawanie poprawki RAM dla Windows 98 SE...
A:\CWSDPMI.EXE -s-
A:\PATCH9X.EXE -auto -select mem C:\WIN98
IF ERRORLEVEL 1 GOTO FAILED
C:
CD \WIN98
C:\WIN98\SETUP.EXE /IS
GOTO STOP
:FAILED
ECHO Przygotowanie dysku nie powiodlo sie. Instalator nie zostanie uruchomiony.
:STOP
ECHO Uruchom ponownie komputer, aby wrocic do USOS.
PAUSE >NUL
GOTO STOP
