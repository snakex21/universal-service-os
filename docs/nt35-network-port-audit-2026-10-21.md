# Eksperymentalny LAN NT3.5 — dowody i historia portu

Późniejsza kwalifikacja czterech offsetów IRQ na zachowanym R20b dała standardowy
ping3/3 time<10ms, logger ICMP1s/strict DNS/HTTP200 oraz native shutdown/rc0
z dokładnym stopped SYS readback. Szczegóły, manifest i ograniczenie do tej
zainstalowanej fixture: [nt35-irq-canonical-registers.md](nt35-irq-canonical-registers.md).
Poniższe około2s i FAIL11010 są zachowaną historią poprzedniego sterownika.

Aktualny wynik R20: świeży normalny USOS osiągnął Program Manager Version3.5,
DHCP, dopasowany ICMP oraz UDP/TCP DNS. `r20-guest-evaluation.json` wiąże wynik
z faktycznym installed SYS e1aa...21c5, gościem i zakończonym capture. Stock ping
5s dał najpierw2/3, oddzielny warm3/3; opóźnienia około2s pozostają usterką
używalności. StrictDORA=false zachowano, osobne dopasowane pary i guest lease
potwierdzają przydział. Native safe shutdown/QMPquit/rc0 i ścisły odzysk5plików
zakończone. R20b osobno sprawdza USB przy i8042prtStart4. Poniższe sekcje są
historią pomiarów, a ich wcześniejsze oczekiwanie na runtime nie jest nowym
ograniczeniem aktualnego wyniku. Szczegóły w nt35-r20b-usb-isolation.md.

Fix/nt35-net pochodzi z NT351b762b240. Build i host testy nie są wynikiem Windows; nie wykonano jeszcze nowej instalacjiNT35. ISO SHA256109d2c28e3d774e01987434b11c622fbf336e01f28eec2eafe40544f166852d1 i NDISfa392210418f6a5977ea8117d49b4d6a0b4cfc7d4fcc436fca2e3defdd6a5543 są związane z oryginalnym nośnikiem. Expanded MS pliki pozostawały wRAM, tymczasowyISO pod własnymG/_audit usunięto. Metadane są w artifacts/nt35-network/original-{bus,setup}-contract-04/05.json.

NdisPciAssignResourcesEE64 ma5argumentów i zapisuje listę do pierwszego fullMAC handle+6C. Nie jest aliasem miniportowego API. Nowy driver nie importuje go ani trzech nieobecnych MPciAssignResources/MQueryAdapterResources/OverrideBusNumber, nie tworzy fałszywych uchwytów/stubów.

Wrapper9258 odczytuje Parameters/BusNumber (Unicode9242, call9599, ESI95A7) i BusType (Unicode9232, call95C7, EDI95D5), potem przypisuje miniport bus+104 w96F0 i type+108 w96EA. Read/WritePCI4BFC/4C30 korzystają z+104. MMapIoSpace7EA0 deleguje doMapIoSpaceCB84, która raportuje zakres przezIoReportResourceUsage i tłumaczy adres przezHalTranslateBusAddress. ConfiguredFind35 wymaga BusType5, BusNumber0..255, UsosPciSlot0..255 i właściwegoID na prawdziwym miniport handle. Używa firmwareBAR/IRQ oraz claim przezMMapIoSpace. Nie zapisuje prywatnych offsetów ani nie przestawia busów. Poprawność rzeczywistego MMIO/DMA pozostaje do sprawdzenia wWindows.

RegisterMiniport1BD0 wymaga3.0/0x3C. Wewnętrzne RX1885→188B iComplete1890→1896 używają EthDBD8. Checker946 posiada lock+30/busy+2E, wywołuje zarejestrowanyCheckForHang i uzbraja2000ms w9DD–9E9. Halt7F68 używa tego samego gate, anuluje timer+90, wołaHalt8005. DirectCFG checker93/Halt66instr ma truncation=false. Duży wrapper ma jawne truncation3000; wnioski bus dotyczą konkretnej prześledzonej ścieżki, nie całego wrappera. Driver nie tworzy własnego timera/DPC. IRQ pozostaje ścieżką normalną, checker wolnym fallback, bez obietnicy20ms.

Usosnet35 build02:16384B, SHA256e1aa69a3ec8e3da802013131abbb6fefc9f466da6f4eeb66fe15ec47e60421c5, PE3.10/nativei386,27importów NDIS obecnych w tym oryginale.8NT35 hostPASS obejmuje skompilowaną faktyczną ConfiguredFind35, odmowy i PE/import/ABI.8NT351 +20istniejących usosnetPASS. RuntimeNT351f39, NT4 iNDIS5 binarki niezmienione. Kontrolny rebuild351 ma identyczne .text/INIT/.data/.reloc; inne bajty są wyłącznie w linktimestamp, CodeView/PDB, wynikowym rozmiarze virtual.rdata i checksum. Nie podmieniono runtime351.

Scoped collect_nt35_success pozwala tylko literalne keyless false i folderNT3.5WS/Server oraz własne _vm/_assets/artifacts/coverage. Odczytuje readonly5własnych tekstów NET35.STATUS/NET35.ON/USABILITY.TXT/POST.LOG/USOSNET35.SHA256 i hash16384B systemowego własnegoSYS. Nie eksportuje hive/MSplików ani nie podnosi runtimePASS z obecności/statusu.8evidencehostPASS: realny tar/gzip/base64/hash, odmowy prywatnego/obcegoOS, traversal/duplicate/NUL oraz wykonanie rzeczywistego preflight z patcha. Capture używa istniejącego8MiB localhost mirror, soleigb/MAC52:54:00:55:53:01; bez interfejsu hosta i pollingu. Trzy politykiNT35/NT351/NT4 są wyłączne. Patch tools/tests/coverage/nt35-runner-015ddddf.patch przeszedł gitapply--check na matrix015ddddf; matrix nie edytowano.

Primary setupNT35: INITIAL0bd331...a7b w475–477 czyta NetworkAdapterData/NetCardParameterList/DomainData. NTLANMAN8ed0...344b w414–416 czyta TransportData wGUIunattended,688–701 honorujeAutoNetOptionLOOP. OEMNXPTCd4dcee...ce4 w107–108 ustawiaEnableDHCP1 wGUIunattended i zawiera usługęDHCPCSVC oraz właściwe opcje bramy/DNS. Ograniczenia DHCP nośnikaNT3.1 nie dotycząNT35. OEMNADLB37e16...7cb0 po faktycznie wykonanym własnym patchu dialogu medium mafff3c...27cf. Nowy posthelperPE3.10 SHA2dbd8ca90d229d55731fa18287a107b7d7da8d394c2a4306a3ad7db9e5782944 i loggerff258 mają zero brakujących importów względem oryginalnych KERNEL32/ADVAPI32/USER32.

Renderer/staging/helper/cache są w trakcie integracji. Przed świeżą próbą trzeba przypiąć spójnycache, zachować późniejszeNT4hunki, zintegrować collector i przejść zwykłyRAMguard. Pulpit,USBreplug,DHCP,guestICMPmatch iDNSmatch nadal wymagają rzeczywistego runtime. R17 pozostaje osobnym starym przypadkiem z pasywnym listenerem.

## Spójna integracja przed świeżym runem, 2026-10-22

Oryginalny TXTSETUP.SIF w ponowionym audycie06 potwierdza MajorVersion3/MinorVersion50. Nowe hooki używają3:50, SOURCE.TXT3.50, a helper wymaga faktycznego GetVersion3.50. Omyłkowy warunek5 wykryto i poprawiono przed uruchomieniemVM. Helper finalny post-build-04:24576B, SHA2568ab10c79cbbdab08c7f6d722219cbf14e034df9cb798739fdae3e64fab477024, źródło07e628ac16e0d2f3fb65a6a95f18f1c404e7dae95e1f4060e19d46cfd5311db9, PE3.10;50importów bez brakujących w oryginalnych DLL. Wcześniejsze buildy01–03 są historyczne i nie trafiają do nowego cache.

Renderer tworzy wyłącznie markerNT35 dla3.5/Server. Staging wymaga jednego obsługiwanegoPCI, DHCP i automatycznegoDNS oraz zweryfikowanych własnych payloadów. BDF0000:bb:dd.f jest dekodowany do bus/slot bez skanowania czy zgadywania busa. SIF korzysta z oryginalnych NetworkAdapterData/NetCardParameterList/TransportData/DomainData, medium0, AutoNetOptionLOOP i TCP/IP. Własny helper zmienia istniejący oryginalny NDISLoop dopiero po sprawdzeniu medium0, DHCP1, powiązania i odczycie skopiowanego SYS/parametrów; ImagePath jest ostatnią operacją. Status nie oznacza działania sieci.

Actual renderer/staging/BDF/refusal11PASS, skompilowany metadata-parser/commit-order2PASS, cache2PASS, istniejący NT3flow35PASS, NT351flow10PASS; Zig build test zakończony exit0. To testy hosta. Collector/capture zintegrowany przez root w matrixc0c5ab26 ma114coveragePASS; własna kopia zawiera ten sam ścisły guard typu folderu.

Nowy cache-builder czyta wszystkie warstwy newc przed nałożeniem delty. Rzeczywisty net2ea7c1f...13aca ma2warstwy/832entries. Trzy hunki nakładają się jednoznacznie na aktualne skrypty, zachowując późniejszeNT4 Storage/LogFile. Oryginalny skompresowany initrd jest zachowany jako prefiks; następna warstwa zawiera wyłącznie nowe własne payloady i te delty. Pełny efektywny readback sprawdza również niezmienione wpisy. Format wielu archiwów opisuje [pierwotna dokumentacja kernela](https://www.kernel.org/doc/html/latest/driver-api/early-userspace/buffer-format.html). Nowa EFI jest własnym buildem renderera; nie ma dowodu równoważności całego release ani historycznego source-commit bazowej EFI.

Pierwsza świeża instalacja ma i8042 sprzętowoON ze względu na udowodnioną zależność NTDETECT351. To nie jest USB-onlyPASS. Dopiero osobny zachowany overlay po natywnym shutdown pozwoli wyłączyć sam i8042prt i sprawdzić USB; żadna zmiana usosusb/hubów nie jest częścią tej integracji. R17 pozostaje oddzielny i niezmieniony.

Cache net1 powstał z czystego0b6e7907: initrd8bfc9d006670aeb05970383cde2e14da709dd28646f3ed66537fd0f81c6b1790, overlayf286cb3fb63e31502ccc9c9e8651404ad862b1716536f78878f31932bab7b8cd, EFI5d64d0e5357d99976278028159f0fe02c7fd8679d0b9eaf1b793855516370828.3warstwy/837entries, pełny odczyt efektywnych wpisów i zachowanie prefiksuPASS. Dokładny manifest pozostaje w artifacts/nt35-network/next-cache-manifest.json i w cache/nt35-inputs.json.

R20 r20-nt35-network-hid wystartował przez matrixrun_plan z tego cache (TTY24068). ps2_input=false oznacza dołączoneUSBkbd/mouse, zaś usb_only_input=false pozostawia i8042 sprzętowoON. Jedynyigb/MAC52:54:00:55:53:01 ma ograniczony8MiB mirror. Pasywny listener utworzył nowy hardlink targetu _vm/r20-nt35-preserved/target.qcow2; aktywnego obrazu nie odczytywano ani nie kopiowano. R20 czeka pasywnie na endpoint. To jeszcze nie wynikWindows.

Startowy boot_menu i successcollector są już załadowane z matrixc0c5ab26. Późniejsza zmiana plików archive_policy nie podmienia bytecode uruchomionego procesu; failurecollector jest importowany późno. Przy końcowym odczycie trzeba rozróżnić te wersje i, w razie potrzeby, zweryfikować ukończony transport nową ścisłą polityką bez kolejnejVM.

Osobny statyczny audyt original-usb-imports-02.json potwierdził19importów frozenUSB2d455...cfe1 w obu oryginalnychNT35kernelach UP53fbab...ea58/MP7f1444...a0be i standardowymHAL142045...05f5. Nie ma brakujących nazw. FrozenUSBpozostajePE4.0; sama wersjaPE i zgodne importy nie dowodzą uruchomienia/CONNECT/ENABLE/HID. Nie zmieniono source/hubów/binarnegoUSB. OryginalneMSbajty tylkoRAM, temporaryISO usunięto.


## NT35 timezone i rozpoznanie wersji hive

Po rozstrzygnięciu R17 sprawdzono odrębnie oryginalne dane NT35. Sam main.cpl 99003c...7275 nie zawiera etykiety Monrovia; ma jednak ścieżkę Software/Microsoft/Windows NT/CurrentVersion/Time Zones i przełącznik /INSTALL=. INITIAL.INF831–834 wywołuje go z !TimeZone. Sam brak stringa w CPL nie jest dowodem błędnego aliasu.

Oryginalny i386/software._ po rozpakowaniu ma SHA25635a9dbe06bda1b23f716b33a0786ac28e263fc5aef7d742dc0845ae8c2a18192 i faktyczny REGF1.2. Po sprawdzeniu nagłówka/checksum/cleanseq odczytano go wyłącznie w RAM za pomocą czytnika1.2. Klucz Time Zones/GMT Standard Time ma Display=(GMT) Monrovia, Casablanca; inny GMT ma Display=(GMT) Greenwich Mean Time; Dublin, Edinburgh, London. To źródłowe potwierdzenie etykiety użytej w cache R20, nadal bez deklaracji unattended/runtimePASS. Odtwarzalny tools/tests/audit_nt35_timezone.py wykonał ponowiony pomiar do original-timezone-contract-05.json; MS bajty nie zostały wyeksportowane, temporaryISO usunięto.

Wersję trzeba rozpoznać dla konkretnego pliku. [Dokumentacja libregf](https://github.com/libyal/libregf/blob/main/documentation/Windows%20NT%20Registry%20File%20%28REGF%29%20format.asciidoc) opisuje odmienne komórki1.1 i kolejne wersje. Zakończony NT31 R19 roota ma faktycznie SYSTEM1.1; to nie uzasadnia automatycznego założenia1.1 dla NT35 ani1.2 dla wszystkich jego hivów. Root zweryfikował osobny bounded regf11.py na tym NT31. Dla przyszłego stopped-readback R20 wybór czytnika nastąpi dopiero po własnym nagłówku; nie użyto351patchera na aktywnym NT35.

Przy aktualizacji dokumentacji wykryto użycie domyślnego lokalnego dekodowania CP1250. Odtworzono trzy historyczne sekcje z ich pierwotnych commitów, zachowując UTF8 bez wielokrotnego przekodowania. Nowe pomocnicze skrypty czytają teksty jawnie jako UTF8; nie zmieniono payloadów cache, sterownika ani aktywnej VM.
