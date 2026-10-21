# NT4: przegląd instalatora, USB HID i sieci — 2026-10-21

NT4 nie ma jeszcze świeżego wyniku PASS pulpitu, ponownego podłączenia HID
ani sieci. Poniżej oddzielono dowody hostowe, zakończone próby QEMU i zadania
na fizycznym X470. Nie uruchomiono dodatkowej VM, nie wykonano pełnego buildu,
merge, push ani wdrożenia; nie dotykano fizycznych dysków.

## Zakres i pochodzenie

- Własny worktree: `C:\Users\ASRock\usos-work\nt4-net`, gałąź
  `fix/nt4-net`, baza `54282e85`. Przejrzano również tester z
  `macierz-windows` przy `786bcabd`.
- Nie zmieniano `tools/nt4/usosusb`, hubów ani binariów USB. Właścicielem
  tych obszarów pozostaje Claude.
- Oryginalny NT4 Workstation PL ISO:
  `7aae3d7c36619c4edab58c8dccf9d350c78639f88afa36ae6b21e2e9cee9611b`.
- SP6a PL, członek `SP6I386.EXE`:
  `a3306f0bc93d1d4709ab784ecd8aebd1a162c8249a219a9e078d1a4a91260542`.
- Sprawdzony `usosnet4.sys`:
  `4f2eb16b71753baab740302025b9e8ba02c38a676670b13626c757bdb3700f8d`.
- Sprawdzony własny `USOSLOG.EXE` z `usability-usb-net/artifacts/nt4-net-build`:
  `1f6a74ab8a5a8ddd9d0a67a465f86db75e1a02f944f5f9275a9ec1740299bcff`.

## Zakończone próby QEMU

| Próba | Co rzeczywiście zaszło | Czego nie dowodzi |
| --- | --- | --- |
| `r6-nt4-msc-usb-net` | USOS przygotował cel i uruchomił wewnętrzny Setup. Na starcie 2 instalator przestał zapisywać; produkt zakończył próbę `rc=3`, po 904 s bez zapisu i około 3545 s pracy instalatora. | Brak świeżego pulpitu, SP6a, HID, MSC i sieci. Konkretna strona Setupu pozostaje nieznana. |
| `r7-nt4-keyless-setup-diagnostic` | Po około 11 s pojawił się formularz klucza produktu w menu USOS. Cel pozostał pusty. Limit 10800 s minął na tym formularzu. | Windows nie wystartował. To błąd fixture, nie wynik instalatora NT4. |
| `r16-nt4-sp6a-hid-native-text` | Plan jest zakolejkowany przez właściciela głównego testera; niniejszy przegląd go nie dubluje i nie odczytuje postępu. | Do powiadomienia o zakończeniu brak wyniku. |

Zapisane dowody r6/r7 są w
`macierz-windows/artifacts/coverage/vm/<tag>/result.json`, `serial.log` i
`cleanup.json`. Obrazy r6/r7 zostały usunięte. Błąd runnera r6 o niedozwolonym
ręcznym przechwyceniu ekranu nie usuwa wcześniejszego faktu awarii produktu;
ochrona prywatnego Setupu powstrzymała wykonanie zrzutu nieznanej strony.

Wewnętrzny NT4 Setup ma `-nic none` i nie otrzymuje xHCI. Skrypty kopiują
oraz rejestrują `USOSUSB.SYS` i `usosnet4.sys` dopiero w `POST.CMD` po GUI
Setupie. Samo zatrzymanie przy starcie 2 nie pozwala przypisać przyczyny tym
sterownikom. Potrzebny jest wynik kolektora tekstu i ustalenie, czy wykonano
`POST.CMD`.

## Rozłączne zestawy USB i loggera

- R6 używał starego cache MSC z `feat/nt4-usb-sticks`, commit
  `ed1e14598927516c70a778d1a7cabfab7428d539` i usosusb 1.1. To nie są nowe huby.
- R16 używa osobnego cache HID 1.3, opartego na
  `f28a3fd8155b82dd1be22608f6ef17e82437ad1d`. Ten cache zastępuje dokładnie
  trzy własne binaria USB; nie zawiera niepołączonego NT4 MSC.
- Żaden z tych testów nie potwierdza wykonania nowej integracji loggera
  `54282e85`. Nie należy łączyć wyników różnych cache w jeden wynik PASS.

## Host: wykonane sprawdzenia

Przeprowadzono 62 różne testy hostowe obejmujące:

- `test_logger_network`: 7 testów rzeczywistej funkcji C z syntetycznymi
  API, w tym sukces ICMP tylko przy zgodnym adresie bramy, statusie i treści
  odpowiedzi; timeout, zła treść, zły wskaźnik, brak API i brak bramy nie
  dają PASS; REG_SZ/MULTI_SZ, DHCP i statyczny wybór bramy/DNS.
- 2 testy rzeczywistego przeniesionego `USOSLOG.EXE`: domyślny zapis w
  `LOGS` obok EXE oraz jawny `/out` bez dodatkowego katalogu domyślnego.
- 3 testy ukrytego uruchomienia loggera w kroku NT4 i 3 testy argumentów
  towarzyszącego programu diagnostycznego.
- 20 testów `test_usosnet`: importy NDIS4 dostępne w oryginalnym NT4 SP6a,
  PE 4.00, struktura rejestracji 0x48, filtr odbioru NDIS3/4 zamiast handlerów
  NDIS5, skan PCI i przypisanie zasobów ścieżki NT4, classifier i logika IRQ.
- 27 testów `test_network_defaults`: staging oryginalnych własnych bajtów,
  rozdział NDIS4/5, brak sieci, przygotowanie NT4/NDISLoop1, DHCP,
  zatrzymanie przy brakującym loggerze, realne kompilacje GUI PE4 bez CRT,
  eksporty importów NT4 i renderowanie odpowiedzi.

Pierwsze uruchomienie miało 56 PASS, dwa błędy testów kompilacji oraz błąd
`setUpClass Render`, ponieważ nowy worktree nie zawierał `tools/zig/zig.exe`.
Po ustawieniu `USOS_ZIG` na istniejący
`C:\Users\ASRock\usos-work\dokumentacja-9x\tools\zig\zig.exe` ponowiono
`Builds` i `Render`: 7/7 PASS, w tym jeden wcześniej zaliczony test.
Łączny wynik to 62 różne testy PASS. Nie jest to wynik wykonania w NT4.
Logi i manifest hostowy: `artifacts/nt4-host-review/`.

## Ograniczenie obecnego testu HID

`boot_menu.py` dodaje `usb-kbd` i `usb-mouse`, lecz pozostawia domyślny
kontroler PS/2: zewnętrzna maszyna używa `-machine q35` bez `i8042=off`.
Wysyłanie klawiszy przez `sendkey` i ruchu przez `input-send-event` nie
nazywa docelowego urządzenia. Sama odpowiedź pulpitu po odłączeniu i
ponownym dodaniu urządzenia USB nie wyklucza zapasowej ścieżki PS/2.

Bez uruchamiania VM sprawdzono pomoc lokalnego QEMU:
`-machine q35,help` podaje `i8042=<bool>` — włącza/wyłącza emulację
kontrolera Intel 8042 PS/2. Właściciel wspólnego testera otrzymał uwagę,
aby w przyszłym fixture USB wyłączyć i8042 i zapisać to w metadanych.
Nie zmieniano już zakolejkowanego r16. Jego wynik trzeba ocenić z tym
ograniczeniem, jeśli nadal ma domyślną ścieżkę PS/2.

## Kolejne rozstrzygające kroki

1. Po powiadomieniu o zakończeniu r16 odczytać jego wynik i wyłącznie
   zanonimizowane `native-text-evidence`. Kolektor czyta zatrzymany FAT16
   C: tylko do odczytu, LBA 63. Dopuszcza SETUPLOG, SETUPERR, SETUPACT i
   POST.LOG; rzutuje do ASCII i usuwa klucze oraz ciągi co najmniej trzech
   cyfr jeszcze w gościu, przed transportem. Host ponownie waliduje treść.
   Nie obchodzić ochrony kluczy i nie przechwytywać nieznanego Setupu.
2. Jeżeli brakuje POST.LOG, badać etap natywnego GUI Setupu na podstawie
   logów; nie oceniać sterowników, których POST jeszcze nie zainstalował.
   Jeżeli POST.LOG istnieje, ustalić ostatni wykonany krok, w tym uruchomienie
   SP6a i mechanizm starego polskiego self-extractora bez `-x`.
3. Po osiągnięciu zweryfikowanego pulpitu wykonać osobny test z wyłączonym
   i8042 i dokładnie wskazanym HID 1.3. W edytorze wpisać tekst kontrolny,
   odłączyć i ponownie dodać wyłącznie własny `coveragekbd`, potem dopisać
   drugi tekst. Dla `coveragepointer` wykonać analogiczny reconnect oraz
   widoczny ruch i kliknięcie. Zapisać jawne akcje operatora i rezultat po
   każdej ukończonej akcji; nie wykonywać cyklicznych zrzutów postępu.
4. Sieć QEMU oceniać osobno na 82576 `8086:10C9` (`igb`). Helper LAN celowo
   odkłada autostart w VM, więc test musi jawnie uruchomić dokładnie
   wystagedowany logger, np. `/once /nodbg /nohook /nodisk /out
   C:\USOS\NT4\USABILITY.TXT`. Nowy fixture musi wskazać dokładną wersję
   loggera i sterownika. Rejestr z EnableDHCP jest konfiguracją/śladem
   dzierżawy; wymagane są rzeczywiste wyniki ICMP bramy i DNS w logu.
5. Dopiero oddzielny test fizycznego X470 może potwierdzić I211
   `8086:1539`, jego IRQ/tryb polling i pierwszy pulpit sprzętowy. QEMU
   82576 nie weryfikuje tych zachowań. START.TXT/HOTPLUG.TXT wymagają
   osobnego, spójnego fixture MSC i nie należą do testu samego HID 1.3.

Nie stwierdzono obecnie uzasadnienia dla kolejnej zmiany kodu sterownika
sieci lub USB. Najbliższy brakujący dowód dotyczy natywnego Setupu, a
następnie testu HID bez alternatywnego kontrolera PS/2.

## Uzupełnienie po przeglądzie kolektora

W niezależnej kopii dwóch plików kolektora z `macierz-windows` przygotowano
patch jawnych statusów czterech logów: `exported`, `empty`, `unavailable`,
`too-large`. Nieudany mcopy nie jest dowodem nieistnienia pliku. Same
statusy lub puste logi dają `no-native-text-exported`, a metadane wskazują
rzeczywiste niepuste logi. Zachowano sanitizację w gościu przed transportem
i dokładną allowlistę. Jeden prefiks tar `./` jest normalizowany w jednym
miejscu; kolejne prefiksy, kolizje, linki i traversal są odrzucane.

Autor wykonał 13 testów skupionych na kolektorze, wszystkie PASS, w tym
rzeczywistą funkcję shell gościa ze sztucznymi odczytami. Właściciel głównego
testera przejrzał i zintegrował patch jako `e0fac76d`, a następnie zgłosił
72/72 PASS zestawu coverage. Te 72 testy są osobnym zestawem od 62 testów
hostowych sieci opisanych wyżej. R16 załaduje kolektor po zakończeniu VM;
aktywna maszyna nie została zmieniona. Poprzedni repack main już usuwał
`./`, więc przegląd nie dowiódł istniejącej awarii prefiksu podczas pracy VM.

Właściciel testera dodał też przyszły tryb `--usb-only-input`, commit
`82e7eaf1`, z `q35,i8042=off`, sprawdzaniem konfliktu z PS/2 przed fixture
i jawną metryką wyniku. Obecny R16 zachował dotychczasowy plan. Raport
zadaniowy z pełną analizą ograniczeń sanitizera i proponowanego preflight
klucza: `Documents/Codex/zadania/2026-10-21-nt4-usability-RAPORT.md`.


## Zakończony R16 i odzyskanie transportu

Po pasywnym powiadomieniu `cleanup.json` odczytano zakończony wynik R16.
Próba zgłosiła `Preparation stopped` po około 4057 s (całość 4060 s), bez
potwierdzenia pierwszego logowania. QEMU zakończono przez QMP; obrazy testu
usunięto. Nie przechwytywano ani nie otwierano niezweryfikowanego ekranu
prywatnego Setupu. R16 nie obejmował nowego loggera 54282e85 i miał PS/2.

Pierwotna kolekcja tekstowa zakończyła się błędem transportu `Excess data
after padding`. Zachowany serial kolektora w G: zawierał jedną pełną ramkę
oraz dokładnie dwa znane echa BusyBox ash: zapytanie kursora przy komendzie
base64 i skrócony fragment `VERAGE_E` przed echem END. Oryginalny błąd
odtworzono, a transport odzyskano bez trybu pobłażliwego base64 i bez
obcinania na pierwszym padding. Nieznane linie, inne komendy, podwójne
ramki i doklejone drugie archiwum są odrzucane. Oryginał pozostał niezmieniony.

Po pełnej walidacji allowlist i sanitizacji host przyjął archiwum 238 B.
SHA-256 serialu: `8b05063892e4ad5b5591b5a0da1ddd0d639e440ba75585a17221811a16913417`;
archiwum: `fd5490dc185d03b14fdacdb78480ed4be72149277e1e8bc8f4325e76169c1119`.

| Log | Status |
| --- | --- |
| SETUPLOG.TXT | empty |
| SETUPERR.LOG | unavailable |
| SETUPACT.LOG | unavailable |
| POST.LOG | unavailable |

`actual_native_logs=[]`, `native_logs_read=false`. Nie ma niepustego
natywnego tekstu Setupu ani dowodu jego konkretnej przyczyny. `unavailable`
oznacza nieudany odczyt, bez twierdzenia o istnieniu pliku. Potwierdzona
statycznie luka UTC nie jest przez to potwierdzoną przyczyną zatrzymania R16.

[Wynik odzyskania i zachowane źródło](<C:/Users/ASRock/usos-work/nt4-net/artifacts/nt4-transport-review/r16-recovered/collection.json>)
wiąże wszystkie hashe. [Patch dekodera do przeglądu](<C:/Users/ASRock/usos-work/nt4-net/artifacts/nt4-transport-review/strict-transport-echo.patch>)
ma 6 testów transportu PASS oraz 13 testów NT4 text PASS. Poprzedni patch
statusów e0fac76d miał 13 focused PASS i pełne 72 testy roota PASS;
nie przypisuje się tych 72 testów nowemu patchowi bez nowego wyniku roota.

## Gotowy cache i wariant ze ścisłym DNS

Na polecenie właściciela przygotowano nowy, oddzielny baseline
`G:\USOS-Kolekcja\_assets\B261020-200536-968CCBE8-nt4-hid13-net542-utc`.
Initrd SHA-256: `e71de996f25f3e25a65f97debb9caba82609eaa300250d27be6fbd1770edeff4`.
Zmiany obejmują dokładnie cztery własne wpisy: osiem linii kopiowania i
readback loggera w aktualnym skrypcie cache, dwie linie UTC PL/EN z e2a0d6a9,
USOSLANNT.EXE oraz USOSLOG.EXE z 54282e85. Nie podmieniono całych skryptów
starszą wersją. Wszystkie 824 inne wpisy mają identyczne bajty, tryby i
symlinki, w tym własne HID 1.3, NDIS4, Storage i LogFile. Brak domieszki MSC.
SP6a PL znajduje się wyłącznie w dozwolonym cache, z przypiętym hashem
`a3306f0bc93d1d4709ab784ecd8aebd1a162c8249a219a9e078d1a4a91260542`.
[Manifest, mapy CPIO i ścisłe hunki](<C:/Users/ASRock/usos-work/nt4-net/artifacts/nt4-coherent-cache-review/cache-manifest.json>)
umożliwiają przegląd.

Przegląd loggera 54282e85 wykazał, że samo `resolved` mogło pochodzić z
niedopasowanej odpowiedzi DNS. Dlatego na polecenie roota utworzono drugi,
mały overlay, bez zmian wspólnych źródeł loggera NT4/9x:
`G:\USOS-Kolekcja\_assets\B261020-200536-968CCBE8-nt4-hid13-netdns-utc`.
Initrd SHA-256: `932bb19a66a9b1807f2658e73d010aa74bbc8fe5521d2881e7cf654dd2efd8be`.
Zastępuje wyłącznie jeden wpis USOSLOG.EXE samodzielnym, odtwarzalnym
wariantem z ec8d61d1; pozostałe 827 wpisów zachowano bitowo wraz z trybami
i dowiązaniami. Hash EXE:
`ff2585043a882065f9598628ac31afdaba356a3d91f3e55d93a36e313e3983b7`.

Wszystkie 7 hashów źródeł i zgodność z drugim przypiętym buildem są
potwierdzone. PE 3.10 GUI ma 71 importów; wszystkie importy z łańcuchami
forwarderów oraz 16 wymaganych dynamicznych API WSOCK32/ICMP.DLL znaleziono
w oryginalnych NT4 PL i Enterprise EN CD. Oryginalne binaria były tylko w RAM.
To dowód dostępności eksportów, nie runtime ani ABI PASS.
[Audyt importów i źródeł](<C:/Users/ASRock/usos-work/nt4-net/artifacts/nt4-strict-logger-review/original-nt4-imports.json>)
wiąże nośniki i hashe. Rzeczywisty parser C przeszedł 7 testów PASS,
w tym 1500 deterministycznych mutacji. Dopasowuje peer/IP/port, ID,
QR/opcode/rcode/TC, pytanie A/IN i łańcuch odpowiedzi; dopiero wtedy
`DNS PASS dns_match=1` może być dowodem. Dodatkowo wykonano 6 kontroli
składni skryptów i faktycznych wyników UTC/GMT PL/EN z finalnego cache.

[Konkretny plan instalacji](<C:/Users/ASRock/usos-work/nt4-net/artifacts/nt4-coherent-cache-review/nt4-hid13-dns-utc-candidate01.json>)
i [argv oraz kryteria odbioru](<C:/Users/ASRock/usos-work/nt4-net/artifacts/nt4-coherent-cache-review/launch-review.json>)
są gotowe do przeglądu roota. Plan ma jawny first_logon, dokładny logger
na własnym CD obserwatora, USB-only/i8042 off, igb, świeży cel i SP6a.
Żadnej nowej VM nie uruchomiono. Root przydziela RAM i kolejność.

Do ukończenia nadal wymagane są: rzeczywisty pulpit NT4, klawiatura i mysz
przed i po reconnect, aktualna dzierżawa DHCP oraz zgodne z nią ICMP i DNS
w tym samym gościu. Sam marker, rejestr DHCP, HTTP i start helpera nie są
PASS. Należy zebrać własny USABILITY.TXT i natywne ipconfig /all przed
usunięciem celu po sukcesie. Obecny kolektor awarii NT4 nie zbiera tych
logów po sukcesie. Fizyczny X470/I211 pozostaje osobnym nieprzetestowanym
zakresem; żaden z opisanych testów hostowych go nie zastępuje.


## Prywatna polityka sukcesowej kolekcji NT4 — gotowa do przeglądu

Root zintegrował poprawkę ścisłego transportu w 41078de2; pełna suite
coverage ma 75 testów PASS. Następnie przygotowano w odrębnej kopii
[patch prywatnej polityki NT4](<C:/Users/ASRock/usos-work/nt4-net/artifacts/nt4-success-review/nt4-private-success-policy.patch>)
bez edycji aktywnego kodu. Patch ma sześć plików i aplikuje się na
41078de2; rezultat próbnego zastosowania jest identyczny z kopią roboczą.
11 testów nowej polityki i 17 regresji PASS obejmują faktyczną ścieżkę
shell filtr → tar → base64 → ścisły walidator, syntetyczne klucze,
niepoprawne archiwa, bramę first-logon i korelację DHCP. Jest to wynik hosta.

- Zakończony cel jest otwierany tylko do odczytu, po faktycznym znaczniku
  logowania prywatnego NT4 z dokładnie przypiętym loggerem. Sama granica
  przygotowanego dysku nie zezwala na sukcesową kolekcję.
- Gość czyta wyłącznie `C:\USOS\Coverage\USABILITY.TXT`,
  `C:\USOS\NT4\USABILITY.TXT` i własny `usosnet4.sys` do weryfikacji
  dokładnego hasha. Każdy odczyt logu jest ograniczony do 1 MiB, eksport
  do 64 KiB i 128 linii. Statusy odczytów są jawne.
- Przed transportem gość redaguje kompletne formaty kluczy i przyjmuje
  wyłącznie zamkniętą gramatykę ASCII linii ICMP, DNS oraz resolvera.
  Nie eksportuje sekcji rejestru/procesów, HTTP, hexdumpów, pełnych logów,
  odpowiedzi, hive ani obrazów ekranu. Adresy IP pozostają użyteczne.
  Host ponawia walidację i odrzuca całe archiwum przed zapisem w razie
  rozbieżności, także drugi strumień gzip/tar.
- Osobna polityka NT4 mirror przyjmuje tylko ramki DHCP pinowanej,
  wirtualnej karty igb po rzeczywistym first-logon. Wszystkie ramki
  wcześniejsze oraz inne protokoły są odrzucane bez przechowywania.
  Odbiornik zachowuje limit 8 MiB i opróżnia kanał po jego osiągnięciu.
- Własny observer jedynie kopiuje `TESTNET.CMD`. Operator uruchamia go
  jawnie po ocenie pulpitu/HID: native `ipconfig /release`, `/renew`,
  następnie dokładny logger. Domyślne zachowanie observera innych testów
  zachowano. Test odnowienia i log powstają po bramie logowania.
- DHCP wymaga pełnego DORA z tym samym XID, serwerem i adresem dzierżawy.
  Z tym dowodem muszą zgadzać się router/DNS rzeczywistego loggera, jego
  `echo_match=1`, `dns_match=1` i hash sterownika. Sam rejestr DHCP ani
  resolver/HTTP nie wystarczą. Pole `installed_runtime_pass` pozostaje
  fałszywe: pulpit i HID wymagają oddzielnej oceny.

[Metadane polityki i testów](<C:/Users/ASRock/usos-work/nt4-net/artifacts/nt4-success-review/review-result.json>)
wiążą dokładny zakres. Plan candidate01 zawiera wymagane trzy jawne flagi;
nie uruchomiono VM. Root przydzieli RAM i kolejność po przeglądzie.

Końcowy cache HID 1.3 nie zawiera MSC. Po pulpicie, HID i LAN potrzebny
będzie odrębny test zamrożonego, niezmienionego MSC z feat/nt4-usb-sticks.
Nie łączy się go ze źródłami hubów i nie przypisuje wspólnego PASS.


## Aktualna wersja hooka, transportu i planu pierwszej instalacji

Przegląd ujawnił ograniczenia starego planu: produkcyjny `user_script` nie
obsługuje NT4, DONE.REG wyłącza ATAPI, a NT4 CMD nie obsługuje COPY /Y.
Dlatego sam observer CD nie dawał poprawnego testu logowania. Ostateczna
propozycja ma własny, testowy hook z plikami na celu; domyślna ścieżka CD
innych systemów pozostała niezmieniona.

[Finalny patch na 41078de2](<C:/Users/ASRock/usos-work/nt4-net/artifacts/nt4-success-review/nt4-private-success-final.patch>)
składa się z czterech oddzielnie przeglądalnych poprawek wymienionych w
[manifestcie przeglądu](<C:/Users/ASRock/usos-work/nt4-net/artifacts/nt4-success-review/final-review-result.json>).
Wersje apply-check i byte-match są poprawne. Ostateczny helper GUI ma SHA
`37e7a0f69846d9bab18a718f7d66c3fd937f0f35913d2b0eb22f2d7ce4eae0e9`;
dwa świeże buildy 04/05 są identyczne. PE 4.00 GUI ma 23 importy, zgodne
z eksportami i forwarderami oryginalnych NT4 PL/EN. Wcześniejszy pin 5fb8
jest zastąpiony.

Hook powstaje wyłącznie w prywatnym fixture na podstawie aktualnych
skryptów finalnego cache. POST po SP6a/DONE.REG rejestruje testowe RunOnce
oraz idempotentny Run. Dopiero po powrocie wewnętrznego QEMU i udanych
kontrolach SP6a/status=0 w nt4_vm_finish powstaje ARMED.TXT, przed sync i
unmount. GUI helper przy natywnym logowaniu sprawdza ARM i staging, usuwa
oba własne hooki i ARM, uruchamia FIRSTLO ukrycie przez DETACHED_PROCESS i
SW_HIDE oraz blokująco czeka na kod zakończenia. Błędy mają stały status;
przed ARM ani przy błędzie przygotowania nie powstaje token. Duplikat
uruchomienia bez ARM zachowuje READY, TESTNET_DONE i wcześniejsze błędy.

Operator po ocenie pulpitu uruchamia `C:\USOS\Coverage\NT4OBS.EXE /testnet`.
Helper dopiero po READY ukrycie wykonuje TESTNET (native release/renew i
logger), czeka na zakończenie i zapisuje TESTNET_DONE albo błąd. Token nadal
oznacza logowanie, nie LAN PASS. Kolektor dopuszcza dodatkowo wyłącznie
zamknięty enum z własnego OBSERVER.STATUS; nie eksportuje żadnej innej
zawartości tego pliku. Do korelacji sieci wymaga TESTNET_DONE.

Testy końcowe hosta: 11 polityki kolektora PASS, 10 obserwatora PASS i
6 FIN/RST PASS. Test obserwatora wykonuje rzeczywisty kod C dwa razy na
tym samym kontekście: oba hooki i ARM są usunięte raz, token pojawia się
raz, READY/DONE oraz błąd pozostają zachowane. Testy transportu używają
rzeczywistych połączeń localhost. Znany reset/WinError64 jest akceptowany
wyłącznie między ramkami, gdy bufor nagłówka jest pusty, shutdown został
oznaczony przed QMP quit, a końcowy wynik to QMP quit/rc0. Częściowy
nagłówek lub payload oraz wcześniejszy reset pozostają błędami. Nie nadaje
się historycznemu R18b PASS wstecz bez dowodu pozycji jego błędu.

Root przekazał potwierdzony wynik pary NT351: i8042 OFF zatrzymuje system
na NTDETECT, ON pozwala dojść do pulpitu. Nie przenosi się tego jako
przyczyny R16. Zgodnie z decyzją roota pierwszy nowy NT4 ma jawnie
`usb_only_input:false`, `ps2_input:true`, i8042 ON. Tag planu to
`nt4-sp6a-desktop-net-ps2-candidate01`. Zakres tej próby to rzeczywisty
pulpit i LAN; samo umieszczenie HID 1.3 w cache nie otrzymuje HID PASS.

[Plan i zapis zakresu](<C:/Users/ASRock/usos-work/nt4-net/artifacts/nt4-coherent-cache-review/launch-review.json>)
wymagają od roota zachowania targetu przez dokładny hardlink w tym samym
G:\USOS-Kolekcja\_vm przed finish/cleanup, z użyciem powiadomienia o pliku.
Późniejszy test HID użyje osobnego startu zachowanego celu z dowodem
wyeliminowania PS/2 w gościu albo hardware OFF. MSC pozostaje odrębną,
zamrożoną próbą. Autor nadal nie uruchomił nowej VM ani nie zmienił
sterowników/hubów; żadnego runtime PASS nie przypisano hostowym testom.


## Candidate01 wykonany: błąd fixture przed startem Windows

Root zintegrował końcową politykę jako 450b8bd7 i potwierdził 102 testy
coverage PASS (28.719 s). Zgodnie z przydziałem uruchomiono dokładny
launch-review argv z TTY 33469 i zwykłym guardem, bez obchodzenia go lub
ponawiania odczytu RAM. Próba miała PS/2 i i8042 ON; zakres desktop+LAN.

Przed startem uzbrojono dwa oddzielne, jednorazowe ReadDirectoryChangesW.
Listener retention (72256) zareagował na utworzenie dokładnego target.qcow2,
utworzył target-retained.qcow2 przez CreateHardLinkW i porównał tożsamość
metadanych, bez otwarcia/odczytu zawartości aktywnego obrazu. Listener
endpoint/cleanup (87408) zakończył się dopiero po cleanup.json. Cleanup
usunął pierwotny target; zachowany link ma 334954496 B i jeden link po
usunięciu oryginalnej nazwy. To niedokończony staging, nie zainstalowany NT4.

[Końcowy wynik](<C:/Users/ASRock/usos-work/macierz-windows/artifacts/coverage/vm/nt4-sp6a-desktop-net-ps2-candidate01/result.json>)
wykazuje Preparation stopped po 214.75 s, cały boot 217.94 s,
first_logon_observed=false i zero ramek sieciowych. Zwykły QMP quit/rc0
zakończył VM; znany boundary WinError64 został poprawnie sklasyfikowany
jako kontrolowane zamknięcie, bez błędu capture. ASSESS_ENDPOINT/rc0 jest
wynikiem harnessu, nie oceną Windows. Nie powstał endpoint.png; ochrony
prywatnego Setupu nie osłabiono ani nie otwarto nieznanego ekranu.

Końcowy serial USOS jednoznacznie wskazał wcześniejszy błąd fixture:
cp nie znalazł /usr/lib/usos/coverage-nt4/FIRSTLO.CMD, potem zatrzymano
coverage script readback. CPIO zawierało pliki nowego katalogu, lecz nie
jego rekord. Kernel initramfs nie tworzy automatycznie brakujących
katalogów nadrzędnych. Nie wystartował wewnętrzny Windows, więc ten wynik
nie diagnozuje NT4 Setup, HID, LAN ani sterownika.

[Wąski patch](<C:/Users/ASRock/usos-work/nt4-net/artifacts/nt4-success-review/candidate01-cpio-parent.patch>)
dodaje rekord katalogu 040755 przed czterema plikami, bez zmian cache,
helpera, driverów czy hubów. 11 focused observer tests PASS (27.943 s).
Nowy test czyta rzeczywiście serializowany newc, wymaga rodzica przed
każdym plikiem i rozpoznaje poprawny typ katalogu. Kontrfaktycznie usunięty
rekord odtwarza dokładnie brak rodzica przed FIRSTLO.CMD.

Kolektor native-text zakończył swój readonly run, lecz interaktywny ash
wstawił fragment własnego echo VERAGE_E po pierwszych 76 znakach base64.
Surowego serialu nie zmieniono. Jednorazowe odzyskanie przypięto do jego
SHA256 e5ae14042b6b370b257bc69aa7f43afda14a7909f96277d80b9acb2c4c01c6a6,
wymagało jedynej pełnej ramki i usunęło tylko ten dokładny znany fragment.
Zachowano canonical base64, CRC i EOF pojedynczego gzip, pojedynczy tar
bez końcowych danych oraz pierwotny allowlist/status validator hosta.
Test negatywny odrzucił doklejone drugie archiwum; automatycznego decoder
nie rozszerzono. Root bada osobno wyłączenie echo/promptów przed transportem.

[Odzyskany wynik kolektora](<C:/Users/ASRock/usos-work/nt4-net/artifacts/nt4-success-review/candidate01-recovered-native-text/collection.json>)
ma tylko collection-state.txt: wszystkie cztery logi unavailable,
actual_native_logs=[], native_logs_read=false. Nie dowodzi to nieistnienia
plików; nic z natywnych logów nie odczytano. Archiwum ma 206 B i SHA256
eff7442fd558c71ca260704efa957a833f2b6540092e63b2c8c7cd13ddbd47f0.

Aktualna ocena: hostowe polityki/importy/buildy opisane wyżej PASS;
Windows desktop, DHCP, brama, DNS, USB/HID reconnect, MSC i fizyczny
sprzęt nadal bez PASS. Candidate01 ma konkretny błąd fixture i zakończone
wszystkie własne procesy. Kolejna VM wymaga odrębnego przydziału roota.
