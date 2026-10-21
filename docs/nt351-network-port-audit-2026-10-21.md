# NT 3.51: audyt oddzielnego wariantu usosnet

2026-10-21. Nie uruchomiono QEMU ani sterownika pod Windows. Nie zmieniono wariantów NT4/95. Nie utworzono eksperymentalnej binarki: pozostał nierozstrzygnięty kontrakt zamykania timera, opisany poniżej.

## Oryginalny nośnik i metoda

Audyt dotyczy wyłącznie NT 3.51 Workstation z planu R15. Archiwum SHA-256 `24adda13744589cacebf6a75e21bf8999465b5637235ce55b0cf3a7578aa7975`, ISO `b9d0e8417c1f502d1de22c249401b593be2a7fe59524b27a624dfa8dedaa099c`. Oba hashe ponownie sprawdzono przed pomiarem.

`tools/tests/audit_nt351_ndis_exports.py` używa istniejącego parsera oryginalnych mediów, pefile i Capstone. ISO i krótkotrwałe skompresowane wejścia CAB/SZDD są pod `G:\USOS-Kolekcja\_audit\nt351-ndis-exports`; TemporaryDirectory usuwa je po pomiarze. Rozwinięte pliki Microsoft są wyłącznie w RAM. Wyniki zawierają nazwy, hashe, RVA i tekst ograniczonych fragmentów instrukcji; bez surowych bajtów MS. Nie są dowodem wykonania ani pełnym grafem sterowania.

Dokładne wyniki lokalne: `artifacts/nt351-network-audit/original-metadata.json`, `timer-metadata.json`, `halt-metadata.json`; wszystkie potwierdzają usunięcie tymczasowego ISO. Kolejne pomiary dodają nowe cele: wrapper DPC, oryginalny MiniportHalt DC21X4 i jego wywoływane funkcje, a nie postęp jakiejkolwiek VM.

## Ustalone ABI rejestracji i odbioru

| Oryginalny moduł | SHA-256 | Dowód |
|---|---|---|
| NDIS.SYS | `948d3c6feee3f80b98da5b40a254f7047b044a0bcc9be23739a460d7cfc5ab1b` | Eksporty i implementacje API. |
| NE2000.SYS | `4d0bd9c3e47d9ccdee5fcf7f8a1c67cb47a62c8a898edc499e3a3baed9885112` | Receive i Complete używają handle+0xD8; rejestracja 0x3C, major 3. |
| ELNK3.SYS | `37a65b25846ff837ec4bde55f92cb5c5cbca3e27f2e8afee6cba63da2ff4d426` | Niezależne potwierdzenie +0xD8 i 0x3C. |
| DC21X4.SYS | `c301eaf6a9fac68f851d5f6b084b27a8dd1eef78dc5a78e21955713459ced423` | Major 3/minor 0, 0x3C; +0xD8; rzeczywiste użycie one-shot API. |

RVA są względem odpowiedniego obrazu, nie adresami fizycznymi. Istotne przykłady:

- NE2000 RVA `0x18e3`–`0x18e6`: przekazuje kontekst ESI oraz `[esi]` jako MiniportAdapterHandle do `NdisMSetAttributes`. Przy odbiorze `0xbb5` ładuje ten handle z `[esi]`, `0xbbc` przekazuje `[eax+0xd8]` do `EthFilterDprIndicateReceive` (`0xbc2`); Complete robi to samo w `0x81a`–`0x822`.
- ELNK3 RVA `0x260b`–`0x2612`: kontekst ESI, handle `[esi+0xf8]` do SetAttributes; receive `0x899`/`0x8a8`/`0x8ae` i Complete `0x98b`/`0x991`/`0x997` używają tego handle i pola +0xD8.
- DC21X4 RVA `0x3287` zapisuje major 3, `0x328b` minor 0, `0x32d5` przekazuje rozmiar 0x3C; `0x32f3` wywołuje `NdisMRegisterMiniport`. Receive `0x134b`/`0x1352`/`0x1358`, Complete `0x13ed`/`0x13ef`/`0x13f5` potwierdzają +0xD8.

To jest dowód z dokładnego oryginalnego nośnika, mocniejszy niż samo wystąpienie symbolu lub współczesny nagłówek. Nie przenosi się go automatycznie na NT 3.5/3.1 ani wszystkie Service Packi. Publiczny [nagłówek ReactOS](https://raw.githubusercontent.com/reactos/reactos/master/sdk/include/ddk/ndis.h) zawiera NDIS30 prefix: dwa bajty wersji, wyrównany Reserved i 13 wskaźników callbacków, co na i386 daje 0x3C; to niezależna kontrola struktury, nie zastępstwo dowodu z NT3.51.

## Dwa brakujące API i rzeczywiste użycie

`usosnet.c:672` przekazuje do `NdisMSetAttributesEx` tylko CheckForHang=0, BUS_MASTER i PCI. Oryginalne NT351 eksportuje `NdisMSetAttributes`; jego RVA `0x8e7f`–`0x8ea3` pobiera cztery argumenty, zapisuje context w handle+0xC, BusMaster w +0x110 i typ magistrali w +0x10C, wraca `ret 0x10`. Kandydat odrębnego wariantu powinien jawnie importować tę funkcję z TRUE/Pci. Trzeba ominąć makro z nowszego ndis.h, które rozwija SetAttributes ponownie do brakującego Ex. Bieżący wariant nie wymaga pozostałych rozszerzonych flag; [Microsoft opisuje różnicę atrybutów i timeoutu](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ndis/nf-ndis-ndismsetattributesex).

W NT351 są `NdisSetTimer`, `NdisMInitializeTimer` i `NdisMCancelTimer`; **nie ma** `NdisMSetTimer`, `NdisMSetPeriodicTimer` ani `NdisMIndicateReceivePacket`. DC21X4 w RVA `0x4687` inicjalizuje miniport timer pod kontekst+0x58, a `0x46a2` uzbraja ten sam obiekt przez `NdisSetTimer`. Można więc oprzeć przyszły wariant na rzeczywistym eksporcie i NDIS-owym obiekcie, bez własnej kopii KeTimer layoutu.

Aktualny usosnet inicjalizuje jeden timer (`:825`), ustawia go okresowo (`:827`), wykonuje RX/TX i diagnostykę w `TimerFn` (`:502`), anuluje w `MpHalt` (`:861`) i `FreeAll` (`:326`). [Microsoft rozróżnia one-shot od timera okresowego](https://learn.microsoft.com/en-us/previous-versions/windows/hardware/network/ff553635(v=vs.85)): każde kolejne wywołanie wymaga nowego uzbrojenia. Samo przekierowanie nazwy nie zachowuje okresowego działania. Zliczane sekundy/watchdog także wymagają świadomego rozstrzygnięcia dryfu po one-shot rearm.

## Nierozstrzygnięty kontrakt zamykania

Oryginalny `NdisMCancelTimer`, RVA `0x894a`–`0x895a`, wywołuje KeCancelTimer i zapisuje jego bool. Nie czeka na opróżnienie DPC. [Opis cancel](https://learn.microsoft.com/en-us/previous-versions/ms958802(v=msdn.10)) rozróżnia timer anulowany od takiego, który już wygasł. Sam licznik rozpoczętych callbacków nie obejmuje DPC czekającego w kolejce.

Wrapper DPC zarejestrowany przez `NdisMInitializeTimer` jest w RVA `0x59c0`. Ładuje miniport z Timer+0x50, bierze lock miniportu (+0x30), a `0x59d6`/`0x59dd` sprawdza miniport+0x4A3 i może od razu przejść do zwolnienia locka (`0x5a18`) bez callbacku. Sprawdza też +0x2E i +0x3F; inne gałęzie odraczają pracę. Callback jest wywoływany w `0x5a00` z Timer+0x48 i kontekstem +0x4C. Semantyka tych flag i ich związek z Halt nie zostały jeszcze w pełni udowodnione. Nie wolno zakładać, że każdy nieskasowany timer na pewno wejdzie do callbacku i odda referencję podczas Halt.

Spinlock API (również DprAcquire/Release) jest eksportowane. NDIS351 nie eksportuje Initialize/Set/Reset/WaitEvent ani ScheduleWorkItem. Proponowany mechanizm wymaga referencji przypisanej przed **każdym** uzbrojeniem, zsynchronizowanego stop/rearm gate i oczekiwania na oddanie referencji przez callback lub udane anulowanie. Do jego poprawności nadal trzeba wykazać: zachowanie odroczonego/pominiętego DPC podczas Halt, właściwy IRQL Halt i dostępne oczekiwanie o zgodnym ABI, które nie zakleszczy ścieżki NDIS. Obiekt event z późniejszego WDK nie może być uznany za zgodny tylko na podstawie nazwy typu.

Przed budową wariantu potrzebny jest ten ostatni dowód albo inny kompletny mechanizm życia timera. Znaczące testy powinny objąć cancel TRUE, cancel FALSE przy DPC jeszcze w kolejce, Halt podczas callbacku, rearm ścigający się ze stop oraz pełne opróżnienie referencji. Dopiero później: osobny build NT351 z major/minor 3.0, rozmiarem 0x3C, ABI assertions i importami przeciw dokładnym NDIS/NTOS/HAL z tego ISO; stare NT4/95 binarki i zachowanie pozostają niezmienione. Nawet taki build nie oznacza DHCP/ping/DNS PASS bez normalnego NT351 runtime.

Ostatnia kontrola: rejestracja DC21X4 w RVA `0x32a4` ustawia Halt na VA `0x11972` (RVA `0x1972`). Ta funkcja wywołuje `0xf7e` (zatrzymanie układu i `KeStallExecutionProcessor(2000)`), `0x3132` (zwalnianie buforów/DMA), następnie NdisMDeregisterInterrupt (`0x1987`), NdisMDeregisterIoPortRange (`0x19a1`), NdisMFreeMapRegisters (`0x19a9`) i NdisFreeMemory (`0x19b7`). W prześledzonych funkcjach nie ma anulowania timera ani oczekiwania na oddanie referencji. Osobny shutdown handler RVA `0x19c1`, zarejestrowany przez `0x4668`–`0x4671`, anuluje timer kontekst+0x58 w `0x19d2`. Timer callback RVA `0x1654` może ponownie uzbroić ten sam timer w `0x186f`–`0x1878` na 2000 ms. Nie wykazano, że shutdown handler zawsze poprzedza Halt, ani że NDIS sam opróżnia te DPC przed zwolnieniem kontekstu. Krótki stall sprzętowy nie jest dowodem takiej bariery. Nie skopiowano tego schematu do usosnet.

Wniosek audytu: **receive i rejestracja mają teraz konkretny dowód NT351; bezpieczny teardown timera nadal nie ma pełnego dowodu.** Audyt kończy się bez implementacji i bez eksperymentalnego worktree/binary. Ustalenie brakującego kontraktu lub zaprojektowanie sprawdzonego mechanizmu z dostępnym oczekiwaniem pozostaje osobnym zadaniem, przed jakimkolwiek runtime.
