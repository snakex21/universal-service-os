# MiniOS 1c4 — STOP i punkt wznowienia

2026-10-26. Gałąź `codex/minios-etap1`. Kod końcowy: `f716537893002265ad431812bb24b4000980977f`.

**STOP na pierwszej bramce Win11 WHPX / 128 MiB: timeout 900 s.** Użytkownik następnie poprosił o zakończenie pracy na dziś. Wszystkie uruchomione operacje zakończone; nie uruchamiać dalszych VM bez wznowienia. To postęp w kodzie i diagnozie, nie zaliczenie pełnej instalacji ani pierwszego startu Windows.

**1. Tanie testy A/B, wykonane przed zmianami kodu produkcyjnego**

A: niezmieniony natywny program na hoście Windows, Win11 obraz 2, bez QEMU, do rzadkiego RAW 32 GiB: **212,856291 s**, zakończenie apply poprawne. Źródło WIM pozostało bez zmian. To pomiar bezpośredniego WIM, z pojedynczą partycją NTFS GPT; nie obejmuje ISO-na-NTFS ani układu ESP/MSR z firmware. Nie wykonano dla niego chkdsk ani pełnej niezależnej kontroli drzewa. Nie mierzono ms/wywołanie natywnego RAW.

B: niezmieniony firmware, WHPX, 128 MiB, nowy QCOW2, ten sam Win11 i ISO na źródłowym NTFS. Limit 400 s całego gościa zapewnił ponad 300 s apply; ostatnia linia apply ma 311 s. Celowo ograniczony test diagnostyczny, nie pełna instalacja. Porównanie z wcześniej zamkniętym VHD; nowego gościa na VHD nie uruchamiano.

Ten sam odcinek: pozycje **10151 → 12613** (2462 pozycje, 2000 zasobów, 10547056 B):

| Wersja / backend | Odcinek apply | Liczba BlockIo | Czas odcinka | Czas / zbiorcze wywołanie |
|---|---:|---:|---:|---:|
| Stary dynamiczny VHD | 163–671 s | 97318 | **508 s** | **5,220000 ms** |
| Bazowy QCOW2, bez nowych cache | 52–60 s | 97318 | **8 s** | **0,082205 ms** |
| Końcowy QCOW2, cache i profilowanie | 175–205 s | 27532 | **30 s** | **1,089641 ms** |

Pierwsze A/B potwierdza poprawę **63,5×** dla tego odcinka po zmianie backendu. Liczba wywołań była identyczna. To iloraz czasu całego odcinka i **zbiorczych wywołań źródła oraz celu**, nie zmierzona osobno średnia latencja dysku docelowego. Zegar gościa ma rozdzielczość 1 s; liczby w ms są przeliczeniem, nie pomiarem o takiej precyzji.

Stary VHD pochodzi z `1f83101c`, bazowy QCOW2 z `1fb9157a`. Różnica obejmuje dodatkową odmowę nieobsługiwanego DATA katalogu przed formatowaniem; badany zwykły przebieg Win11 ma identyczne punkty oraz liczniki. Wniosku o czasie nie należy rozszerzać na inne obciążenia.

Dowody względem katalogu puli: `1c4/host-baseline/result.json`, `1c4/probe-qcow/win11-128/result.json`, `1c23/qemu-x64/win11-whpx128-01/result.json`. CSV i porównania: `1c4/report-final02/`.

**2. Zamknięte zmiany kodu**

- Żywy cel w runnerach jest QCOW2. Dynamiczny VHD odrzucany przed IO; konwersja do VHD pozostaje pojedynczym końcowym krokiem niezależnej kontroli Windows. Stare zamknięte VHD są nadal czytelne do audytu.
- Cache MFT: 1064960 B, zwykły rekord budowany w RAM i zapisany raz; rekordy 0–26 pozostają bezpośrednie. Zachowane bootstrap, mirror, kolejność ATTRIBUTE_LIST, ponowne użycie rekordów i dirty po błędzie. Read-only miss nie może wywołać zapisu przez wyparcie dirty rekordu.
- Cache indeksów: 32 bloki po 4096 B, przygotowanie pojedynczego lookup+insert z kontrolą owner/revision/root/nazwy. Trwała bitmapa bieżącego katalogu, ograniczone flush i usunięte redundantne przełączanie katalogów przy mkdir.
- Bufor celu 1 MiB, odczyt widzi oczekujące zapisy, zachowana kolejność i obsługa błędów. UEFI przekazuje duży wyrównany zapis do BlockIo bez podziału na 64 KiB. BIOS zachowuje limit EDD 127 sektorów / 65024 B.
- Hint alokacji wolumenu nie cofa się przy każdym release; nadal zawija do zwolnionego miejsca. Alokator rekordów MFT ma osobną preferencję dokładnego ponownego użycia.
- Kategorie czasu: dekoder, SHA-1 zasobów, fizyczne IO źródła i celu, MFT, indeks; liczba ukończonych plików i tempo. Czas kategorii jest kumulacyjny i exclusive. Stos oraz peak alokatora nadal raportowane.
- PM timer czytany z walidowanego ACPI, bez zapisu konfiguracji i bez instrukcji zegara nowszych niż i486. Brak coarse RTC lub niepewne przepełnienie unieważnia czas; log pokazuje null, nie fałszywe zero.
- Przegląd usunął redundantny zewnętrzny flush poza zakresem dirty recovery. Złożony test WIM+MFT+bufor wymusza awarię ostatniego flush: dirty=1 w głównym i lustrzanym rekordzie, brak PASS.
- Prywatny slot instalatora BIOS ma 272 KiB. Payload 255140 B, zaokrąglony koniec ładowania 0x5e600, BSS koniec 0x5e4dd, stos od 0x60000. Wspólne źródła legacy i globalny packer pozostały bez zmian. To wynik statyczny, nie test gościa BIOS.

**3. Testy i pomiary komponentów**

Końcowe, czyste F3 przy wskazanym HEAD: **228/228 Zig, 76/76 Python**, build UEFI x64/IA32, BIOS compile/link/pack i audyt i486 PASS. Każdy końcowy log zaczyna się od HEAD i WORKTREE_DIRTY 0, kończy tym samym HEAD i czystym drzewem. Testy i buildy ograniczone do dwóch CPU, niższy priorytet, `-j2`, jeden kompilator naraz.

- 2100 małych plików: **2100 fizycznych odczytów i 2100 zapisów zwykłych rekordów MFT** na poziomie NTFS→Disk, nie ostatecznego BlockIo.
- 3000 plików: **8 odczytów INDX**, 3296 zapisów INDX, 3000 przygotowanych wstawień, 1 odczyt bitmapy / 142 zapisy.
- Cały test celu po formatowaniu, wraz z końcową trwałością: **12560 wywołań / 3000 plików = 4,187 na plik**. Wymuszony limit: 8/plik + 1024 na wzrost. To rzeczywiste wywołania backendu celu w teście pamięciowym, nie tempo firmware.
- 50 tys. wstawień: odczyty backendu indeksu **383953 → 0**, identyczne chronione bajty drzewa i 56265 zapisów. Cache + hint + bitmapa: 141112 B. Osobny test 150 tys. nazw, usuwania i ponownego użycia PASS.
- Bufor: **16 × 64 KiB → jeden zapis 1 MiB**, wyrównanie i scenariusze awarii PASS.

Surowe logi: `1c4/logs/core-final01.log`, `harness-final01.log`, `bios-final01.log`. Zig wypisuje przy pomiarach także tekst `failed command`; końcowa suma, kod wyjścia i bramka procesu wynoszą 228/228 oraz EXIT 0. Zachowano pełny log, bez usuwania takich linii.

**4. Pełna próba firmware Win11 — FAIL czasu**

QEMU q35, WHPX, `qemu64,-xsave`, 1 vCPU, 128 MiB, QCOW2 32 GiB, `verify_scope=selected`. ISO z istniejącego NTFS źródła. **Limit gościa 900 s**, po nim proces zakończony przez harness. Cały kontroler: **934,657 s**, zawiera także sprawdzenie hashy po zatrzymaniu; nie nazywać tego czasem apply.

Ostatnia linia apply: **19561/168751 pozycji**, 12871 zasobów, **3094080144 B**, 431 s tej fazy. To częściowy odczyt postępu, nie kompletne apply. Brak końcowego WIM PASS.

| Faza | Bazowy QCOW2 | Końcowy build | Wywołania w obu próbach |
|---|---:|---:|---:|
| Preflight wybranego obrazu | 14 s | **190 s** | 72615 |
| Skan pustego dysku 32 GiB | 70 s | **198 s** | 524288 |
| Apply do tej samej pozycji 19561 | 119 s | **431 s** | 920742 → 274617 |

Liczba IO spadła, ale **wersja końcowa jest wolniejsza**. Wstępnie podejrzany jest koszt częstych odczytów PM timera i dodatkowej instrumentacji w WHPX. To hipoteza, nie potwierdzona przyczyna: nie wykonano pary prób tego samego buildu z profilerem włączonym/wyłączonym. Nie przypisywać regresji wyłącznie buforowi albo backendowi. Szczególnie ważny jest spowolniony skan, przy identycznych 524288 odczytach i bez pracy MFT.

Końcowy log ma **3163130 odczytów zegara**, valid=true, invalid=0, nesting_errors=0, depth_overflows=0. Czasy exclusive od początku apply do ostatniej linii (różnica względem pierwszego snapshotu fazy):

| Kategoria | Czas |
|---|---:|
| Dekoder | 61,235 s |
| SHA-1 zasobów | 11,994 s |
| IO źródła | 90,720 s |
| IO celu | 210,158 s |
| MFT | 7,730 s |
| Indeks | 14,776 s |

Suma nie obejmuje całego czasu: poza zakresami pozostają m.in. część narzutu pomiaru, logowania i innych prac. To czasy **instrumentowanego** przebiegu, nie wynik bez kosztu obserwacji.

Ostatni peak alokatora: **12044492 B ≈11,49 MiB**, obejmuje własny stos 1 MiB. Ostatni stack high-water: **417576 B ≈407,79 KiB**. To żywe snapshoty niedokończonej próby; brak końcowego pomiaru wycieku/canary i brak pomiaru innych wersji/RAM. Nie utożsamiać ich z całkowitym RAM firmware.

Niezależny odczyt zamkniętego QCOW2, bez montowania i eksportu: GPT/ESP/MSR/NTFS rozpoznane, **dirty=1 w głównym i lustrzanym Volume**, rekordy zgodne. Źródło, bazy i łańcuch QCOW bez zmian. Nie stwierdzono na tej podstawie twardego zawieszenia; wymuszono limit, a ostatni postęp nie jest terminalnym błędem.

Dowody: `1c4/win11-final/whpx128-01/{result.json,debug.log,qemu.stderr}`, `closed-structure/result.json`, `1c4/report-final02/{evidence.json,final-progress.csv,inspection-script.py}`.

**5. Niewykonane bramki**

Po timeout STOP, bez kolejnego podejścia i bez obchodzenia bramki. **Nie wykonano**: pełnego porównania drzewa/SHA/SD, Windows chkdsk dla finalnego dysku, Win11/64 MiB, Win10 IA32, Win7 BIOS, małego TCG486 na finalnym buildzie, porównania BCD z bcdboot, zapisania plików rozruchowych, pierwszego startu Windows i potwierdzenia pominięcia metadanych typu 4 Win11. Build IA32/BIOS PASS nie oznacza PASS tych uruchomień.

Miejsce: przed próbą było 122,76 GiB wolnego, pełny plan firmware+VHD wymagał rezerwy 28 GiB i naruszałby zasadę pozostawienia 100 GiB. Użytkownik poprosił o liczby A/B do przeglądu, nie udzielił zgody na usunięcie obrazów. Uruchomiono wyłącznie firmware w osobnej rezerwie 14 GiB. **Główną przyczyną obecnego STOP jest timeout**, niezależnie od ograniczenia dalszej kopii VHD.

**6. Obrazy i zakres zmian**

W tym podejściu zachowano **13 nowych obrazów/plików NVRAM**, łącznie **46214318080 B rozmiaru logicznego**. Pełna lista, rozmiary, SHA i źródło każdego hasha: `1c4/report-final02/retained-images.json` oraz kopia `docs/minios-retained-images-1c4.json`. Duże hashe pochodzą z zamkniętych receipt; małe obrazy ponownie zahashowano przy raporcie. To nie oznacza powtórnego hashowania wszystkich dużych starych obrazów.

**Usunięte: brak.** Wszystkie logi, manifesty, receipt i obrazy zostają do akceptacji. Propozycja poniżej nie jest zgodą ani zleceniem automatycznego usuwania:

| Ewentualnie do usunięcia po akceptacji | Bajty | Dowód / SHA-256 |
|---|---:|---|
| `1c4/host-baseline/target.raw` | 34359738368, sparse | `1c4/host-baseline/result.json`; `18bd451dea6938bf1161d106beed70525d2e55988fe81a4d216c332e2e452c9c` |
| `1c4/probe-qcow/win11-128/target.qcow2` | 8248950784 | receipt obok; `1f8cb5b5bf8bc594e3727cf38a64849bac8d13898c86e95c25e224803ac5c69c` |
| `1c23/qemu-x64/win11-whpx128-01/target.vhd` | 9055683072 | receipt obok; `a6346851a830b7d546076123f56f1a37703880c5377a3b92a2e92881076d92b1` |

Rozmiar logiczny sparse RAW nie jest ilością miejsca odzyskanego po skasowaniu. Pula po zamknięciu: **120,44/150 GiB**, wolne **118,78 GiB**; raport pojemności zachowuje nieprzeglądane rezerwy starszych zakresów.

Zero zmian `.sys`/`.cer`, wspólnych plików BIOS legacy i globalnego packera. Bez merge, push, deploy, dysków fizycznych i G:. Integracja nadal wyłącznie przez wybór ścieżek MiniOS; nie przywracać starych binariów z historii gałęzi.

**7. Commity i wznowienie**

| Commit | Kawałek |
|---|---|
| `945813c8` | Wyniki A/B |
| `a582ffab` | Zakaz żywego VHD |
| `a8e68d1f` | Cache MFT |
| `09c3d019` | Cache indeksu i przygotowany insert |
| `ffd423fe` | Bufor zapisów |
| `5dda7b39` | Profiler |
| `53891772` | Hint i zegar PM |
| `62914c8f` | Integracja UEFI |
| `5d5941c2` | Integracja NTFS i bitmapy |
| `16eb5f45` | Trwałość końcowa i brak RTC |
| `6c828494` | Prywatny slot BIOS |
| `45d04b1d` | Integracja BIOS |
| `f7165378` | Limit wywołań celu |

Wszystkie zmiany źródłowe mają commity; brak wdrożenia. SHA binariów są w `docs/minios-evidence-1c4.json`; badany x64: `db81def8f3eec0bfbe6668d876cf15a753fd9750813109090d0f7ef076e66ccc`.

Jutro najpierw przegląd tego raportu. Następny sensowny krok po wznowieniu: rozdzielić narzut profilera od zmian IO (jeden kontrolowany test tego samego kodu bez częstych odczytów portu PM), a dopiero potem ponowić bramkę 900 s. W tym podejściu takiego przełącznika ani kolejnej VM nie dodawano. Obecnie **STOP / pauza użytkownika**.
