<!-- Copyright (C) 2026 Maksymilian and the USOS Authors
SPDX-License-Identifier: GPL-3.0-or-later
-->
# USOSPKT.COM — tryb kolejkowy dla klienta w trybie chronionym (etap 2a)

Data: 2026-10-23. Gałąź: `ds/usospkt-queue` (worktree `<local-worktree-or-evidence>`,
baza `ds/winsock16`). Zmiana dotyczy wyłącznie strony sterownika:
`src/platform/bios/msdos/usospkt.S`. Strona DLL (`winsock16.c`) należy do innego workera i nie
została tknięta.

## Po co drugi tryb

`USOSPKT.COM` to nasz packet driver (FTP Software Packet Driver Specification 1.11, class 1 DIX
Ethernet) dla I211/I210/82576. Do tej pory miał jedno wejście: `INT 60h`, a ramki odbierał
upcallem (far call do klienta z kontekstu ISR). DLL Windows 3.1 działająca w trybie chronionym
nie może przyjąć takiego upcallu, więc doszedł **drugi, niezależny tryb**: pierścień ramek w
pamięci DOS, który klient **odpytuje** (polling). Klient nie dostaje żadnego przerwania.

## Co dodano w `usospkt.S`

Nowa sekcja „queue mode” (rezydentna) plus zmiany w istniejących ścieżkach:

| symbol | rola |
|---|---|
| `int2f` | handler `INT 2Fh`; `AX=5553h` („US”) nasz, wszystko inne → `JMPFAR old2f` (poprzedni handler, rejestry nietknięte) |
| `q_query`, `q_attach`, `q_state`, `q_kick`, `q_free` | podfunkcje multipleksu |
| `q_rx_frame` | dopisanie ramki do pierścienia RX (bez DOS-u, także z ISR) |
| `q_tx_kick` | wysyłka slotów TX kolejki w kontekście `INT 2Fh` |
| `q_log` | zapis do tekstowego pierścienia logu (bez `INT 21h`) |
| `rx_dispatch` | nowy rozgałęziacz w `rx_poll`: klient podłączony → kolejka, inaczej `deliver` (upcall) |
| `tx_frame` | wydzielone z `f_send` ciało wysyłki (kopiowanie do `A_TXBUF`, descriptor, czekanie na DD); używane przez `f_send` i `q_tx_kick` |

Zmiany w istniejącym kodzie:

* `f_send` (INT 60h, AH=04h) woła teraz `tx_frame` — zachowanie bez zmian (te same kody błędów,
  te same liczniki `st_pout`/`st_bout`/`st_eout`, ten sam descriptor i to samo czekanie na DD);
* `rx_poll` woła `rx_dispatch` zamiast `deliver`, a przy ramce odrzuconej (CRC/SEO/brak EOP/za
  krótka) inkrementuje dodatkowo `rx_errors` w bloku, gdy kolejka istnieje;
* init: **tylko z `/Q`** po bloku DMA powstaje blok kolejki (własny segment, 16-bajtowo
  wyrównany), zerowany i wypełniany nagłówkiem, a wektor `INT 2Fh` jest zapisywany (razem z
  `INT 08h` i IRQ); rozmiar rezydentny liczy się wtedy do końca bloku kolejki. Bez `/Q` blok
  nie powstaje, `INT 2Fh` nie jest dotykany, a rozmiar liczy się ze starego wzoru
  (`area + AREA_SIZE`, bez `Q_SIZE`);
* argumenty: `/Q` (albo `-Q`, wielkość liter dowolna — jak `/P`, `/M`, `/S`) ustawia `opt_q`;
  reszta ogona polecenia parsowana jak dotąd, nieznane opcje nadal kończą się `arg_bad`.

**Bez `ATTACH` wszystko działa jak dotąd** — bit `QF_SUPPRESS` nie jest ustawiony, więc ramki
idą upcallem, a `INT 60h` obsługuje mTCP bez żadnej zmiany semantyki.

## Włączanie: przełącznik `/Q` (tryb opcjonalny)

Tryb kolejkowy jest **domyślnie wyłączony**. Bez `/Q` sterownik jest pakietowym driverem jak
przed zmianą: hookuje tylko `INT 08h` (i ewentualnie IRQ karty) oraz wektor packet drivera
(`INT 60h`), nie alokuje bloku kolejki i nie dotyka `INT 2Fh`. `NETSTART.BAT` pozostaje bez zmian
— `/Q` włączymy później tylko dla sesji Windows 3.1/WfW:

```
USOSPKT.COM            ; mTCP, DOS: same upcalls, ~pamięć jak dotąd
USOSPKT.COM 60 /Q      ; + kolejka dla DLL w trybie chronionym
```

| | bez `/Q` | z `/Q` |
|---|---|---|
| pamięć rezydentna | **44 544 B** (2 784 akapity): obraz + blok DMA 34 816 B | **84 256 B** (5 266 akapitów): + blok kolejki 39 712 B |
| wektory | `INT 08h`, IRQ karty, `INT 60h` | jak obok **+ `INT 2Fh`** (łańcuch do poprzedniego handlera) |
| `INT 2Fh AX=5553h` | nieobsługiwane — przechodzi do poprzedniego handlera | `FFFFh/1/2/3/4` obsługiwane |
| RX | upcall (far call do klienta z ISR) | po `ATTACH`: kopiowanie do pierścienia RX, bez upcalli |
| TX | `INT 60h` AH=04h | dodatkowo `TX_KICK` (`BX=3`) z slotów TX |
| banner/raport | tekst instalatora bez zmian | dodatkowa linia `Queue block: seg:0000, size 9B20` + wpis `QUEUE ON` w pierścieniu logu |
| błąd braku pamięci | kod 6 (jak dotąd) | kod 6, gdy blok kolejki się nie mieści |

Wartość 44 544 B to rozmiar, który gałąź raportuje dziś (przed trybem kolejkowym było
43 264 B — kod nowych, nieaktywnych ścieżek to +1 280 B, czyli 10 akapitów wyrównania DMA).
Testy pilnują obu liczb jednocześnie, żeby przyszła zmiana nie powiększyła po cichu wariantu
domyślnego.

## Układ bloku współdzielonego

Blok leży w **własnym segmencie** (`qseg`), bezpośrednio za blokiem DMA (`area`), 16-bajtowo
wyrównany i fizycznie ciągły — dzięki temu offsety wewnątrz bloku nie przekraczają 64 KiB
(blok DMA + pierścienie w jednym segmencie dałyby > 60 KiB i przekroczyły limit `.COM`).
Adres publikowany klientowi: `ES:DI = qseg:0000`. Blok jest alokowany raz, przy instalacji,
w pamięci przydzielonej programowi przez DOS (sprawdzane względem `PSP:0002`).

Nagłówek (`Q_HDR` = 128 B):

| offset | rozmiar | pole |
|---|---|---|
| 0x0000 | 4 | magic `'USQ1'` (`0x31515355`) |
| 0x0004 | 2 | wersja API, `0x0100` |
| 0x0006 | 2 | rozmiar nagłówka, 128 |
| 0x0008 | 2 | flags: bit0 = `QF_READY` (sterownik gotowy), bit1 = `QF_ATTACH`, bit2 = `QF_SUPPRESS` (bez upcalli) |
| 0x000A | 2 | zarezerwowane |
| 0x000C | 2 | `rx_head` — pisze sterownik, następny slot do zapisu |
| 0x000E | 2 | `rx_tail` — pisze klient, następny slot do odczytu |
| 0x0010 | 2 | liczba slotów RX (16) |
| 0x0012 | 2 | stride RX (2056) |
| 0x0014 | 4 | offset pierścienia RX w bloku (0x0080) |
| 0x0018 | 2 | `tx_head` — pisze klient, następny slot do wypełnienia |
| 0x001A | 2 | `tx_tail` — pisze sterownik, następny slot do wysłania |
| 0x001C | 2 | liczba slotów TX (4) |
| 0x001E | 2 | stride TX (1544) |
| 0x0020 | 4 | offset pierścienia TX w bloku (0x8100) |
| 0x0024 | 4 | `rx_dropped` — ramki odrzucone, bo pierścień pełny |
| 0x0028 | 4 | `tx_busy` — nieudane `TX_KICK` (timeout/błąd) |
| 0x002C | 4 | `tx_done` — ramki wysłane z kolejki |
| 0x0030 | 4 | `rx_errors` — ramki błędne (CRC/SEO/brak EOP/za krótka) |
| 0x0034 | 4 | `tx_errors` — błędy wysyłki (timeout, zła długość) |
| 0x0038 | 2 | `log_head` — pisze sterownik |
| 0x003A | 2 | `log_tail` — pisze klient |
| 0x003C | 2 | rozmiar pierścienia logu (512) |
| 0x003E | 4 | offset pierścienia logu w bloku (0x9920) |
| 0x0042 | 4 | `log_dropped` — wpisy pominięte, bo log pełny |
| 0x0046 | 1 | wektor packet drivera (`INT 60h` domyślnie), informacyjnie |
| 0x0048 | 6 | MAC karty (informacyjnie) |
| 0x004E | 2 | `seq` — licznik ramek RX (rośnie, zawija się) |
| 0x0080 | 32 896 | pierścień RX: 16 × (8 B nagłówka + 2048 B) |
| 0x8100 | 6 176 | pierścień TX: 4 × (8 B nagłówka + 1536 B) |
| 0x9920 | 512 | pierścień logu tekstowego |
| **razem** | **39 712 B** | `Q_SIZE` (`0x9B20`) |

Slot RX (`0x0080 + i*2056`): `+0` len (word), `+2` flags (bit0 = ramka kompletna), `+4` seq
(word), `+6` zarezerwowane, `+8..+2055` ramka. Slot TX (`0x8100 + i*1544`): `+0` len, `+2` flags,
`+4` seq, `+8..+1543` ramka.

Protokół: każdy wskaźnik ma jednego pisarza (`rx_head`/`tx_tail`/`log_head` = sterownik,
`rx_tail`/`tx_head`/`log_tail` = klient), więc nie potrzeba blokad. Pierścień RX mieści 15 ramek
naraz — 16. slot jest odstępem rozróżniającym pełny od pustego (tak jak w sprzętowym pierścieniu
RDT/TDT); 16. ramka bez miejsca trafia w `rx_dropped`. `GET_STATE` zwraca `(head - tail) & 15`.

## Multipleks `INT 2Fh` — podfunkcje

Wejście: `AX=5553h` („US”), `BX` = podfunkcja. Wyjścia w nawiasach to wartości zwracane.

| BX | wejście | wyjście |
|---|---|---|
| `0xFFFF` | — | `AL=0xFF` obecny, `ES:DI` = blok, `CX=0x0100` (wersja API), `DX` = flags (bit0 ready, bit1 attached, bit2 suppress); `AL=0` gdy brak bloku |
| `0x0001` | — (ATTACH/PUBLISH) | `AL=0` ok + `ES:DI` = blok + `CX=0x0100` + `DX` = flags; `AL=1` brak sterownika; `AL=2` już zajęty. Ustawia `QF_ATTACH`+`QF_SUPPRESS`, zeruje wskaźniki obu pierścieni, loguje `ATTACH` |
| `0x0002` | — (GET_STATE) | `AL=0`, `ES:DI` = blok, `CX` = ramki czekające w RX, `DX` = sloty czekające w TX; liczniki błędów w nagłówku. Nie zmienia stanu |
| `0x0003` | — (TX_KICK) | `AL=0` wysłano wszystko, `AL=1` nic nie czeka, `AL=2` brak klienta, `AL=3` błąd wysyłki (slot porzucony, `tx_errors`/`tx_busy` rosną, log `TX ERR`) |
| `0x0004` | — (RELEASE) | `AL=0` wróciliśmy do upcalli (`QF_ATTACH`/`QF_SUPPRESS` wyczyszczone, zaległe ramki porzucone), `AL=1` nic nie było podłączone |
| inne BX | — | przekazanie do poprzedniego handlera `INT 2Fh` (rejestry bez zmian) |
| inne AX | — | przekazanie do poprzedniego handlera `INT 2Fh` |

`TX_KICK` wysyła **synchronicznie w kontekście przerwania 2Fh** (bez kolejek w ISR): dla każdego
slotu kopiuje ramkę do `A_TXBUF`, ustawia descriptor, czeka na DD i dopiero potem przechodzi do
następnego slotu; po każdym slocie `tx_tail` rośnie. Pierwszy błąd przerywa pętlę (`AL=3`).

## ISR RX

`rx_poll` (IRQ i timer `INT 08h`) woła `rx_dispatch`. Gdy `qseg != 0` i ustawiony `QF_ATTACH`,
ramka jest kopiowana do następnego wolnego slotu RX, liczona w `stats` (`st_pin`/`st_bin`),
`rx_head` rośnie; **żadnego upcallu**. Gdy pierścień pełny → `rx_dropped++` i wpis `RXQ FULL` w
logu. Gdy klienta nie ma — dotychczasowa ścieżka `deliver` (upcall) bez zmian.

## Rozmiar COM, rozmiar rezydentny

* `USOSPKT.COM`: **9 436 B**, SHA-256
  `b7ece027762c7413def6e3b050b13726874c757302d6e0e0768993c1888d5b48`
  (przed trybem kolejkowym 8 157 B — kod obu ścieżek; limit `check_usospkt` 4–16 KiB zachowany).
* Zbudowane `zig cc`/`ld.lld`/`objcopy` z `tools/build_dos_network.py` (`build_usospkt`) — w tym
  worktree nie ma `tools/zig` (toolchain nie jest śledzony w gicie), więc użyto
  `<local-worktree-or-evidence>` przez `USOS_ZIG`
  oraz cache `...\tools\cache\zig-global` przez `USOS_ZIG_CACHE`.
* Pamięć rezydentna (z `/Q`): **5 266 akapitów = 84 256 B (~82,3 KiB)**; bez `/Q`:
  **2 784 akapity = 44 544 B (~43,5 KiB)** — dokładnie jak dotąd (obraz + blok DMA).
  Różnica to `Q_SIZE` = 39 712 B (oba warianty są akapitowo wyrównane, więc nic ponad blok).
  Uzasadnienie rozmiaru bloku: kontrakt wymaga 16 buforów RX po 2048 B (32 896 B z
  nagłówkami), 4 slotów TX po 1536 B (6 176 B), 512 B logu i 128 B nagłówka — razem 39 712 B.
  Sprzętowy pierścień DMA (34 816 B) został nietknięty, żeby mTCP działał bez zmian; wersja
  „zero-copy” (oddawanie buforów sprzętowych klientowi) odrzucona jako zbyt ryzykowna dla
  istniejącej ścieżki upcalli. Po zmianie zostaje ~558 KiB pamięci konwencjonalnej.
  Gdyby DOS nie miał miejsca, instalacja kończy się kodem 6 i nic nie zostaje w pamięci.

## Testy

`tools/tests/legacy_bios/test_usospkt_queue.py` (nowy plik, 21 testów) + istniejący
`tools/tests/legacy_bios/test_usospkt.py` (bez zmian, regresja): **34 passed**.

Warstwa (a) — kontrakt źródłowy:
* `test_multiplex_and_subfunctions` — `AX=5553h`, `BX=0xFFFF/1/2/3/4` → właściwe etykiety,
  `JMPFAR old2f` dla reszty;
* `test_block_constants` — magic `USQ1`, 2048/1536/4/512, `Q_SIZE = 39 712`, wersja `0x0100`,
  układ `RXBUF`/`TXBUF`;
* `test_upcalls_switch_off_on_attach` — `QF_ATTACH + QF_SUPPRESS` w ATTACH/RELEASE, RX przez
  `rx_dispatch`, brak bezpośredniego `call deliver`;
* `test_isr_never_calls_dos` — w `q_rx_frame` i `q_log` nie ma `int 0x21/0x10/0x2F`;
* `test_packet_driver_entry_unchanged` — wszystkie dotychczasowe `AH` `INT 60h` (`1,2,3,4,5,6,7,
  20,21,24,25`), `"PKT DRVR"` za 3-bajtowym `JMP`, `check_usospkt`;
* `test_dma_area_layout_kept` — `A_TXRING/A_TXBUF/A_RXBUF/AREA_SIZE` bez zmian;
* `test_queue_mode_is_opt_in` — parsowanie `/Q` (`-Q`, dowolna wielkość liter), blok tylko za
  `cmp byte ptr [opt_q], 0 / je no_q_block`, hook `INT 2Fh` tylko między tym testem a
  `hook_done:` (jedyne wystąpienie `offset int2f` w instalatorze), wzór rozmiaru bez `/Q`
  (`area + AREA_SIZE`).

Warstwa (b) — zbudowany sterownik w Unicorn (16-bit, emulowany rejestr igb za IOADDR/IODATA):
`test_installed_block`, `test_query`, `test_attach_once_and_release`, `test_state`,
`test_rx_goes_to_the_ring_not_the_upcall`, `test_rx_ring_full_drops`,
`test_rx_errors_counted_for_the_client`, `test_tx_kick`, `test_tx_kick_timeout`,
`test_release_returns_to_upcalls`, `test_other_multiplex_passed_on`,
`test_queue_block_inside_the_resident_size`, `test_without_q_multiplex_reports_absent`
(bez `/Q`: `INT 2Fh 5553h` → `AL=0`, `ATTACH` → `AL=1`, a upcalls i `INT 60h` działają jak
przed zmianą).

Regresja rozmiarów: klasa `ResidentSize` liczy oba warianty z symboli zbudowanego obrazu w
jednym przebiegu — `test_without_q_is_the_old_size` (44 544 B = 2 784 akapity),
`test_with_q_adds_exactly_the_block` (84 256 B, różnica == `Q_SIZE`), `test_both_sizes_in_one_run`.

Uwaga: pytest wypisuje na stderr ostrzeżenie `Windows fatal exception: access violation` z
`unicorn.mem_map` — występuje także przy niezmienionym `test_usospkt.py` (Python 3.13 +
unicorn), nie pochodzi z tej zmiany i nie wpływa na wynik (wszystkie testy przechodzą).

## Czego nie sprawdzono

* **Brak smoke-testu w QEMU z prawdziwym DOS-em.** W tym worktree nie ma `tools/qemu` ani
  `tools/vendor/freedos` (katalogi nietrzymane w gicie), a `zig-out` nie zawiera gotowego obrazu
  MS-DOS 6.22; złożenie bootowalnego obrazu + klienta DOS (`INT 2Fh 5553h/FFFF`, `GET_STATE`,
  zrzut bloku na `C:`) przekraczało pozostały budżet. Warstwa (b) w Unicorn pokrywa logikę
  multipleksu, pierścieni i TX/RX, ale **nie** pokrywa: instalacji na prawdziwym sprzęcie
  (alokacja bloku względem `PSP:0002`, hook `INT 2Fh` w DOS), zachowania pod EMM386 (V86, VDS)
  ani współistnienia z innym rezydentem na `INT 2Fh`;
* strona DLL (`winsock16.c`) — inny worker; nie testowano żadnego realnego klienta Windows 3.1;
* mTCP po tej zmianie nie był uruchamiany w QEMU (ścieżka `INT 60h` jest regresyjnie pokryta
  testami w Unicorn i niezmieniona poza wydzieleniem `tx_frame`);
* wydajność (polling 16 slotów, kopiowanie 2048 B w ISR) — nie mierzona;
* `netstart`/instalator nie były uruchamiane (zmiana nie dotyka `build_dos_network.py` ani plików
  instalatora).
