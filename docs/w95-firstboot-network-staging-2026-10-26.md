# 950: ograniczenie wielokrotnego skanowania CAB

Zamknięta próba `rtm-nvme-02/native-02` zakończyła się po3604,68s bez GUI: oryginalny DOS nadal wykonywał `NFILES.BAT`, ostatni plik w logu to `ftp.exe`. `FIRSTBT.LOG`, `FIRSTBT.ERR` i `FIRSTBT.OK` nie powstały; nie jest to wynik GRPCONV ani instalatorów dodatków. Wcześniejszy limit1200s również przerywał ten etap. Oba obrazy i dowody zachowano.

Każde osobne `EXTRACT /A ... nazwa` skanuje cały dalszy zestaw CAB, również po odnalezieniu pliku. Dotychczasowy skrypt generował51 takich poleceń. Mały eksperyment w oryginalnym DOS950 potwierdził, że jeden EXTRACT przyjmuje wiele nazw: `ftp.exe`, `winipcfg.exe`, `winsock.dll`, exit85/71,296s, trzy prawidłowe pliki MZ. Początkowy błąd naszego odczytu małych nazw przez rozróżniający wielkość liter PyFatFS skorygowano na tym samym zamkniętym obrazie; VM nie uruchamiano ponownie. Dowód: `extract-group-probe-01/result.json` na K:.

`tools/w9x_reg95.sh` grupuje teraz nazwy w12 poleceniach, każde do125bajtów razem z przekierowaniem, zgodnie z ograniczeniem COMMAND.COM. Oryginalny EXTRACT i pliki z oryginalnych CAB trafiają do własnego `C:\USOS9X\NET\NF`. Do katalogów Windows kopiowane są wyłącznie brakujące pliki, więc istniejące i łatane pliki pozostają. Grupa, której wszystkie cele istnieją, nie uruchamia EXTRACT. Zestaw51 plików, strażniki RUN/OK/ERR oraz bramka importu rejestru pozostają. Poprawka jest w ścieżce źródła950 po fazie1.

Walidacja:

- 38 testów hosta: generator plików sieciowych, rejestr95 i etykiety DOS PASS. Pierwszy przebieg wykrył zbyt długi wiersz133B spowodowany ucieczką `$cab` w obliczeniu długości; po poprawce maksimum125B i wszystkie38 PASS.
- Rzeczywisty wygenerowany `NFILES.BAT` na nakładce niezmiennej bazy fazy1 RTM: oryginalny DOS, WHPX wyłącznie dla komponentu DOS, exit85/88,043s. Wszystkie51 wcześniej brakujących plików obecne i niepuste, `NFILES.OK`, brak RUN/ERR. Nie uruchamiano Windows. Dowód `netfiles-group-production-01/result.json`; SHA skryptu `8270d84a694f045eef915e0d32e7ac499fddc04047ee2cce50c69f830de48b2f`.
- Oddzielny kontrprzykład zachowania plików:51 istniejących celów, w tym własny znacznik testowy zamiast `vredir.vxd`, wyłącznie w nakładce komponentowej bez uruchamiania Windows. Exit85/15,864s, wszystkie oczekiwane SHA zachowane, OK bez RUN/ERR; `netfiles-group-preserve-01/result.json`. Oryginalna baza i źródła pozostały tylko do odczytu.

Wyniki DOS/WHPX nie są pomiarem czasu natywnej ścieżki CSMWrap/TCG ani PASS pierwszego pulpitu. Po pełnym buildzie poprawiony skrypt trzeba sprawdzić w tym rzeczywistym przepływie.

Reinstalacja jest zbędna: zmiana dotyczy wyłącznie `C:\USOS9X\NET\NFILES.BAT`, wykonywanego po zapisanej, zaliczonej fazie1. Dalsza próba ma być nową nakładką tej bazy z tą jedną aktualizacją skryptu; żadnych wstępnie rozpakowanych plików sieciowych z komponentowego testu ani znaczników sukcesu. Profile, CAB, rejestry Windows, dodatki i pozostałe helpery pochodzą z zaakceptowanej bazy.
