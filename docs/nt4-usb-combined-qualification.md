# NT4: wspólna kwalifikacja HID i MSC na tym samym frozen SYS

Wynik: wspólny installed-overlay HID+MSC PASS na tym samym frozen313952.
Klawiatura i mysz przeszły odłączenie/ponowne podłączenie z kontrolami
negatywnymi; START, HOTPLUG i ROUNDTRIP pozostały czytelne po replug nośnika.
Natywne Shutdown/safe-off25, QMP exit0 i stopped readback są zakończone.
Historyczny osobny HID2d455 zachowuje własny zakres i dowody.

Po utrwaleniu wyników własne obrazy testowe usunięto zgodnie z osobnym
[potwierdzeniem sprzątania](nt4-usb-image-cleanup.md). Opis obrazów i odczytów
poniżej dotyczy stanu zakończonej kwalifikacji. Źródła, helpery, klatki,
logi i przypięte metadane w C pozostają zachowane.

Osobny test `nt4-installed03-usb-combo01` startuje z COW zamkniętego
MSC04, target SHA256
`a6807a432891b47ea20a4eb1650fc981ae8b7fdade6cec138d9ef03818b1de5c`.
Ten rodzic ma zakończony natywny Shutdown/safe-off, QMP exit0 oraz
potwierdzony START/HOTPLUG/ROUNDTRIP/replug. MSC04 pozostaje niezmieniony.
Jego oryginalny rodzic candidate03 cf04 również pozostaje niezmieniony.

Jedyna zmiana celu przed startem to istniejący DWORD
`ControlSet001/Services/i8042prt/Start`:1→4. Sprzęt i8042 wciąż jest obecny.
Pełny SYSTEM przed i po przygotowaniu różni się tylko tym DWORD, offset hive
143284, raw351415732. Po odtworzeniu starego DWORD cały raw jest identyczny z
rodzicem według qemu-img compare. Zmieniony raw i COW również są identyczne.
Niezależny ponowny odczyt potwierdził delta i identyczność pozostałych
2056 plików. Nie dodano żadnych plików celu.

Faktycznie zainstalowany własny `USOSUSB.SYS` 43648B ma SHA256
`3139522926f054946b280c14c962593062817a0ca71170a5aeeb8551a6fab2a1`.
Obserwator 5120B pozostaje dokładnie tym samym
`75cef5e2e8be39b1cdc3d52a0f414464a86cd85fb0513de1139133fc3ac6429e`.
SYS, helper, fixture marker i dotychczasowy własny log nie zostały zmienione.
38 importów SYS i 14 helpera rozwiązano ponownie względem rzeczywistych
NT4 NTOSKRNL/HAL/KERNEL32, wyłącznie w RAM. Nie przebudowano ani nie
zmieniono drivera, hubów ani modułów Microsoft.

## Topologia i ukończone testy

| Stały port xhci.0 | Urządzenie |
| --- | --- |
| 1 | startowy USB MSC/FAT16, serial USOS-USB-BOOT-TEST |
| 2 | hot/replug USB MSC/FAT16, serial USOS-USB-HOT-TEST |
| 3 | usb-kbd coveragekbd |
| 4 | względna usb-mouse coveragepointer |

Nośniki są świeżymi własnymi kopiami o dokładnie identycznych początkowych
pinach jak w MSC04: boot cabf0e03…1a28, hot29760ec7…e44c.
Ich prywatne FAT16/MBR payloady i etykiety odczytano niezależnie.
Named blockdev pozostaje przy device_del; przy reinsert wraca dokładnie
ten sam hot backend, port i serial. Test nie używa fizycznego USB.

Ukończona kolejność: keyboard remove/negatywny brak wpisu/insert/rzeczywisty wpis;
mouse remove przy żywej klawiaturze/insert/ruch i kliknięcie menu;
dopiero potem jawne STARTUP, HOT, REPLUG obserwatora oraz natywne pliki.
Obserwator zamyka i flushuje plik przed zakończeniem akcji. Nie wyjmujemy
nośnika podczas zapisu. Każdy sygnał COM1 jest osobnym uzbrojonym future.
Operator wykonuje pojedyncze akcje; brak pętli oczekiwania na wolumin,
odczytów postępu lub dodatkowych automatycznych zrzutów.

| Czynność | Faktyczny dowód |
| --- | --- |
| Klawiatura przed odłączeniem | Run03: nt4combo |
| Keyboard remove i próba AB | Run04: nadal nt4combo, AB nie pojawia się |
| Keyboard insert i rzeczywiste CD | Run06: nt4combocd |
| Mouse remove, rel100/100, żywa klawiatura | Run07: dopisane mouseout, kursor bez ruchu |
| Mouse insert, ruch i lewy klik | frame09: ruch, frame10: otwarte menu Start |
| START w tej samej konfiguracji HID | STARTUP11:0, native Notepad12: START payload |
| HOT i własny zapis | HOT14:0, Explorer14: D/E, native Notepad15/16: HOTPLUG/ROUNDTRIP |
| Wyjęcie po zamknięciu Notatnika17 | DEVICE_DELETED18, nieprzesłonięty nowy Explorer19: D bez E |
| Ten sam nośnik ponownie | REPLUG21:0, Explorer21: D/E, native Notepad22: persisted ROUNDTRIP |
| Mysz działa po ponownym włożeniu nośnika | lewy klik23 rzeczywiście otwiera Start |
| Bezpieczne wyłączenie | native Shutdown24, safe-off25, TTY98310 exit0/QMP quit |

Obserwator dopisał wyłącznie trzy nowe pomyślne etapy do własnego logu;
prefiks zachowany po MSC04 pozostał identyczny. Oddzielny tail logu zapobiega
zaliczeniu starych wpisów. Wszystkie zakończenia COM1 oceniono jako nowe,
jednorazowe futures, uzbrojone przed akcją. Fizyczne odczytanie plików przez
Notatnik i wynik stopped FAT readback stanowią odrębne dowody od QMP.

Stopped target:
`dc757988b9634acaa03c5a4cb90d64e268c7109e62bdd88ea73b52cd8d0493fa`.
Ponownie potwierdzono dokładne SYS/helper i ich importy, Select Current/Default1,
i8042prt Start4, usosusb/kbdclass/mouclass Start1, NDISLoop Start3.
SYSTEM po normalnych zmianach Windows ma SHA256
`bfa316328dffcc119465ca131a07fe611934efa501a0235de10dc0ab8076e297`;
twierdzenie o jedynym zmienionym DWORD dotyczy przygotowania przed startem.
Oba własne FAT16 zachowały etykiety i znaczniki, HOT zachował ROUNDTRIP
SHA256 `003fd2202119eff8ac1e0e241942c8a9ce4ad2465f57339143e3557eb84efe15`.
Oba rodzice pozostały niezmienione, whole-disk scratch usunięto po sprawdzeniu
dokładnych własnych ścieżek. Samodzielnych modułów/hive MS nie eksportowano.

To installed-overlay BIOS/q35/AHCI, z zimnym firmware innym od świeżego
normalnego USOS OVMF/CSM. Nie kwalifikuje LAN, fizycznego sprzętu ani fresh
AUTO. NDISLoop w tej próbie miał Start3; współistnienie z zakwalifikowaną
aktywną siecią jest osobnym testem właściciela NT4 NET.
Nie deklarujemy automatycznego odświeżania istniejącego Explorera. Użyto
nowych okien; WinM zminimalizował powitalne okno Microsoft przed frame19.

Dowody przygotowania: `artifacts/nt4-combo/preparation.json`.
Runtime: `artifacts/coverage/vm/nt4-installed03-usb-combo01`.
Zakończone własne dowody: `artifacts/nt4-combo/stopped-readback.json`,
`evaluation.json`, `MSC4LOG.TXT` i osobny `combo-own-log-tail.txt`.
Normalny guard wymagał 2GiB RAM i 8GiB rezerwy, operator miał prawdziwy PTY
i limit450 encoded JSON bytes. Dwa nowe testy kontraktu operatora PASS.
Nie wykonywano odpytywania postępu; oczekiwania korzystały z dokładnych
przyszłych zdarzeń i ReadDirectoryChangesW.

## Plan własnych zakończonych obrazów, bez kasowania

Odczytowy skrypt `tools/tests/coverage/plan_nt4_usb_cleanup.py` zapisał
`artifacts/nt4-usb-cleanup-plan.json`. Zweryfikował zakończenia i dokładne
ścieżki bez reparse points, rozmiary z otwartych uchwytów, SHA256 oraz
`qemu-img info --backing-chain`. Łączny otwarty rozmiar plików własnych:
2294808896B. Nie jest to pomiar rzeczywistego odzysku miejsca po usunięciu.

| Dokładny własny katalog | Rozmiar plików | Zależność celu |
| --- | ---: | --- |
| G:\USOS-Kolekcja\_vm\nt4-installed03-usb-combo01 | 459210752B | MSC04 |
| G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc04 | 459210752B | chroniony candidate03; rodzic combo01 |
| G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc03 | 459210752B | chroniony candidate03 |
| G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc02 | 459145216B | chroniony candidate03; tylko przygotowanie |
| G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc01 | 0B | pusty po odmowie przygotowania |
| G:\USOS-Kolekcja\_vm\nt4-installed03-usb-hid01 | 458031424B | chroniony candidate03 |

Znane własne drzewo: combo01/target.qcow2 → msc04/target.qcow2 →
`G:\USOS-Kolekcja\_vm\nt4-sp6a-desktop-net-ps2-candidate03\target-retained.qcow2`.
Pozostałe własne targety wskazują bezpośrednio na ten chroniony candidate03.
Własne nośniki USB nie mają backing parent. Przyszłe wykonanie planu należy
do root: najpierw zebranie dowodów i ustalenie zewnętrznych zależności,
następnie ewentualnie dziecko combo01 przed rodzicem MSC04. Wspólny
candidate03, wszystkie NET oraz wszystkie macOS, w tym odmówione02–04,
pozostają poza planem. Commit6457ab4b utrwalił wyłącznie plan; późniejsze
autoryzowane wykonanie opisuje `docs/nt4-usb-image-cleanup.md`.

Do ręcznego potwierdzenia użytkownika: czy klawiatura, mysz i pliki nośnika
po wyjęciu/włożeniu działają razem na tym samym sterowniku: TAK/NIE.
Operator VM potwierdził powyższe czynności. Odpowiedź użytkownika pozostaje
osobną oceną używalności, bez deklarowania fizycznego sprzętu PASS.
