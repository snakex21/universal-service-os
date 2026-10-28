# W95RTM-FIRSTBOOT — zamknięcie podejścia 2026-10-26

Wynik: **STOP na bramce pełnego buildu; pełna instalacja RTM/OSR1 niezaliczona.**
Zadanie nie osiągnęło wymaganego pierwszego kompletnego pulpitu. Nie uruchomiono
żadnej świeżej instalacji nowym pełnym payloadem. Wyniki komponentowe poniżej
nie zastępują tego kryterium.

Baza: `564a4eeea71a316f11e9d37aa91cf30637865d04`, worktree
`C:\Users\ASRock\usos-work\codex-w95-firstboot`, gałąź `codex/w95-firstboot`.
Kod: `02dea825`. Nie zmieniano chronionego `w95-vesbind`, MiniOS ani obcych gałęzi.

## Przyczyna STOP

Pełny build pozostaje niezaliczoną bramką od pierwszej zakończonej próby
2026-10-25 22:33:24 UTC. Po nieudanym build02 o 22:47:23 UTC nie uzyskano
kompletnego, zweryfikowanego zestawu release. O 2026-10-26 00:00:13 UTC
minęła ponad godzina blokady tej bramki. KOTWICA nakazuje:
„Blokada > 1 godziny = przerwij i opisz w raporcie.” Zatrzymanie nie oznacza
akceptacji FIRSTBOOT ani zamknięcia brakujących kryteriów jako PASS.

- Build01: Windows PowerShell 5 odziedziczył ścieżki modułów PS7, brak
  `Get-FileHash`; błąd przed kompilacją. Prywatny wrapper dostał jawne ścieżki PS5.
- Build02: **632/632 testy Zig PASS**, ale pełny graf 102/104 nieukończony:
  brak ignorowanego `tools/vendor/windows7-nvme/assets.zip`.
  Przywrócono wejścia z chronionego worktree tylko do odczytu; bajty na K:,
  oczekiwane ścieżki C: są dowiązaniami. Zachowano sumy i manifest przywrócenia.
- Build03: zakończony 23:34:16 UTC, exit 1: brak przypiętego MSU SHA-2 dla
  Windows 7. Źródło znaleziono lokalnie, sprawdzono SHA-256
  `99312df792b376f02e25607d2eb3355725c47d124d8da253193195515fe90213`,
  skopiowano 55 853 327 B na K: i utworzono dowiązanie w prywatnym worktree.
- Build04: skrypt Windows PowerShell przerwał przechwytywanie wyjścia na
  `NativeCommandError` dla tekstu `[PASS] supported architecture`.
  Brak pliku `full-build04.result.json`; pełnego buildu nie uznano za PASS.
  Wrapper przygotowano do jawnego `ProcessStartInfo`, osobnych strumieni
  stdout/stderr i oczekiwania `WaitForExit`. Ta korekta nie ma potwierdzenia
  kolejnym pełnym buildem. Nie uruchamia się build05 w tym podejściu.

Poprzednie katalogi wyjściowe zachowano jako `build-output-01-retained`
oraz `build-output-03-retained` na K:. Istniejące dowiązanie `zig-out`
pozostało na miejscu. Nie obchodzono bramki przez użycie starego payloadu.

## Wdrożone i sprawdzone kawałki

| Commit | Zmiana i dowód | Granica wyniku |
| --- | --- | --- |
| `32f90f3f` | DELKEY przed importem, przyczyna do logu, rollback atrybutów i trwałe ERR. Oryginalny DOS/REGEDIT 950 odtwarza odmowę przy atrybutach 0x27; po zdjęciu atrybutów te same bajty dają 0. Produkcyjny VESALATE: exit 85/4,003 s, VLATE.OK, brak RUN/ERR i legacy devnode. 17 testów generatora/parsera + osobny rzeczywisty ul + 6 VESA PASS. | Nie sprawdzono odtworzenia devnode po dwóch pełnych startach nowej instalacji. |
| `273696f2` | USOSGRPW: limit 120 s, pompowanie komunikatów, tylko własny GRPCONV i potomny PROGMAN, zawsze exit 0. Fałszywe procesy zatrzymane po 120027 ms; oryginalny GRPCONV zakończył proces po 2576 ms, jego exit 1, helper 0. Produkcyjny TZFIX z oryginalnymi ulami PL i EN: exit 85/2,458 s i 85/2,254 s, właściwe nazwy, TZFIX.OK. 20 parsera + 21 TZFIX + 9 payload PASS. | Oryginalny GRPCONV kończący proces nie dowodzi udanej świeżej konwersji skrótów. |
| `756ca823` | USOSADD /setup przed tray bez własnego restartu; /setup /check wyłącznie sprawdza pakiety. Syntetyczny pakiet tray=0, helper 3010, później tray=1; 24,084 s. Realny DCOM95 zakończył się 3010 i przeszedł installed-check przed tray. | Cały rzeczywisty zestaw dodatków niezaliczony. |
| `ee9fd17d` | Pełny graf Zig ograniczony do -j2. | Pełny release niezaliczony. |
| `a6c1a9de` | Winsock2 używa obsługiwanego /Q. Własny zasób pomocy potwierdza przełącznik. Następna próba przeszła parser i zatrzymała się na rzeczywistym wymaganiu Microsoft TCP/IP w starej bazie. | Stara baza ma jawne network_runtime_pass=false; nie naprawiano jej. Nowy payload z przygotowaniem TCP/IP nieuruchomiony. |
| `b965188f` | FIRSTBT.BAT i USOSFB.EXE, zwykły RunOnce, dziennik, ekran błędu bez automatycznego wyłączenia; USOSRES/setup przed dodatkami; USOSLAN/setup/refresh przed tray. Oryginalny RunOnce blokuje tray przez 5 s pompowania. Produkcyjny DOS queue exit 85/0,970 s, sześć oryginalnych wartości Setup bez zmian. Koordynator syntetyczny: 41,132 s, dokładnie jeden końcowy restart, check i LAN przed tray, FIRSTBT.OK, potem pulpit. 2 FIRSTBT + 9 payload + 11 etykiet DOS + 27 LAN PASS. | Test kontraktu wyłączał opcjonalny ekran/mysz, część znaczników stanowiła warunki testu. Brak Full HD/sieci/świeżej instalacji PASS. |
| `7e6eda4f` | Nowe źródła i generatory objęte fingerprintem buildu. | Brak finalnego verified release. |
| `02dea825` | Koordynator kończy wyłącznie własne oczekujące USOSVMD.INF przed dodatkami, sprawdza SYSTEM.INI, usuwa tylko USOSVmd. Dwa małe DOS testy pokazują, że nadpisanie istniejącego RunOnce nie przesuwa go na koniec, a REGEDIT4 deletion tego nie rozwiązuje. Rzeczywiste FIRSTBT/VMDLATE DOS hooks: 42,020 s, bez wejścia, pakiet tray=0, jeden końcowy restart, B2 VMDLATE.OK bez RUN/ERR, check/LAN tray=0, potem FIRSTBT.OK i tray=1. | Nie sprawdzono faktycznych ruchów myszy w oknie DOS ani pełnej instalacji. |

Szczegóły źródłowe i rozróżnienie poprawnych/niepoprawnych fixture:
`docs/w95-firstboot-2026-10-25.md`. Zachowane nieudane nakładki obejmują
dialog sieciowy starej bazy, niepoprawne stare przełączniki Winsock2,
brak TCP/IP starej bazy, celowo wychwycone brakujące warunki myszy/Favorites
oraz błędne dyskietki diagnostyczne. Nie zaliczono ich jako PASS.

## Kryteria końcowe

| Wymaganie pełnego przepływu | RTM PL | OSR1 EN |
| --- | --- | --- |
| Nowy pełny build/payload → instalacja bez kliknięć → kompletny pierwszy pulpit | niewykonane | niewykonane |
| Dokładnie jeden końcowy restart po rzeczywistych dodatkach | niewykonane; tylko komponent | niewykonane |
| Jeden adapter po dwóch startach GUI, brak odtworzenia PNP0900 | niewykonane | niewykonane |
| 1920×1080 przed pierwszym widocznym pulpitem | niewykonane | niewykonane |
| TZ/DST, wartości IE i kompletny rzeczywisty zestaw dodatków | niewykonane; TZFIX osobno PASS | niewykonane; TZFIX osobno PASS |
| Faktyczna mysz w oknie DOS | niewykonane | niewykonane |
| BOOTLOG bez fallbacku DISPLAY, brak Safe Mode/automatycznego wyłączenia | niewykonane | niewykonane |
| NVMe za mostkami i porównanie IDE | niewykonane | niewykonane |
| Porównanie kolejności OSR2/98 tylko do odczytu zachowania | niewykonane | niewykonane |

Nie stwierdzono nowej przyczyny awarii pełnego firstboot, ponieważ nowy pełny
przepływ nie ruszył. Nie przypisuje się dawnych wyników z 23.10 nowemu zadaniu.
QEMU nie stanowi potwierdzenia działania na X470.

## Migawki, dodatki, obrazy i ograniczenia

Świeży przebieg był uzasadniony przed jego planowanym startem zmianą samego
instalatora i kolejności przed bazą. Nie wykonano ponownej instalacji.
Komponenty używały osobnych nakładek na zachowanej bazie. Nowa udana
instalacja nie powstała, więc nie utworzono dla niej migawki `base`.
Przygotowane, ale nieuruchomione adaptery normalnego przebiegu mają zachować
stan po fazie 1 jako zewnętrzną migawkę i wszystkie dalsze dyski.

Dziesięć przypiętych plików dodatków znaleziono kanonicznym Finderem po
rozmiarze i SHA-256 w źródłowych archiwach `łatki` oraz podanym Winsock2.
Rozpakowane i surowe prywatne kopie są na K:. Brak IE6 SP1 EN dotyczy
osobnego kompletnego assetu i nie jest przyczyną tej blokady. Fizycznego
pendrive'a nie użyto. Nie wprowadzano surowych plików Microsoftu do git.

Zachowano całe `K:\USOS-VM\W95RTM-FIRSTBOOT-20261025`, wszystkie nakładki,
dyskietki, logi, zrzuty, próbki uli, wejścia i wyjścia buildów.
Dokładny spis obrazów z rozmiarami jest w `artifacts/firstboot/retained-images.json`.
**Usunięte rzeczy: brak (0).** Przed build04 własna pula zajmowała
3 125 847 177 B, wolne K: 136 577 880 064 B. To pomiar puli tego zadania;
starsze zamknięte pule innych zadań nie są jej częścią. Nie zmieniono ich.

QEMU używało najwyżej dwóch zarezerwowanych silników (w tych próbach
komponentowych po jednym), BelowNormal, do dwóch CPU. Pełne buildy
wywoływano wyłącznie przez `cmd /d /c "cd /d <repo> && .\build.bat"`.
Oczekiwano na zakończenia/zdarzenia; nie odpytywano postępu.
Nie wykonano merge, push, deploy ani dostępu do fizycznych dysków/G:.

## Zmienione pliki kodu względem bazy

```
build.bat
docs/w95-firstboot-2026-10-25.md
installer/cmd/usos-payload-pack/main.go
src/addons/legacy-pack.ini
src/platform/bios/dos_startup.cmd
src/platform/bios/win9x/vesbind.c
src/platform/win32_legacy/usosadd/main.c
src/platform/win32_legacy/usosfb.c
src/platform/win32_legacy/usosgrpw.c
tools/build_micro_linux.py
tools/build_usosfb.py
tools/build_usosgrpw.py
tools/build_win9x_support.py
tools/generate_build_info.ps1
tools/tests/golden/staged_payloads.tsv
tools/tests/test_dos_native_payload_lists.py
tools/tests/test_network_defaults.py
tools/tests/test_w9x_firstboot.py
tools/tests/test_w9x_tzfix.py
tools/tests/test_w9x_vesbind.py
tools/verify_release_consistency.ps1
tools/w9x_csmwrap_target.sh
tools/w9x_firstboot.sh
tools/w9x_tzfix.sh
tools/w9x_vesa95.sh
tools/windows_usos_lan.c
tools/windows_usos_res.c
```

Dodatkowy commit dokumentacyjny przechowuje ten raport oraz spis zachowanych
obrazów na tej samej gałęzi. Lokalna orkiestracja i logi pozostają w
`artifacts/firstboot`; adaptery pełnego przepływu są niezweryfikowane.

Nowe, odrębne R0 W9X-NATIVE-SETUP przekazano na jawne polecenie użytkownika
do sesji `01a17579-80a4-7fb2-a730-c1cdc1d11835`. Nie jest kontynuacją FIRSTBOOT.
Po tym raporcie: **STOP**, bez automatycznego nowego buildu/reinstalacji.

## Zakończenie procesów i spis dowodów

2026-10-26 00:05:38 UTC: jednorazowa diagnostyka po ponad 300 s od błędu wrappera nie wykazała pozostałych własnych procesów buildu. Niczego nie zakończono siłowo; build05 nie ruszył. Receipt: `artifacts/firstboot/build04-process-drain.json`.

Spis zawiera 84 zachowanych obrazów, łącznie 2340357144 B przydzielonego miejsca. Jest także w śledzonym `docs/w95-firstboot-retained-images-2026-10-26.json`. Składnia poprawionego wrappera PowerShell PASS; brak kolejnego pełnego buildu.
