# MiniOS 1c-2/1c-3 — wznowienie po 00abbed0, raport STOP

SPDX-License-Identifier: GPL-3.0-or-later

Data: 2026-10-26 (Europe/Warsaw). Gałąź `codex/minios-etap1`.
Końcowy kod: `61cc50b9ce06179fd6d58be2e9f52daad514507f`.
Próba firmware: czysty `1f83101cea2253130edb1a6388d5763521c445b1`.

**STOP na pierwszej niezaliczonej bramce kroku5.** Win11 x64 UEFI/WHPX128MiB
przeszedł weryfikację metadanych, preflight, skan pustego celu oraz GPT/FAT32/NTFS,
ale rozpakowanie nie zakończyło się w1800s. Ostatni postęp:51338/168751 pozycji,
8594011060B danych i36354 ukończone zasoby. Nie jest to PASS instalacji.
Nie uruchomiono native chkdsk tej próby, kolejnych profili ani pierwszego Windows.

Katalog runtime jest oznaczony jako `<RUNTIME>`; ścieżki dowodów poniżej są
względne wobec niego. Repozytorium nie zawiera obrazów ani payloadu Windows.
Poprzedni raport pozostaje w `docs/minios-report-1c2-1c3.md` i historii00abbed0;
przed podmianą zewnętrznego RAPORT zachowano jego kopię w outputs zadania.

## Wynik kolejnych kroków

| Krok | Wynik | Dowód / ograniczenie |
|---|---|---|
|1: PROGRESS | Kod/testy PASS, widoczny w rzeczywistym gościu | Weryfikacja, preflight, skan i apply;256MiB lub2000zasobów, czas/liczniki/heap/stos. |
|2: mikrobenchmark | PASS, host | Rzeczywisty LZX i SHA-1, osobno x64 i kod i486; tabela niżej. To nie pomiar TCG ani fizycznego486. |
|3: I/O cache | PASS komponentów | Offsety≤64KiB, source cache≤1MiB, adaptacyjny odczyt sekwencyjny. Pełne apply nadal za wolne. |
|4: selected SHA | PASS testów, częściowo wykonany firmware | Metadane przed formatem, DATA/ADS/reparse przy streamingu, odmowa i dirty po błędzie; `verify_scope=all` zachowane. |
|5: Win11 UEFI128 | TIMEOUT1800s, FAIL bramki | Występował postęp do1704s apply. Celu nie oznaczono jako gotowy; dirty=1 potwierdzone niezależnie. |
|5: Win11 UEFI64 | NIE WYKONANO | STOP po pierwszej bramce. |
|5: Win10 IA32128/64 | NIE WYKONANO | STOP po pierwszej bramce. Harness używa64-bitowego QEMU i firmware IA32. |
|5: Win7 BIOS128/64 | NIE WYKONANO | STOP po pierwszej bramce. Nowy mały test TCG486 również niewykonany. |
|6: prawdziwy bcdboot/bootfiles/TCG firstboot | NIE WYKONANO | Nie wolno ominąć niezaliczonego kroku5. Type4/F5 nadal niepotwierdzony startem. |
|7: F-a…F-i / higiena | Tabela poniżej | Bez merge/push/deploy, bez G: i fizycznych nośników. |

## Limity i powód nowego przygotowania

Start kroków1–4:2026-10-25 21:37:21UTC; limit do2026-10-26 00:37:21UTC.
Pierwszy komplet był gotowy22:29:04UTC (~52min). Przegląd wykrył dodatkowy
przypadek directory DATA; poprawkę i końcowe testy zamknięto przed23:05:16UTC,
czyli także w tym samym limicie3h. Nie resetowano zegara.

Krok5 rozpoczęto22:29:04UTC; jego limit2h upływał00:29:04UTC. Zatrzymano się
wcześniej po pierwszym timeout. Limit gościa1800s był wymuszony automatycznie;
kontroler zapisał1832,15s od uruchomienia gościa do zakończenia kontroli sum.
Oczekiwanie było blokujące; aktywnych logów/QMP/obrazów nie odpytywano.

Świeży cel był konieczny: zmieniono instalator, weryfikację i I/O przed pierwszą
udaną migawką. Dotychczasowe duże próby nie utworzyły działającej instalacji,
a ścieżka dopuszcza wyłącznie świeży NTFS. Starych obrazów nie nadpisano.
Nowy cel miał zachowany pusty checkpoint; nie utworzono checkpointu sukcesu
ani nakładki Windows dla nieukończonej instalacji.

## Implementacja i testy

Domyślnie `verify_scope=selected`: selected metadata SHA-1 przed zapisem,
strukturalny preflight każdego odwołania, następnie SHA-1 strumieni podczas apply.
Ostatnia porcja uszkodzonego zasobu nie jest zwracana do NTFS. `finish()` może
wyczyścić dirty dopiero po sukcesie wszystkich strumieni i indeksów. Przy błędzie
`markIncomplete()` utrwala dirty i loguje `TARGET_INCOMPLETE`; obejmuje to także
błąd końcowego flush. Timeout procesu nie wykonuje errdefer — dlatego stan
niepełnego celu został dodatkowo sprawdzony z zamkniętego VHD.

`verify_scope=all` nadal sprawdza surową integrity table i zasoby wszystkich
edycji przed formatem. Selected nie czyta tej archive-wide tabeli. Obydwa tryby
sprawdzają SHA wybranych metadanych i danych. UEFI odrzuca nieznany/podwójny scope;
BIOS używa byte152=0/1 z CRC i kontrolą pozostałych reserved bytes.

Przegląd ujawnił directory/root unnamed DATA: preflight dotąd znajdował blob,
ale zapis katalogu go pomijał. Commit61cc50b9 wprowadza jawną odmowę
`UnsupportedDirectoryData` przed formatowaniem, z testem dla obu scope.
Zwykłe DATA, ADS, reparse i hardlinki pozostają obsługiwane. Ta poprawka powstała
w trakcie próby1f83101c; nie przypisujemy jej wyniku do końcowego61cc50b9.
Pełna próba na końcowym buildzie pozostaje niewykonana po STOP.

PROGRESS podaje seconds/current/total/bytes/resources/MiB/s, rzeczywiste
source/target BlockIo calls+bytes, alloc_peak i painted-stack high-water.
Diagnostyczne zapisy przez file protocol są poza licznikiem source/target.
Koniec tree-walk nie stanowi sukcesu instalacji — wymagany jest WIM PASS po flush.

Offset-cache:39998lookup→2odczyty okien. Source-cache:3073×1KiB→67odczytów;
2048losowych×64B pobrało dokładnie131072B. Jest ograniczony przypadek nadmiaru:
burst32KiB+32KiB+1KiB może uruchomić1MiB prefetch, którego późniejszy seek nie użyje.
To uwaga wydajnościowa; cache nie obiecuje zerowego nadmiaru dla każdego wzorca.

Końcowe czyste F3 na61cc50b9:

- `resume-core-final02.log`:174/174 Zig (162core+12FAT), oba UEFI buildy i audyt IA32 i486 PASS.
- `resume-bios-final02.log`: BIOS i486 build PASS, payload238404B mieści się w240KiB; obraz1MiB.
- `resume-harness-final02.log`:70/70 Python, w tym WHPX/config/VHD/reuse/BCD reference/BIOShost.
- logi zaczynają się od HEAD/WORKTREE_DIRTY0 i kończą tym samym czystym HEAD.
- dev logi zachowano do diagnozy; nie są końcowym dowodem.

## Mikrobenchmark — firmware code na hoście

Rzeczywisty blob LZX1–4MiB z każdego WIM,16przebiegów dekodera i256 SHA-1,
IO poza czasem pomiaru. Wszystkie blob SHA i źródłowe SHA-256 zgodne przed/po.
Kod kompresji i SHA nie zmienił się od clean977f2a02 do końcowego61cc50b9.

| Próbka | LZX x64 / i486 (MiB/s) | SHA-1 x64 / i486 (MiB/s) |
|---|---:|---:|
|Win11 x64 |127,12 /101,05 |873,37 /690,63 |
|Win10 x86 |110,59 /78,03 |850,98 /715,50 |
|Win7 x86 |106,31 /76,86 |859,28 /705,68 |

Szczyt śledzonej alokacji próbki2,51–3,89MB. Nie jest to pomiar całej instalacji,
firmware, TCG ani komputera z rzeczywistym i486. Dowód:
`1c23/final-logs/lzx-sha-bench01/result.json` i `summary.md`.

## Rzeczywista próba WHPX i diagnoza

Win11 index2/10, LZX, WIM7437390947B. QEMU x86_64, q35, WHPX,
`-cpu qemu64,-xsave`,1vCPU,128MiB. Źródło ISO na read-only NTFS;
source/target virtio-blk. Nowy dynamiczny VHD32GiB jako cel.

| Faza | Wynik |
|---|---|
|Selected metadata |41602168B SHA zweryfikowane; czas zaokrąglony do0s. |
|Preflight |168751pozycji,15s;136696plików/32055katalogów. |
|Skan blank |34359738368B,63s, complete=true. |
|Układ |GPT, ESP300MiB FAT32, MSR16MiB, Windows NTFS od332398592B. |
|Ostatni apply PROGRESS |1704s,51338/168751pozycji,8594011060B (~8,00GiB),36354zasoby. |
|I/O w tym punkcie |3176965wywołań,57704810496B source+target łącznie ze skanem. |
|Średnie tempo apply |4,809MiB/s przy ostatnim raporcie. |
|Obserwowany heap/stack |10995916B (~10,49MiB) alloc_peak;372184B (~363,46KiB) high-water. |
|Zakończenie |Timeout1800s; brak WIM PASS/INSTALL_APPLY PASS. |

Nie ma dowodu całkowitego zwisu: liczby rosły przynajmniej do1704s apply.
Nie ma też dowodu ukończenia ani ostatecznego szczytu RAM/stosu. 128MiB nie jest
potwierdzonym minimum dla pełnej instalacji. Źródło i checkpointy mają niezmienione
SHA. Niezależny parser VHD/GPT/FILE/$Volume, bez montowania, potwierdził dirty=1
oraz niezmieniony hash celu po odczycie. Partial VHD ma9055683072B.

**Wniosek:** blokada na Archive.verifyAll została usunięta. Aktualny koszt jest
na ścieżce apply, która wykonuje miliony operacji source/target. Sam szybki
hostowy LZX/SHA nie dowodzi, która część apply dominuje. Następne uprawnione
wznowienie powinno rozdzielić pomiar czasu dekodera, source IO i zapisów/metadanych
NTFS oraz zbadać grupowanie operacji. Nie wydłużono limitu ani nie pominięto bramki.

Dowody: `1c23/qemu-x64/win11-whpx128-01/{result.json,closed-diagnosis.json,progress.csv,debug.log,qemu.stderr}`.

## CPU, RAM i sektory — dokładny zakres

| Wersja | Końcowy kod/build | Rzeczywista próba tego wznowienia |
|---|---|---|
|UEFI x64 |x86_64 |128MiB, częściowe apply;64MiB i komplet niewykonane. |
|UEFI IA32 |i486, audyt bez SIMD/CMOV/post-i486 PASS |Nie wykonano; wymagania samego firmware są osobne. |
|BIOS |i486, build/audyt PASS |Nowy TCG486/Pentium niewykonany; wcześniejsze małe PASS dotyczą wcześniejszego kodu. |

Źródłowy adapter sektorów512/4096 i optyczne2048 mają testy komponentów.
Ta rzeczywista próba użyła512B. Writer instalacji NTFS nadal odmawia celu4Kn
przed zapisem tablicy partycji; nie zgłaszamy pełnego Windows install4Kn PASS.

## Status F-a…F-i

| Punkt | Status | Dowód / pozostały zakres |
|---|---|---|
|F-a UDF0x1800 |PASS kod/testy |Maska bez bitu System, regresja w optical; wcześniejszy dowód1c23 zachowany. |
|F-b kotwice256/N-256/N |PASS kod/testy |Fallback po błędnej kotwicy i checksum, wcześniejsze fixture. |
|F-c unsupported skip/count |PASS kod/testy |Pomijanie/listowanie z licznikiem, odmowa żądanego nieobsługiwanego pliku. |
|F-d limit1M |PASS kod/testy |Wspólny walker w bibliotece, ograniczenie pętli/drzewa. |
|F-e pierwotny błąd Stream |PASS kod/testy |Log zachowuje original error; adapter i cache nie ukrywają przyczyny. |
|F-f NTFS AL/>128runs |PASS ograniczonego zakresu |Czytnik pliku do8192runów i ATTRIBUTE_LIST; wcześniejszy rzeczywisty Windows-copy512runów/3extentów zachowany. ATTRIBUTE_LIST samego $MFT jawnie odmawiany. |
|F-g ESD/SWM |PASS diagnostyki, brak pełnej obsługi |Jasny komunikat; solid ESD i multipart SWM nadal wyłączone. |
|F-h SYS/CER |AUDYT PASS, integracja oczekuje |Master0ba50f6e:34, branch74;40branch-only. Od00abbed0 zero zmian SYS/CER. Nie wszystkie takie rozszerzenia oznaczają ten sam rodzaj autora. |
|F-i kopie VHD1c-1 |WYKONANE wcześniej za osobną zgodą |4pliki/47244642304B, receipt `docs/minios-cleanup-accepted-1c1-vhds.json`. W tym wznowieniu NIC nie usunięto. |

Win11 tagged type4/F5 pozostaje „pominięty i raportowany”. Nie potwierdzono jego
nieszkodliwości startem Windows; pierwszy start nie został dopuszczony.

## Commity

| Commit | Zamknięty kawałek |
|---|---|
|51760a50 |PROGRESS, telemetry, blank scan i testy. |
|977f2a02 |Mikrobenchmark LZX/SHA x64/i486. |
|ac438ff4 |Cache offsetów i source readahead, hooki SHA progress. |
|8e826223 |Adaptacyjny prefetch ograniczający losowy nadmiar. |
|941c599c |Przygotowanie WHPX, timeout, scope. |
|b441f03c |Bezpośredni dynamiczny VHD, zachowane checkpointy. |
|12e5fe04 |Native reuse gotowego VHD bez drugiego pełnego eksportu. |
|5f5b0350 |Rzeczywista mała próba VHD bez gościa. |
|1f83101c |Selected streaming SHA, incomplete, integracja telemetrii i cache. |
|3fda8704 |Ścisły kontrakt reuse dla przyszłego prawdziwego bcdboot. |
|0a774716 |BIOS boot admission wymaga końcowego SHA PASS. |
|61cc50b9 |Odmowa directory DATA przed formatem i test obu scope. |

Przygotowane kontrakty Step6 przeszły testy hostowe, ale prawdziwy bcdboot na
nowym układzie, bootfiles i TCG/OOBE pozostają niewykonane. Przy następnym
wznowieniu nie używać starego endpointu900s jako rzekomego testu3h; konfiguracja
pełnego limitu3h ma zostać sprawdzona przed dopuszczonym pierwszym bootem.

## Obrazy i dowody

Pula po zamknięciu:77,40/150GiB; wolne149,71GiB (rezerwa100GiB zachowana).
`resume-closed-images.json` zawiera56obrazów tego etapu:21703018496B,
każdy z pełną względną ścieżką, rozmiarem i SHA-256. Klasyfikacja obejmuje
raw/qcow2/vhd/vhdx/fd/img. Żadnego obrazu ani dowodu nie usunięto.

Nowe obrazy — **do ewentualnego usunięcia dopiero po osobnej akceptacji**:

| Ścieżka względem runtime | Bajty | SHA-256 | Dowód |
|---|---:|---|---|
| `1c23/fixtures/vpc-direct01/target-blank.vhd` | 2100224 | `5ad9bc4567d93c6ca5cc8dd2cb4ece463e53295794f3b08f0daa719eebc9ec83` | vpc-direct01/result.json |
| `1c23/fixtures/vpc-direct01/target.qcow2` | 328192 | `eae3d7fb9066998c581c32601d3f8f8d88997984dee144a05abfa3bc89301a79` | vpc-direct01/result.json |
| `1c23/fixtures/vpc-direct01/target.vhd` | 4197888 | `703c77bcf3f83be9ce51dc86cc772610a434ce326b22c5002a31fdcd2cbcc8ff` | vpc-direct01/result.json |
| `1c23/qemu-x64/win11-whpx128-01/boot-base.raw` | 68157440 | `964a3a26b0d7296ced8c3b6451b4c39cc322cc814d47e7f6c849786b1bd7990d` | result.json + closed-diagnosis.json |
| `1c23/qemu-x64/win11-whpx128-01/boot.qcow2` | 786432 | `8c0e18ddf7fc92fc542ec2ed98676ee537143fc9b65c2808c9269add17791e41` | result.json + closed-diagnosis.json |
| `1c23/qemu-x64/win11-whpx128-01/target-blank.vhd` | 2165248 | `2e3ab477d56c42fe5b9abdac24be3ff6e89f3b2c7bcb31fc87b2d2a4a3889b8e` | result.json + closed-diagnosis.json |
| `1c23/qemu-x64/win11-whpx128-01/target.vhd` | 9055683072 | `a6346851a830b7d546076123f56f1a37703880c5377a3b92a2e92881076d92b1` | result.json + closed-diagnosis.json |
| `1c23/qemu-x64/win11-whpx128-01/vars.fd` | 540672 | `b0bcd83a209785521235492decc423f5cd4dc451e7ab309eabf46379f7fcf062` | result.json + closed-diagnosis.json |

Małe dowody zachowane: logi F3, manifesty, bench summary, progress CSV, receipty,
pełne SHA i niezależna analiza dirty. Indeks: `docs/minios-evidence-1c23-resume.json`.

Bez merge/push/deploy. Bez nośników fizycznych i bez G:. Integracja wyłącznie
przez selektywny cherry-pick ścieżek MiniOS; nigdy merge całej gałęzi. Nie przenosić
SYS/CER, szczególnie acpi.sys. Hostowe testy nie zastępują niezaliczonej bramki5.

**STOP.** Nie uruchamiać kolejnego gościa ani pierwszego Windows bez nowego
zlecenia odnoszącego się do opisanej bramki wydajności apply.