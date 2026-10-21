# NT 3.51: audyt oddzielnego wariantu usosnet

2026-10-21. Nie uruchomiono QEMU ani sterownika pod Windows. Pierwszy checkpoint zakończył się bez implementacji z powodu nierozstrzygniętego zamykania prywatnego timera. Późniejszy dowód z oryginalnego CheckForHang pozwolił zbudować osobny eksperymentalny `usosnet351.sys` bez tego timera; aktualny stan jest na końcu dokumentu. Warianty NT4/95 zachowują dotychczasowe działanie.

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

Wniosek pierwszego checkpointu: receive i rejestracja mają konkretny dowód NT351; teardown prywatnego timera nadal nie ma pełnego dowodu. Nie wdrożono wariantu one-shot rearm. Poniższy wariant usuwa potrzebę takiego timera.

## Oryginalny checker, cykl i serializacja

Nowe pomiary z tego samego hash-verified ISO: `nt3-usb-tests/artifacts/nt351-network-audit/register-cfg.json`, `halt-wrapper.json`, `checker-routine.json` oraz `checker-initialization.json`. Zapis `checker-cfg.json` z wejściem 0x980 był wyłącznie oknem poszukiwawczym i nie jest dowodem CFG: ten adres leży wewnątrz instrukcji. Prawidłowe wejście to 0x98E, a jego direct-branch CFG nie został ucięty.

- `NdisMRegisterMiniport` RVA 0x179D sprawdza wersję 3.0 i minimum 0x3C B, następnie kopiuje dokładnie 0x3C B do driverblock+0x18 (0x180A–0x181A). CheckForHang z charakterystyk+8 trafia więc do driverblock+0x20, a Halt z +0x14 do driverblock+0x2C.
- Inicjalizacja RVA 0x9CB4–0x9CC9 przekazuje miniport jako kontekst, callback VA 0x1098E (RVA 0x98E) i obiekt miniport+0x90 do oryginalnego eksportu `NdisInitializeTimer` (RVA 0x19EB).
- Checker 0x98E bierze miniport lock+0x30 (0x9A1–0x9A6), sprawdza closing+0x4A3 i busy+0x2E. Ustawia busy=1 w 0x9C5, pobiera driverblock+0x20 i wywołuje callback z miniport context+0xC w 0x9D8–0x9DB. W tym miejscu lock pozostaje zajęty. Zwolnienie busy jest w 0xA26. Ścieżka końcowa przekazuje 2000 ms i miniport+0x90 do `NdisSetTimer` (0xA2A–0xA36), następnie oddaje lock w 0xA3D. Również busy-path pomija callback i przechodzi do ponownego uzbrojenia.
- Oryginalny wrapper Halt 0x873C podnosi IRQL do 2, bierze ten sam lock+0x30 i czeka na busy=0 (0x8758–0x8794). Ustawia busy=1 w 0x879C przed oddaniem locka, anulowaniem wewnętrznego timera+0x90 (0x87B0–0x87B7) i wywołaniem Halt przez driverblock+0x2C (0x87D9). Callback miniportu nie może rozpocząć pracy równolegle z tym Halt. Prywatne timery miniportu nie są w tej ścieżce dowiedzioną listą opróżnianych DPC; nie dodano ich do wariantu.

Ten pomiar dotyczy dokładnego NDIS.SYS o SHA-256 podanym wyżej. Późniejszy [opis Microsoft MiniportCheckForHang](https://learn.microsoft.com/en-us/previous-versions/windows/hardware/network/ff549367(v=vs.85)) jest kontrolą znaczenia callbacku; sam nie stanowi dowodu NT351. Nie wykorzystano Doors ani wycieków kodu.

## Wariant eksperymentalny i wykonane testy hostowe

Worktree `C:\Users\ASRock\usos-work\nt351-net`, gałąź `fix/nt351-net`. Wspólny core otrzymuje wyłącznie warunki `USOSNET_NT351`; osobne `src351/sources` i `build351.py` budują `usosnet351.sys`. NT4/95 i NDIS5 mają tę opcję wyłączoną. Stare pliki binarne zachowały hashe odpowiednio `4f2eb16b71753baab740302025b9e8ba02c38a676670b13626c757bdb3700f8d` i `8eac15b474b23fb4e7ac2c2431a4b17e6666cc2d03788b78ec2d8e19eeef89f9`.

NT351 rejestruje 3.0/0x3C, importuje czteroargumentowe `NdisMSetAttributes(TRUE, Pci)` i korzysta ze sprawdzonego EthDB+0xD8. Normalne RX/TX obsługują istniejące ISR/HandleInterrupt. CheckForHang wykonuje ograniczone RX/TX housekeeping jako wolny fallback; **nie tworzy, nie uzbraja ani nie anuluje prywatnego timera**. Pozostaje obowiązek runtime sprawdzenia IRQ w zainstalowanym NT351. QEMU 82576 nie dowodzi I211/X470 ani osiągów fallbacku 20 ms.

Diagnostyczne sekundy są nominalne: każde wywołanie checker dodaje 2 s, więc opóźnione/ominięte callbacki powodują dryf. Próg nominal3s TX stall jest wykrywany na następnym checkerze przy nominal4s, licznik saturuje i nie raportuje ponownie po przepełnieniu. Log cadence uwzględnia parzyste sekundy. Ten wariant nie zapisuje prywatnych danych przez `NdisWriteConfiguration` ani do systemowego event logu; opcjonalny serial i RAM zbiera host przy VM w jej katalogu artefaktów. Standardowa instalacja usługi/protokołu sieciowego Windows jest osobną konfiguracją systemu.

Finalny build `artifacts/nt351-network/build-03/build.json`: **17024 B**, PE i386 native OS/subsystem **3.10**, SHA-256 `dc8827954e6fe75ee8264c7382e87899cc9761890998198c126c7ea8aa5c55b6`. Plik do dalszej próby: `tools/nt/usosnet/bin/i386/usosnet351.sys`. Wszystkie 30 importów pochodzą wyłącznie z NDIS.SYS i występują w oryginalnym NDIS351; nie ma importów z nazwą Timer ani Ex. Build wymaga istniejącego WDK7.1; świeży output i TEMP/TMP są pod artifacts tego worktree, bez usuwania katalogów lub zapisu do profilu.

`tools/tests/test_usosnet351.py` oraz istniejący `test_usosnet.py`: **27/27 PASS, 0 skip**; wynik `artifacts/nt351-network/host-tests/result.json` wiąże testy z powyższym hashem. Nowe 7 testów sprawdza importy oryginalnego NDIS, PE, gotowe instrukcje rejestracji i callback prefix, 4 argumenty SetAttributes, oba wskazania EthDB+0xD8, hashe starych binarek oraz faktycznie skompilowany callback z mock chip operations (unstarted guard, IRQ/poll modes, kolejność RX/TX, nominalny czas, saturacja stall i cadence). Nie wykonuje NDIS ani fizycznego sprzętu na hoście.

**Nie ma jeszcze installed-Windows PASS, DHCP/brama/DNS ani wyniku USB NT3.** R17 reprodukuje Setup z dotychczasowym cache; nie zawiera tej binarki. Następna próba sieci musi jawnie dostarczyć i sprawdzić hash powyższego `usosnet351.sys`, zainstalować TCP/IP, uzyskać DHCP, zapisać bramę i DNS, a potem wykonać rzeczywiste próby pakietowe. Nie rozszerza się wariantu na NT3.5/3.1: ich oryginalne eksporty wymagają dalszego portu.

## Integracja do następnej świeżej instalacji

Pomiary `artifacts/nt351-network/inf-answer-contract.json`, `inf-auto-card-path.json`, `original-inf-patch-final.json` i `server-inf-contract.json` dotyczą oryginalnych INF w RAM. WS ISO/hash jest podany wyżej; kontrola Server użyła archiwum `caa4aea1c97500aaee99dfda7ebb748562d8e612e2bb87ea9fe4879b9ad34f43` i ISO `bc9e2d532f3f13c062a412b196eed72118ebd15b09fda6ffbea148d828b044c7`. NDIS.SYS Server ma identyczny hash jak WS. Wszystkie tymczasowe ISO zostały usunięte.

Oryginalny UNATTEND.TXT opisuje NetworkAdapterData/AutoNetOption=LOOP, AdapterParameters/Medium=0 dla802.3, TransportData/InstallTCPIP=1 i DomainData/AutoWorkGroup (klucze odpowiedzi z prefiksem!). INITIAL.INF czyta dokładnie !SetupNetWork (wielkie W) oraz te sekcje. NTLANMAN.INF przy niepustym AutoNetOption omija detekcję karty. OEMNXPTC.INF przy GUI_UNATTENDED ustawia EnableDHCPFlag=1, instaluje DHCP Client i mapy opcji3 (brama) i6 (DNS); adapter DHCP otrzymuje początkowe IP/mask0.0.0.0. To konfiguracja, nie dowód uzyskanego lease lub osiągalności.

OEMNADLB.INF ustawia usługę NDISLoop z loop.sys i ma bezwarunkowy dialog medium. Własna funkcja dodaje tylko branch GUI_UNATTENDED -> skipoptions, zachowując domyślne medium802.3. Patch wykonuje się po zakończonym boocie text-mode, na rozwiniętym system32/OEMNADLB.INF. Twardo sprawdza wejście, wyjście i readback:

| Edycja | Oryginalny OEMNADLB SHA256 | Po własnym patchu |
|---|---|---|
| WS | `5f64dac6ee633bf961b9d07e2907c63c962a8dc41186eb00a73836d4647bfa52` | `df77ec120ac57faa3bc5b8ba554d254a1c00be55bf56fdc930519c7b0aa16d33` |
| Server | `bc73cc4ffc1677bda5cb536aca9d6dc584a7b2970eb93303e629710c91132946` | `22e9fe3e67d6f097044de0b52e7918aec9e1e5bc10e6f3997c05766727dca125` |

Oba patche faktycznie wykonano na oryginalnym INF w RAM, zapisując tylko hashe/metadane. Nie dołączono plików Microsoft do repo.

renderForSystem emituje marker LAN tylko dla NT351 WS/Server i respektuje network=off. nt351_network_setup.sh wymaga zgodnych hashy binarki/loggera i dokładnie jednej obsługiwanej karty. Pierwsza próba ma celowo DHCP i automatyczny DNS; statyczne żądanie jest odrzucane przed przygotowaniem dysku. Staging zapisuje własne pliki obok aplikacji w C:\USOS\NT3. Inne NT3 minory nie otrzymują tego wariantu.

Po Setup własny USOSNT3 sprawdza rzeczywistą wersję3.51, istniejący Ethernet NDISLoop1, Medium0, EnableDHCP1 i TCP/IP Linkage zawierający adapter. Kopiuje usosnet351 do system32/drivers i porównuje pliki bajt po bajcie. Po readback konfiguracji ustawia ImagePath na nowy plik jako ostatni krok. Nie tworzy fałszywego adaptera przy brakującym stosie/powiązaniu. NET351.STATUS obok helpera wiąże wynik z manifestem źródła i nadal zapisuje installed_runtime_pass=false. Następny start ma dopiero załadować miniport. Standardowa rejestracja sterownika/protokołu jest konfiguracją instalowanego Windows; prywatne logi pozostają przy aplikacji.

Logger NT3 jest odrębnym snapshotem własnego GPL kodu z7024a504 pod tools/nt3/usoslog. Starego źródła/payloadu loggera9x/NT4 nie zmieniono. Przenośny rebuild snapshotu dał identyczną binarkę: SHA256 `fcf99da83e40fbee37496f22ff0f0cfec3386b393db36c87e748ef87c845017e`, GUI PE3.10. TESTNET.CMD uruchamia się jawnie po pulpicie z /once /nohook /nodbg i wyjściem C:\USOS\NT3\USABILITY.TXT. Staging nie uruchamia testów sieci.

Nowe testy rzeczywistego CLI renderera, DHCP answer, stagingu, odmowy złego SHA/dwóch kart/statycznego IP, markerów off/duplicate, patchowania i ochrony nowszych cache hunks:9 PASS. Z istniejącymi testami NT3/NT4 flow daje80/80 host PASS,0skip (host-tests/flow-result.json). Osobne27 testów binarki/core pozostaje ważne. USOSNT3 zbudowano i jego importy nadal przechodzą kontrolę NT3.1, mimo aktywacji nowej funkcji wyłącznie3.51. Nie jest to zainstalowany Windows ani DHCP PASS.

tools/tests/build_nt351_fixture_cache.py tworzy nowy katalog pod G:\USOS-Kolekcja\_assets, zachowuje prefix bazowego initrd3cfcae...ecd5 bajt w bajt i dokłada własny CPIO override. Na rzeczywiste skrypty cache nakłada wyłącznie nowe hunks NT351 i kontroluje zachowanie NT4 Storage/LogFile. Dołącza spójny helper, miniport/hash, logger/hash, własny stage i nowy UEFI renderer. Manifest podaje każdy hash i niedostępność lokalnie źródłowego commitu starego EFI; nie deklaruje nowego pełnego release USOS. Aktywne R17/cache pozostają bez zmian. Następny krok należy do kolejki po diagnozie start2, z USB-only input i rzeczywistymi testami sieci.

Cache faktycznie utworzono po commit d582087d: `G:\USOS-Kolekcja\_assets\B261020-200536-968CCBE8-nt351-net1`. Initrd SHA256 `c392c58954e77e940b98c81fa62be1efa2e1e0d1b243455b68ecfb6bedc00889`. Manifest jest w tym katalogu jako nt351-inputs.json oraz lokalnie artifacts/nt351-network/next-cache-manifest.json. Bazowy prefix zachowano i własny overlay odczytano zwrotnie przed utworzeniem cache.

## Kolektor i ograniczony dowód DHCP — przygotowane do przeglądu

`tools/tests/coverage/collect_nt351_success.py` po zakończeniu zewnętrznego QEMU, przed cleanup, odczytuje własny target.qcow2 wyłącznie readonly. Przyjmuje tylko literalne private_profile=false i dokładne foldery NT351 WS/Server pod własnym _vm, z jawnym cache pod _assets. Brak/None/0/string false są odrzucane. Eksportuje dokładnie C:/USOS/NT3/NET351.STATUS, NET351.ON, USABILITY.TXT, POST.LOG i USOSNET351.SHA256. System32/drivers/usosnet351.sys jest tylko hashowany w RAM kolektora, bez eksportu; rozmiar musi wynosić17024B. Hash porównuje z dc8827…c55b6. Nie czyta hives ani innych plików Windows. Granica własnego pliku to1MiB; transport, dekompresja, nazwy, duplikaty, NUL i UTF8 są sprawdzane. Manifest zawsze ma installed_runtime_pass=false, także przy zgodnym hashu i dodatnim statusie.

`nt351_capture.py` uruchamia wyłącznie lokalny pasywny odbiornik filter-mirror. Patch przypina dotychczasowy jedyny igb do netdev usabilitynet/MAC52:54:00:55:53:01 i odmawia capture bez tego modelu oraz powyższego keyless collectora. PCAP ma twardy limit8388608B razem z nagłówkami, JSON65536B, pojedyncza ramka65535B. Po osiągnięciu limitu odbiornik nadal opróżnia socket bez dalszego zapisu pakietów. Kończy się na EOF po zakończeniu procesu; nie odpytuje postępu. Błędna długość/truncation unieważnia dodatni wynik capture.

Format big-endian u32 length + raw Ethernet potwierdzono w [QEMU8.2 filter-mirror.c](https://raw.githubusercontent.com/qemu/qemu/v8.2.0/net/filter-mirror.c); vnet_hdr_support jest jawnie off. [Dokumentacja QEMU](https://www.qemu.org/docs/master/system/qemu-manpage.html) określa queue=all dla obu kierunków. Odbiornik nie otwiera interfejsów hosta. Obsługę opcji przez rzeczywistą binarkę QEMU trzeba potwierdzić w następnej próbie.

Analiza wymaga kolejnych Discover/Offer/Request/ACK dla tego samego xid/chaddr i MAC Ethernet, RequestedIP/server zgodnych z ofertą oraz dodatniego lease w ACK. Sprawdza długości, checksumy IPv4/UDP, brak fragmentacji, cookie i opcje DHCP. Kontrakt wymiany opisuje [RFC2131](https://www.rfc-editor.org/rfc/rfc2131). Analizuje dopiero rekordy po serialowym żądaniu start the prepared disk. To granica żądania, nie uwierzytelniona identyfikacja OS; stare pakiety oczekujące w buforze TCP mogą ją przeciąć. DORA wymaga więc spójności adresu ACK z logiem uruchomionym na pulpicie i hashu własnego miniportu. ICMP/DNS wymagają dopasowanej odpowiedzi w loggerze. Capture nie wystawia runtime/ICMP/DNS PASS.

`nt351-runner-e0fac76d.patch` dodaje --collect-nt351-success i --capture-nt351-network oraz dwa pola planu. Collector uruchamia się po zewnętrznym QEMU, także po desktop, przed kasowaniem konkretnego targetu. Nie konkuruje z instalacją. Aktywnej R17 nie zmieniono. Następny plan pozostaje nieuruchomiony; wymaga poprawki Date/Time oraz przeglądu i integracji patcha przez root.

14 testów hostowych sprawdza politykę/archiwum/transport, rzeczywiste tar/base64 i hash własnej binarki z mock mtools, fragmentowany socket, pełny limit ze100 odebranymi ramkami, błędne długości/EOF, korelację DHCP i odmowy oraz git apply do e0fac76d i kolejność collect przed cleanup. To nie jest wykonanie collectora ani sieci w VM.

Review poprawił kolejność zamykania dla Python3.13: najpierw close listener, ograniczone oczekiwanie klienta i close/cancel, dopiero bounded server.wait_closed. Realny localhost client pozostawiony otwarty potwierdził zakończenie finish po5s, zamiast wcześniejszego nieosiągalnego timeoutu. Start capture przeniesiono bezpośrednio do osłoniętej fazy spawn po całym preflight. Po tej poprawce zestaw ma15/15 host PASS.

## Dopasowane odpowiedzi DNS i alias UTC

Przegląd starego loggera wykazał, że UDP DNS raportował ID/source, ale mógł ustawić resolved z niedopasowanej odpowiedzi. Odrębny snapshot NT3 otrzymał `usoslog_dns_packet.h`; NT4/9x pozostają bez zmian. Caller wymaga właściwego recvfrom IP/port53/family/rozmiaru, parser wymaga ID, QR, opcode0, rcode0, TC0, dokładnego question A/IN oraz pasującego answer A lub maksymalnie16 ogniw CNAME. Sprawdza granice wszystkich rekordów, limity nazw i wskaźników kompresji; odrzuca pętle i obce rekordy A. Dopiero wtedy ustawia wynik i loguje DNS PASS dns_match=1. Zgodny format wynika z [RFC1035](https://www.rfc-editor.org/rfc/rfc1035.html), a korelacja peer/ID/question z [RFC5452](https://www.rfc-editor.org/rfc/rfc5452.html). To ograniczony matcher diagnostyczny, bez DNSSEC; nie zastępuje stosu resolvera Windows.

Nowy logger: **1023488 B**, SHA256 `ff2585043a882065f9598628ac31afdaba356a3d91f3e55d93a36e313e3983b7`. Dwa buildy (pomiar, następnie pinned rebuild) dały identyczne bajty. PE pozostaje3.10, timestamp0, wszystkie71 statycznych importów są identyczne z wcześniej sprawdzonym fcf99…017e, więc dowód oryginalnych eksportów nadal obejmuje ten sam komplet. Wynik `artifacts/nt351-network/logger-dns-preflight.json`. 7/7 testów wykonuje rzeczywisty skompilowany parser C: poprawne odpowiedzi/CNAME, obce pytania/ID/peer, flagi, truncated i compression loops oraz1500 deterministycznych mutacji. Nie wykonano jeszcze tego loggera w NT3.

Nałożono dokładną jedną linię fixu `9eaa561d` z gałęzi agenta flatNT: en351 Greenwich -> (GMT) Monrovia, Casablanca. Własny host test uruchamia rzeczywistą funkcję resolvera i kontroluje brak tej zamiany w NT4. NT351 network flow ma po dodaniu testu10/10 PASS. Według agenta fix przeszedł też Date/Time w świeżym A/B bez inputu; nie przedstawia się tego jako desktop ani LAN PASS. Builder następnego cache obejmie tylko ten hunk i własny nowy logger/hash, zachowując nowsze NT4 hunki w rzeczywistym bazowym cache.

Finalny cache przygotowany do R18 to `G:\USOS-Kolekcja\_assets\B261020-200536-968CCBE8-nt351-net2`, initrd SHA256 `ea7c1f59537bc0c8ba7eb518bde5cbd41d327067529e417a6d4401d9efd13aca`, source commit `ec8d61d1`. Manifest nt351-inputs.json potwierdza bazowy prefix i readback wszystkich własnych nadpisań. W tym cache jest powyższy logger ff258…83b7 oraz jedna linia aliasu UTC; net1 pozostaje historycznym wariantem z poprzednim loggerem i bez aliasu.

Plan `artifacts/nt351-network/nt351-network-hid-plan-r18.json` ma tag r18-nt351-network-hid, USB-only, collector oraz capture. Pozostaje NOT RUN do koordynacji root po R17. Root zintegrował collector/capture jako matrix7d3feed8 i zgłosił15 nowych+72 istniejące coverage testy PASS. Przed finish po rzeczywistym pulpicie należy zakończyć TESTNET.CMD i natywnie zamknąć Windows, aby zapisać pliki z guest cache. Samo QMP quit nie zastępuje flush. Wynik collectora nadal wymaga osobnej oceny treści, DORA/adresu i dopasowanych odpowiedzi; nie ma jeszcze installed-Windows LAN/USB PASS.

Nie uruchomiono przygotowanego planu artifacts/nt351-network/nt351-network-hid-plan-next.json. Używa USB-only input, jednego igb i klawiatury/myszy USB. next-run-requirements.json wymaga najpierw rozstrzygnięcia R17/start2 oraz kolektora sukcesu przed usunięciem targetu: własny NET351.STATUS/USABILITY.TXT i hash system32/drivers/usosnet351.sys. DHCP musi mieć dowód wymiany pakietów, a brama i DNS rzeczywiste próby; sam wpis lease/konfiguracji w rejestrze nie wystarcza. Logger uruchamia się jawnie dopiero po pulpicie.
