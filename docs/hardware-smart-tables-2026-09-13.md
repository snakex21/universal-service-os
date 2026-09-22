# Czytelny SMART i etapy wykrywania sprzętu

Aktualizacja z 13 września 2026, wydanie `B260913-113611-C1ABE381`.
Dotyczy wbudowanego panelu BIOS `Utilities -> Hardware & SMART`.

## Widok użytkownika

Start pokazuje procent odczytu plików z USB, a po uruchomieniu środowiska
diagnostycznego kolejne etapy: inicjalizacja, wykrywanie kontrolerów
ATA/SATA/NVMe, kontrolerów i dysków USB, klawiatury i myszy oraz otwarcie
panelu. Etapy odpowiadają wykonywanym operacjom; nie skrócono timeoutów
kontrolerów ani zakresu wykrywania. Procent oznacza odczyt plików, nie
szacowany czas całego uruchomienia.

Lista dysków pokazuje `Disk N - model - pojemność`, interfejs i numer
seryjny, gdy jest dostępny. Numer rozróżnia dyski na aktualnej liście;
nie jest trwałym identyfikatorem urządzenia. Wewnętrzna ścieżka `/dev/...`
służy wyłącznie do skierowania odczytu do wybranego urządzenia i do logów.
Nie pojawia się na liście, ekranie oczekiwania, w nagłówkach ani raporcie
wyświetlanym użytkownikowi.

Po wybraniu dysku panel udostępnia tabelę, `Refresh SMART`, `Full report`
i `Back`. Pełny raport otwiera już pobrany wynik, bez kolejnego odczytu
dysku. PgUp/PgDn oraz kółko myszy przewijają wartości pod nieruchomym
nagłówkiem tabeli.

- ATA: ID, nazwa atrybutu, Value, Worst, Limit, RAW oraz zgłoszony stan
  przekroczenia progu. Niezerowy RAW sam w sobie nie jest oznaczany jako
  awaria. Czerwony oznacza zgłoszone bieżące przekroczenie, żółty historyczne.
- NVMe: nazwy i wartości parametrów dziennika zdrowia, bez sztucznych kolumn
  ATA. Critical Warning jest wyróżniany przy wartości niezerowej; zgłoszone
  błędy oraz wykorzystanie trwałości co najmniej 100% mają wyróżnienie żółte.
- SCSI: dostępne parametry temperatury, trwałości, cykli i liczników błędów.
  Pozostałe szczegóły pozostają w pełnym raporcie.

Znaczenie danych RAW i normalizacji zależy od producenta. Szczegółowy opis:
[podręcznik smartctl](https://manpages.debian.org/trixie/smartmontools/smartctl.8.en.html).
Brak atrybutów lub obsługi SMART jest komunikatem o braku danych, nie tabelą
z zerami. Podsumowanie zachowuje rozróżnienie awarii, ostrzeżeń, błędów odczytu,
uśpienia i timeoutu.

## Zakres i weryfikacja

Sesja pozostaje odczytowa. Polecenie SMART nadal ma postać
`smartctl -a -n standby,3`, z limitem 20 sekund; nie uruchamia testu dysku.
Raporty i stan panelu są w RAM, bez montowania systemów plików urządzeń.
Tabela jest ograniczona do 108 wierszy, raport tekstowy do 108 linii
z komunikatem o pominięciu dalszego tekstu. Długie komórki są skracane
wizualnie wielokropkiem. Pełny raport udostępnia oryginalne opisy i kontekst
w granicach limitu widoku.

Pełny build i `tools/tests/run.ps1 -Suite all`: PASS. Dodano testy parsowania
tabel, limitów, dwóch formatów ATA, zachowania wieloczęściowych RAW i dużych
liczników, danych NVMe/SCSI, błędów, pustych wyników oraz układu 640x480.

QEMU qemu64 / 2 GiB / 1280x800: produkcyjny start i rzeczywiste etapy,
tabela emulowanego ATA, NVMe bez ostrzeżeń i z Critical Warning 0x04,
przewijanie do ostatniego wiersza i odświeżenie myszą — PASS.
Próba pełnego raportu wykryła różnicę składni regex pomiędzy awk na hoście
i BusyBox; separator został poprawnie escapowany w końcowym wydaniu.

Końcowa paczka przeszła ponowny start, otwarcie pełnego raportu ATA,
przewijanie, komunikat o braku SMART przez mostek USB, zastąpienie nazwy
urządzenia w jego raporcie oraz ekran informacji o komputerze — PASS.
Aktualizacja zweryfikowanego Kingstona: PASS. Niezależny odczyt wszystkich
78 plików ESP i identyfikatora wydania potwierdził zgodność z paczką.
Pięć plików MySysInf w `Utilities/FreeDOS/Programs/SYSINFO` zachowało
identyczne sumy SHA-256.
Powrót do głównego menu USOS przez restart: PASS. Po zamknięciu obu sesji
trzy obrazy badanych dysków zachowały identyczne SHA-256.

Logi i sumy dysków testowych: `zig-out/hardware-table-work/`.
Zrzuty: `zig-out/win3-work/hardware-table-*.png`.
Wyniki VM nie zastępują weryfikacji odczytu SMART przez fizyczne kontrolery.
