# RAPORT-W95RTM-FIRSTBOOT — zakończenie wznowienia 2026-10-26

**Wynik: faza1 instalatora RTM PL PASS; kompletny pierwszy pulpit RTM i OSR1 NIEZALICZONE. STOP na bramce natywnego firstboot.**

RTM ma zapisany, niezmienny wynik udanej fazy1. Przygotowanie sieci naprawiono i potwierdzono także w rzeczywistym przepływie. Ostatnia próba doszła do inicjalizacji Windows USER, lecz po3604,578s nie było pulpitu, końcowego restartu ani wykonania koordynatora potwierdzonego logiem. OSR1 EN ma fixture; nowej instalacji nie wykonano, zachowując priorytet RTM→OSR1. Akceptacja testów z23.10 pozostaje historyczna i nie zastępuje tego zadania.

## Przyczyna STOP i granica diagnozy

KOTWICA.md nakazuje: „Blokada > 1 godziny = przerwij i opisz w raporcie”. Wymagana bramka pierwszego pulpitu pozostała niezaliczona po godzinnej próbie native03 i wcześniejszych zamkniętych próbach. Kończymy podejście bez kolejnego startu VM. To STOP nieukończonego zadania, nie akceptacja pełnej instalacji. Własne QEMU0, rezerwa2 silników zwolniona; brak automatycznego wznowienia.

Nie ustalono przyczyny zatrzymania lub przewlekłości po inicjalizacji USER. BOOTLOG kończy się parą `Init = TSRQuery` / `InitDone = TSRQuery`; wcześniej zapisano inicjalizację Final USER i MSGSRV32.EXE. Limit nie dowodzi trwałego zawieszenia ani jego przyczyny. Ekran końcowy pozostaje czarny z artefaktami górnego wiersza. Nie przypisujemy tego GRPCONV, IE ani USOSFB: brak FIRSTBT.LOG/ERR/OK; poprawne polecenie `USOSGRPW.EXE -s` nadal jest kolejkowane w oryginalnym RunOnce\Setup.

## Build, instalator i migawki

- Sprawdzono oba wymagane dowiązania wejść na K: i przypięte SHA. Build05 uruchomiony bez przechwytującego stderr wrappera PowerShell wskazał brak ignorowanego Vista v11. Jedna poprawka: manifest i13 przypiętych plików na K: oraz dowiązanie. Jedyna powtórka, build06: PASS104/104,632/632,verify_release_consistency.
- Po zmianie generatora NFILES pełny build07: PASS104/104,632/632,verify_release_consistency, exit0. Polecenie przez cmd /d /c i build.bat, BelowNormal,2CPU/-j2. Build `B261026-121414-3132FCB5`, source SHA `3132fcb500045ed00dee9e2dc903f68847cae9b21d7c93cfe0efa2f9c48e56bb`, log SHA `d286253ef97b6a0c380239f252494187666726b5ba8a98b0649fb429b1793fc4`. Receipt `artifacts/firstboot/full-build07.result.json`; wcześniejsze receipt06 zachowane.
- Rzeczywisty Setup RTM PL: rc0/307s, pełny przepływ menu→gotowy cel343,91s. Zewnętrzne WHPX i wewnętrzny Setup QEMU, produkcyjny profil i kontroler stron. Poprzedni nieukończony TCG w TCG zatrzymał kopiowanie na3%; uzasadnienie zmiany etapu przed bazą zapisano przed ponowieniem. Zaliczonej fazy1 odtąd nie powtarzano.
- Baza `_vm/rtm-nvme-02/target.qcow2`, SHA `42711ac8e27a12bbfed337bc426df2ba84f511695bae3193f9eb506a1d2f0c09`. Zewnętrzna migawka/nakładka, prepared-snapshot.json i phase1-accepted.json. Checkpoint zastąpił ciepły start zimnym; nie zalicza sam firstboot.
- Native03 użył nowej nakładki tej bazy z wymienionym wyłącznie NFILES.BAT.12 chronionych plików, m.in. rejestry, SYSTEM.INI i helpery, ma identyczne SHA. Nie wstrzyknięto gotowych plików sieciowych ani markerów sukcesu. Receipt postphase1-netfiles-01/replacement.json. Zmiana po bazie nie wymagała reinstalacji.

## Poprawki i ich rzeczywiste dowody

| Zakres | Wynik i ograniczenie |
| --- | --- |
| DELKEY | Oryginalny REGEDIT950 odtwarzał atrybuty0x27 i blokował otwarcie ula do zapisu; hostowe kopie traciły atrybuty. DELKEY przed importem, przyczyny do logu, trwałe ERR po rollbacku. DOS/REGEDIT i testy hosta PASS; dwa pełne GUI nowej instalacji niepotwierdzone. |
| Watchdog GRPCONV | Limit120s i wyłącznie własny proces/potomny PROGMAN. Wymuszony hang120027ms, helper0. Oryginalny proces zakończył się po2576ms z1, helper0 — nie dowodzi to kompletnej konwersji nowych skrótów. Oryginalne nazwy PL/EN i podmiana DOS PASS; brak dowodu wykonania w native03. |
| Kolejność przed paskiem | USOSFB, USOSRES/setup, USOSADD/setup i wspólny końcowy restart: testy komponentowe PASS, w tym realny DCOM95 i własne kolejki DOS/myszy. Pełnego rzeczywistego zestawu dodatków nie zaliczono. |
| Pliki sieci950 |51 osobnych skanów CAB zastąpiono12 grupami do125B. Własny cache; kopiowane wyłącznie brakujące cele.38 testów hosta PASS. Cały oryginalny DOS/WHPX:51 brakujących plików PASS88,043s; kontrprzykład51 istniejących celów, w tym znacznik VREDIR: SHA zachowane, PASS15,864s. |
| Ten krok w native03 | NFILES.OK i NET95.OK, bez RUN/ERR. Wszystkie51 SHA zgodne z niezależną referencją oryginalnego DOS. NLATE.OK jeszcze brak. Pliki/import zaliczone; nie jest to test DHCP/HTTP ani całego Windows. |
| Narzędzia wejścia | Aktualny QEMU przypięty SHA, własny ROM:1,401s/85, nonce i ślad PS/2 klawiatura1/keycode1/mysz2. To kontrola narzędzia, nie test Windows. UTEST/M33 i adapter po instalacji przygotowane, bez wykonania w nowym gościu. |

## Zamknięte próby po fazie1

| Nakładka | Wynik |
| --- | --- |
| native01, NVMe, limit1200s | Za krótki limit testera przerwał ekstrakcje DOS przy rpcltc3.dll; bez GUI i NFILES.ERR. |
| native02, NVMe, limit3600s |3604,680s, nadal DOS przy ftp.exe, bez pulpitu. |
| native-ide01, limit3600s |3603,770s, nadal DOS przy vtcp.386. Nie dowodzi awarii Windows zależnej od NVMe; różne obciążenia wykluczają traktowanie tego jako benchmarku. |
| native03, NVMe, nowy skrypt |3604,578s; NFILES/NET95 zakończone, inicjalizacja USER/TSRQuery. Brak pulpitu i FIRSTBT.LOG/ERR/OK. QMP:0 RESET; końcowy SHUTDOWN to host-qmp-quit, nie samoczynne wyłączenie gościa. |

TCG,2CPU/2GiB, NVMe oraz VGA/XHCI/igb za mostkami, klawiatura USB i względna mysz. Po przekazaniu przygotowanego celu nie wysłano wejścia do Windows. Rc0 ostatniego procesu QEMU oznacza poprawne zakończenie procesu, nie sukces instalacji.

## Kryteria końcowe

| Wymaganie | RTM PL | OSR1 EN |
| --- | --- | --- |
| Nowy pełny build/payload | PASS06 i07 | wspólny build PASS; fixture z06 |
| Faza1 i baza | PASS307s, baza i nakładki | fixture PASS272,618s; Setup niewykonany |
| Zero-click do kompletnego pierwszego pulpitu | NIEZALICZONE | niewykonane |
| Dokładnie jeden końcowy restart po rzeczywistych dodatkach | niewykonany; tylko komponent PASS | niewykonany |
| Jeden adapter po dwóch GUI, brak PNP0900 | niepotwierdzone; legacy nadal jest przed późną fazą | niewykonane |
| Pulpit1920×1080 przed pokazaniem użytkownikowi | niepotwierdzone; rozmiar GOP nie jest dowodem trybu pulpitu | niewykonane |
| TZ/DST, IE i komplet dodatków |9 źródeł PL przygotowane; pełny etap niezaliczony | źródła/profil przygotowane; etap niewykonany |
| Mysz w oknie DOS | niewykonane w nowej instalacji | niewykonane |
| USB klawiatura/mysz/replug i pendrive | testy po instalacji niewykonane | niewykonane |
| DHCP i HTTP200 z68k.news | pliki/import NET95 PASS, runtime niewykonany | niewykonane |
| Finalny BOOTLOG bez fallbacku, bez Safe Mode/wyłączenia | pełny końcowy start niezaliczony | niewykonane |
| Restart i wyłączenie z Windows | niewykonane w nowym przepływie | niewykonane |
| NVMe i IDE porównawczo | uruchomione oba, GUI niezaliczone | niewykonane |
| Statyczne porównanie RunOnce OSR2/RTM | wykonane według decyzji użytkownika | ten sam warunek źródła950 |

## Gałąź, commity i zachowanie danych

Gałąź `codex/w95-firstboot`; baza `564a4eeea71a316f11e9d37aa91cf30637865d04`; worktree `C:\Users\ASRock\usos-work\codex-w95-firstboot`. Autor commitów snakex21 noreply, wszystkie lokalne. Chroniony w95-vesbind i MiniOS bez edycji; bez merge/push/deploy i fizycznych nośników.

Commity kodu: `32f90f3f` DELKEY; `273696f2` watchdog; `756ca823` USOSADD/setup; `ee9fd17d` -j2; `a6c1a9de` WS2; `b965188f` koordynator; `7e6eda4f` fingerprint; `02dea825` INF myszy. Wznowienie: `0906e026` podsumowanie buildu, `62a790ef` payload06, `fe043f52` baza fazy1, `34e27d19` tabela OSR2, `c65776a2` grupy CAB, `e158d733` payload07, `36d44c6b` dowody narzędzi.

Zachowano **119 obrazów/nośników/vars**, lista `docs/w95-firstboot-retained-images-resume-2026-10-26.json`. **Usunięto0**. Pomiar2026-10-26 14:38 Europe/Warsaw: pula **9,08/150GiB**, wolne K: **103,10GiB**, minimum100GiB. Własne QEMU0 potwierdzone po zakończeniu operacji, rezerwa2 zwolniona. Obrazy, rozpakowane kopie i surowe MS są na K:; surowych plików MS nie dodano do Git.

Native03 jest checkpointem diagnostycznym po przygotowaniu DOS, nie bazą zaliczonego pulpitu. Plik `K:\USOS-VM\W95RTM-FIRSTBOOT-20261025\_vm\rtm-nvme-02\native-03\target.qcow2`, SHA `4095b00ce136aa4ed75e6900905c5d4a91952b80d87f0182061080b6dc5ae1a6`; zachowane podkłady i vars. Audyt wyłącznie do odczytu, bez nowego raw. Czytnik zweryfikowano wobec istniejących niezależnych kopii qemu-img.

Dowody pod `_vm/rtm-nvme-02/native-03`: observation/result.json, endpoint.png, native-observer.json; offline/audit.json, BOOTLOG.TXT, startup-safe-commands.json, network-files-vs-dos-reference.json, stopped-image.json. Pozostałe próby i starsze raporty zachowane.

QEMU nie potwierdza X470.88s DOS/WHPX nie jest pomiarem CSMWrap/TCG; czasu samego przygotowania w tym ostatnim nie zmierzono. Nie stwierdzono nowej awarii IE: etap dodatków nie jest tu potwierdzony. Brak IE6 SP1 EN w ogólnym pakiecie nie został uznany za przyczynę obecnej blokady.

Dalsza praca tylko po nowym jawnym poleceniu. Pozostał etap pierwszego GUI po USER/TSRQuery, na nakładce zachowanego checkpointu; bez podstaw do ponawiania zaliczonego instalatora, komponentów ani przygotowania51 plików.

## Porównanie OSR2 i RTM — statycznie


Porównanie statyczne, zgodnie z decyzją użytkownika z 2026-10-26. Nie ma gotowego zainstalowanego obrazu OSR2/98; nie wykonano nowej instalacji ani testu tych zamkniętych systemów. Priorytet prób QEMU pozostaje RTM PL, następnie OSR1 EN. Określenie „przed paskiem” oznacza brak okna `Shell_TrayWnd`, a nie sam brak widocznego obrazu na ekranie.

| Etap | Produkcyjny OSR2 | RTM/OSR1, źródło `4 0 0 950`, ta gałąź |
| --- | --- | --- |
| Przygotowanie DOS, przed paskiem | `TZFIX`, `VESA95`, `USBREG`, `REG95`. Windows 95 OSR2 pomija `[Install] AddReg` w MSBATCH, więc wartości Run/RunOnce pochodzą z importu `REG95.REG`, a nie ze skutecznego wykonania sekcji INF. | Ten sam import bazowy; dodatkowo przygotowanie plików sieciowych oraz późne `TZDST`, `VESALATE`, `R95LATE`, `NET95LATE`, `VMDLATE`, strzeżone zakończeniem oryginalnego Setup. |
| Oryginalny `RunOnce\Setup`, przed ukończonym pulpitem | Oryginalne kroki Setup; bez nowego koordynatora950 i podmiany GRPCONV. Statyczna analiza naszych wpisów nie dowodzi dokładnej wewnętrznej kolejności `ClassSetup`/`InitShell`/`TapiSetup`. | Oryginalna lista pozostaje właścicielem tego etapu. Polecenie `grpconv.exe -s`, rozpoznane niezależnie od języka nazwy kroku, zastępuje watchdog120s. Nie dopisujemy własnej listy `RunOnce\Setup`: jej istnienie blokowałoby późne skrypty DOS. |
| Zwykłe HKLM `RunOnce` | `USOSVmd` instaluje własny INF myszy. Generator zawiera też `USOSWelcome`, lecz konwersja95 pomija polecenie z nierozwiązanymi LDID; zamiast niego ustawia `Explorer\Tips\Show=0`. Sam wpis w zwykłym RunOnce nie stanowi nowego pomiaru momentu pojawienia się paska w OSR2. | `USOSVmd` jest kolejkowany dopiero po Setup. `USOSFirstBoot` uruchamia `USOSFB.EXE`; koordynator odmawia pracy, jeśli pasek już istnieje lub Setup nie jest zakończony. Jeśli jego wpis poprzedzi późno dopisany `USOSVmd`, wykonuje wyłącznie znany własny INF i sprawdza `SYSTEM.INI`. |
| Ustawienie obrazu `USOSRES` | Rejestracja w HKLM `Run`. Program czeka na koniec Setup, ale wersja9x nie ma jawnego warunku oczekiwania na `Shell_TrayWnd`; z kodu nie można zagwarantować dokładnego momentu względem widocznego paska. W normalnej VM zachowuje żądanie, odraczając zastosowanie. | Koordynator wywołuje `/setup` przed paskiem, po `VLATE.OK`, `TZDST.OK`, pozostałych znacznikach i sprawdzeniu braku `*PNP0900`. Tryb wymaga źródła950, `PHASE1.OK` i `FIRSTBT.ON`; nie odracza ustawienia tylko z powodu VM. Sprawdza wynik `DISPLAY.DONE` przed dodatkami. |
| Dodatki `USOSADD` | HKLM `Run`, po pasku: normalne `setup_busy()` wymaga `Shell_TrayWnd` oraz zakończenia Setup. Dodatki mogą pracować na widocznym pulpicie; to nie jest przepływ950 z tej gałęzi. | Wywołanie `/setup` pomija czekanie na pasek, zachowując bramkę końca Setup. Koordynator czeka na koniec pakietów i przejmuje końcowy restart; podsumowanie wymagające klikania jest pominięte w tym trybie. |
| Ustawienia IE/sieci `USOSLAN` | HKLM `Run`, po pasku: zwykły tryb czeka na gotowość pulpitu i koniec Setup. W zwykłej VM odracza pracę. | Po końcowym restarcie, jeszcze przed zwolnieniem pierwszego pulpitu, koordynator wywołuje `/setup /refresh` i sprawdza kod wyjścia. Dopuszczenie VM wymaga potwierdzonego przekazania źródła950. Nie dowodzi to samo DHCP ani HTTP200. |
| Kolejność wartości HKLM `Run` | Generator umieszcza `USOSLog` najpierw, następnie pomocniki usuwające swoje wpisy, `USOSLan` na końcu. Usuwanie wpisu jest opóźnione, by nie przesunąć indeksu podczas enumeracji powłoki95. Nie wynika z tego szeregowe zakończenie wszystkich uruchomionych procesów. | Wpisy bazowe nadal istnieją, ale wykonanie wymaganych dodatków i obrazu przejmuje wcześniej koordynator. Samo uruchomienie loggera z `Run` nie jest dowodem zakończenia tych kroków. |
| Restart i zwolnienie pulpitu | Normalny mechanizm dodatków i wznowienia przez `Run`; brak nowej gwarancji jednego restartu przed pierwszym widocznym pulpitem. | Możliwy wcześniejszy restart przejścia Setup→późny DOS jest odrębny od dokładnie jednego końcowego restartu po dodatkach. Po tym końcowym restarcie: `VMDLATE.OK`, `USOSADD /setup /check`, `USOSLAN /setup /refresh`, zapis `FIRSTBT.OK`, dopiero wyjście koordynatora i zwolnienie pulpitu. Pełny wynik obu rzeczywistych instalacji musi potwierdzić tę ścieżkę. |

## Podstawa porównania

- Generowane INF: `src/flow/answer/msbatch.zig:160,201`, `addons_profile.zig:19`, `network_defaults.zig:57`; wpis ekranu `tools/display_profile.sh:94–101` i wpisy DOS `src/platform/bios/dos_startup.cmd:243–306`.
- Dlaczego INF nie wystarcza dla OSR2, pomijanie LDID i kolejność Run: `tools/w9x_reg95.sh:1–64,223–248`. Warunki950 dla późnych skryptów: ten sam plik, wiersze681–724. Jest to zapis produkcyjnej diagnozy X470 OSR2.1 z 2026-10-20, nie nowy pomiar QEMU.
- Włączenie koordynatora wyłącznie dla950: `tools/w9x_csmwrap_target.sh:658–662`, `tools/w9x_firstboot.sh:1–11`. Warunki przed paskiem, obsługa własnego INF myszy, znaczniki i restart: `src/platform/win32_legacy/usosfb.c:39–129`.
- Bramki programów: `tools/windows_usos_res.c:380–418`, `src/platform/win32_legacy/usosadd/main.c:556–570`, `tools/windows_usos_lan.c:397–427`.
- Historia X470 i OSR2: `docs/win9x-modern-2026-09-30.md:477–534`. Opisany tam QEMU smoke OSR2.1 z 2026-10-06 wymagał logowania, anulowania drukarki i zamknięcia Welcome; jest wcześniejszy od późniejszych poprawek. Nie stanowi dowodu obecnego zero-click ani pomiaru aktualnej kolejności RunOnce. KOTWICA odnotowuje zaakceptowaną rodzinę9x poza950 na X470; tego zakresu nie otwieramy.

## Granice wniosku

Statycznie rozstrzygnięto różnicę istotną dla zadania: zwykłe dodatki OSR2 wymagają gotowego paska, natomiast ścieżka950 ma wyraźną bramkę przed paskiem i wspólnego właściciela restartu. Nie przypisujemy gwarancji kolejności wpisom, których nasze programy jej nie sprawdzają. Dokładny moment `USOSRES` względem pojawienia się paska w OSR2 oraz wewnętrzna kolejność oryginalnych kroków Setup pozostają niezmierzone; nie blokują weryfikacji950. Nowa instalacja OSR2 jest dopuszczalna dopiero po PASS RTM PL i OSR1 EN, jeśli pozostanie konkretne pytanie potrzebne do rozstrzygnięcia zadania.


## Zmienione pliki względem bazy — 39

- `build.bat`
- `docs/w95-firstboot-2026-10-25.md`
- `docs/w95-firstboot-final-2026-10-26.md`
- `docs/w95-firstboot-network-staging-2026-10-26.md`
- `docs/w95-firstboot-osr2-static-2026-10-26.md`
- `docs/w95-firstboot-pause-2026-10-26.md`
- `docs/w95-firstboot-phase1-2026-10-26.md`
- `docs/w95-firstboot-result-resume-2026-10-26.md`
- `docs/w95-firstboot-retained-images-2026-10-26.json`
- `docs/w95-firstboot-retained-images-resume-2026-10-26.json`
- `docs/w95-firstboot-validation-harness-2026-10-26.md`
- `installer/cmd/usos-payload-pack/main.go`
- `installer/internal/payload/legacy_boot_generated.go`
- `src/addons/legacy-pack.ini`
- `src/platform/bios/dos_startup.cmd`
- `src/platform/bios/win9x/vesbind.c`
- `src/platform/win32_legacy/usosadd/main.c`
- `src/platform/win32_legacy/usosfb.c`
- `src/platform/win32_legacy/usosgrpw.c`
- `tools/build_micro_linux.py`
- `tools/build_usosfb.py`
- `tools/build_usosgrpw.py`
- `tools/build_win9x_support.py`
- `tools/generate_build_info.ps1`
- `tools/tests/golden/staged_payloads.tsv`
- `tools/tests/test_dos_native_payload_lists.py`
- `tools/tests/test_network_defaults.py`
- `tools/tests/test_w9x_firstboot.py`
- `tools/tests/test_w9x_net95_files.py`
- `tools/tests/test_w9x_tzfix.py`
- `tools/tests/test_w9x_vesbind.py`
- `tools/verify_release_consistency.ps1`
- `tools/w9x_csmwrap_target.sh`
- `tools/w9x_firstboot.sh`
- `tools/w9x_reg95.sh`
- `tools/w9x_tzfix.sh`
- `tools/w9x_vesa95.sh`
- `tools/windows_usos_lan.c`
- `tools/windows_usos_res.c`
