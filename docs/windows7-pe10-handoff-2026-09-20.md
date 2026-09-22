# Windows 7 przez PE10 — 20 września 2026

## Rzeczywista ścieżka

Menu UEFI klasyfikuje wybrane ISO w `windows7_iso.zig`. Oryginalny
Windows 7 wymaga jednego zgodnego dawcy Windows 10 x64. Hybryda używa
własnego PE. Rozruch prowadzi przez WIMBoot i pliki w RAM; nie jest to
ścieżka EfiFs → rozpakowany WORK używana przez inne warianty instalacji.

PE dawcy dostarcza środowisko i sterowniki do rozruchu. W obu wariantach
Setup pochodzi z `sources/setup.exe` wybranego ISO, obok swoich bibliotek
i plików licencjonowania. `/installfrom` wskazuje obraz z tego samego ISO.
Brak Setup na wybranym ISO zatrzymuje instalację. Nie uruchamiamy wtedy
Setup z boot.wim dawcy. To korekta wcześniejszego wymuszenia
`X:\sources\setup.exe`, na podstawie opisanej poniżej próby sprzętowej.

## Sterowniki i aktualizacje

PE10 zachowuje własny stos USB i storage. Skrypt nie ładuje do niego
pakietów przeznaczonych dla Windows 7. Zewnętrzne pakiety z DATA są
przekazywane do obrazu docelowego przez `offlineServicing/DriverPaths`,
również przy ręcznej instalacji bez pliku odpowiedzi użytkownika.
Nie dodajemy wyboru edycji, klucza produktu ani partycjonowania.

Dla Windows 7 SP1 pomocnik pliku odpowiedzi dodaje pełne pakiety
KB4474419-v3, KB2990941-v3 i KB3087873-v2 do sekcji `servicing`.
SHA-2 jest rzeczywistym CAB transportowanym do RAM, zamiast samego
komunikatu o kolejce. Budowanie sprawdza SHA-256 lokalnego MSU oraz CAB.
To nie jest instalowanie aktualizacji na komputerze gospodarza.

CAB KB4474419 ma tożsamość `Package_for_KB4474419`, wersję `6.1.3.2`,
architekturę amd64. Pakiet wsparcia ma limit 64 MiB zamiast 8 MiB.
Brak CAB przy fladze `usos-sha2-required.flag` zatrzymuje pomocnik.
Starsza ścieżka mikro-Linuksa bez tej flagi zachowuje dotychczasowe dwa
pakiety NVMe. Nie została przebudowana na nowy model instalacji.

Nie ma potrzeby kopiowania luźnego `stornvme.inf/sys` bez katalogu CAT:
kompletne pakiety NVMe są już przekazywane do serwisowania systemu
docelowego. Widoczność dysku w PE10 i sterowniki Windows 7 po restarcie
to oddzielne etapy.

Lokalny katalog `USB_Generic` zawiera zmodyfikowane pakiety podpisane
przez firmy trzecie (m.in. Riolin Limited), mimo wpisów Microsoft w INF.
Nie traktujemy go jako niezmienionego pakietu Microsoftu ani jako dowodu
obsługi wszystkich kontrolerów. Zastana zawartość katalogu sterowników
na pendrivie nie jest automatycznie zastępowana zawartością repozytorium.

## Granice weryfikacji

Użytkownik zlecił krótkie testy i kompilację, bez VM i E2E. Sam wynik
kompilacji nie potwierdza instalacji ani pierwszego rozruchu na płycie.
Próba sprzętowa: CSM Disabled, Secure Boot Disabled, Professional SP1,
kontrola nazwy dawcy i PE, następnie USB, widoczności dysku oraz rozruchu
z dysku po instalacji. Nie deklarujemy zakończonej próby fizycznej.

Kompilacja wydania `B260920-144647-A904119A` zakończyła się kodem 0.
Zig: 30/30 kroków, 216/216 testów. Lokalne testy wyboru Setup, tworzenia
plików odpowiedzi i transportu sterowników: 7 + 15 + 5, wszystkie OK.
Zbudowano pomocniki WinPE, instalator i aktualizator. Sprawdzenie spójności
plików EFI i pakietu osadzonego w instalatorze przeszło. Bez uruchamiania VM.
Log: `zig-out/win7-universal-work/build-sept20.log`.

Kingston został zaktualizowany przez istniejący aktualizator, z kontrolą
modelu, rozmiaru, GUID dysku i GUID wszystkich trzech partycji. Wszystkie
pięć etapów zakończyło się PASS, końcowy wynik `RESULT=PASS`.
Odczyt `J:\EFI\USOS\build-info.ini` potwierdził nową wersję.
Log: `zig-out/win7-universal-work/update-sept20.log`.
Kopia poprzednich plików rozruchu i wsparcia Windows, ze sprawdzonymi
sumami: `zig-out/win7-universal-work/kingston-before-sept20-20260920-164958`.

## Odczyt po błędzie ProductKey — próba fizyczna

Sesja `WinSetup-2026-9-20-16-16-41-1764`, build `B260920-151010-95750AEB`:
WinPE 10.0.19041.2006 zgłasza dwa kontrolery AMD USBXHCI z `problem=0`.
Otwiera ISO Professional SP1 i odczytuje cztery obrazy z install.wim.
Setup 10.0.19041.117 uruchomiony z `X:\sources` zapisuje
`ValidateSetupMedia: Could not find media`, a następnie
`Callback_Productkey_Validate_Unattend`, HRESULT `0x80070002` i kończy
się kodem 31. Zapisany `generated-answer.xml` zawiera tylko pakiety
i DriverPaths, bez ProductKey. To nie jest dowód błędnego klucza użytkownika.

Odczyt oryginalnego ISO potwierdził Setup/WinSetup.dll 6.1.7601.17514
oraz obecność product.ini, ei.cfg, pkeyconfig.xrm-ms i pidgenx.dll.
Korekta utrzymuje Setup przy jego własnych plikach na tym ISO, zachowując
PE10 jako środowisko. Jest to poprawka wynikająca z diagnozy źródła;
log nie wskazuje konkretnego brakującego pliku, a usunięcie błędu ProductKey
wymaga kolejnej próby sprzętowej. Nie dodano klucza ani wyboru edycji.

Niezależnie od tego odtworzono błąd CMD: wywołanie skryptu wewnątrz
bloku `if`, zakończone `exit /b` bez kodu, gubiło wynik 31 i zwracało 0.
Dyspozycja przez etykiety oraz jawne przekazanie `%errorlevel%` usuwa
ten błąd. Krótki test z atrapą skryptu zwracającą 31 był czerwony przed
poprawką i zielony po niej; nie uruchamia instalatora Windows.

Pełna kopia logów, łącznie z wygenerowanym XML:
`zig-out/win7-universal-work/productkey-evidence-20260920-171911`.

Wdrożono na Kingston build `B260920-152059-35E1B1C3`. Kompilacja:
30/30 kroków, 216/216 testów Zig, 2/2 self-test oraz 54 krótkie testy
pomocników zakończone powodzeniem, bez VM/E2E. Dziesięć plików EFI
i wsparcia WinPE sprawdzono SHA-256 po zapisie; układ partycji niezmieniony.
Kopia poprzednich plików: `kingston-before-sept20-20260920-172116`.
Logi: `build-productkey-fix.log` i `update-productkey-fix.log` w
`zig-out/win7-universal-work`. Wynik aktualizacji: `RESULT=PASS`.
