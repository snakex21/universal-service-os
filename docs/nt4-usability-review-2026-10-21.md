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


## Candidate02: przydzielony start i niezależny audyt klas NT351

Root zintegrował poprawkę rodzica CPIO oraz serial_shell.wrap dla czterech
kolektorów jako 015ddddf; potwierdził 105 testów coverage PASS. Rzeczywisty
syntetyczny Linux QEMU wykazał, że samo stty/PS1 nie wystarcza; finalny
exec /bin/sh z quoted heredoc przeniósł dokładnie 24603 B. Zintegrowany
wariant również przeszedł próbę (8.205 s). Decoder pozostał ścisły.

Po wyraźnym przydziale uruchomiono candidate02 w TTY 85872. Plan zmienia
wyłącznie tag względem01, zachowując cache/profile/SP6a/helper i PS/2.
Nowe jednorazowe listenery retention76687 i endpoint/cleanup92035 uzbrojono
przed startem; zwykły guard nie był obchodzony. Retention potwierdził
utworzenie i tożsamość hardlinku bez odczytu zawartości aktywnego celu.
Nie uruchamiano niedokończonego retained01. W chwili tej aktualizacji
oczekuje się pasywnie na endpoint/cleanup; desktop/LAN nie dostały PASS.

W tym czasie wykonano uzgodniony, niezależny read-only audyt oryginalnych
kbdclass/mouclass NT351. Rozpakowane binaria pozostawały wyłącznie w RAM;
oryginalne hashe zgadzają się z wcześniejszym audytem NT3. Własne źródła
usosusb są identyczne z frozen f28a3fd8 i nie zostały zmienione.

[Przegląd kontraktu klas](<C:/Users/ASRock/usos-work/nt4-net/artifacts/nt4-success-review/nt351-class-contract-review.json>)
wykazuje DeviceMap query bez zależności od nazwy dostawcy i8042prt:
callback liczy wartości, potem klasy otwierają kolejne KeyboardPortN lub
PointerPortN. MaximumPortsServiced ma default1; pętla jest ograniczona
przez min(parametr, liczba wartości mapy), od indeksu0. ConnectMultiplePorts
sam nie zwiększa tego limitu. Rzeczywista wartość w badanej instalacji
NT351 pozostaje do sprawdzenia przez prowadzącego tamten runtime.

CONNECT używa Internal=1, METHOD_NEITHER, wejścia8B z dwoma wskaźnikami;
kody B0203/F0203 oraz ENABLE/DISABLE B0803/B1003/F0803/F1003 zgadzają się
z WDK i dispatch frozenUSB. Callback RVA70a obu klas ma cztery argumenty
i RET10. Nie znaleziono statycznej niezgodności tego kontraktu; audyt nie
potwierdza rzeczywistego CONNECT, ENABLE ani dostarczania zdarzeń HID.
Wyniki z RVA i ograniczonymi instrukcjami przekazano rootowi i agentowi NT3.


Korekta na podstawie rzeczywistego readback przekazanego przez roota:
Readback R18e ma MaximumPortsServiced=3 dla obu klas i ConnectMultiplePorts=1/1; R18f dziedziczy te wartości bez zmian.
Domyślny limit1 jest faktem oryginalnych binariów, lecz nie wyjaśnia tego
konkretnego gościa. Nie przygotowano ani nie wprowadzono poprawki limitu.
Oddzielna próba NT3 zmienia tylko i8042prt Start1 na4; jej wynik jest
prowadzony przez roota/NT3 i nie jest przypisywany do trwającego NT4.


## Candidate02: zakończony stall GUI Setup, zachowany cel do diagnozy

Oczekiwanie zakończyło powiadomienie cleanup; TTY85872 oraz oba jednorazowe
listenery76687/92035 zakończyły się. Runner startował z015ddddf. Harness
rc0/ASSESS_ENDPOINT nie oznacza sukcesu Windows. Preparation stopped po
4407.25s, całość4409.87s. Wewnętrzny instalator zakończył się rc3 po4204s:
brak zapisu903s na drugim starcie. Konkretna strona pozostaje nieznana.

Nie zaobserwowano pierwszego logowania ani pulpitu; nie zapisano endpointu
i nie otwarto nieznanego ekranu prywatnego Setupu. Przed logowaniem
odrzucono11ramek, capture zachował0; pcap zawiera sam nagłówek24B. Nie
wykonano operatora /testnet, więc DHCP/brama/DNS nie mają PASS. Zakres
PS/2 nie obejmuje HID/reconnect/MSC; fizyczny sprzęt nadal bez oceny.

Retencja utworzyła hardlink na zdarzeniu utworzenia dokładnego targetu,
bez odczytu aktywnego obrazu. Po cleanup zachowany target-retained.qcow2
ma430571520B. Jest to niedokończony Setup, nie gotowy pulpit. Oryginalnej
nazwy target.qcow2 już nie ma; nie wystartowano retained01 ani nowej próby.

Kolektor tekstu tym razem zakończył automatyczny transport po naprawie
quoted-heredoc: SETUPLOG empty, SETUPERR/SETUPACT/POST unavailable,
actual_native_logs=[], native_logs_read=false. Unavailable oznacza
nieudany odczyt, nie dowód braku pliku. Zakończony redacted transport
ponownie przeszedł aktualny ścisły validator: canonical base64, pojedynczy
gzip zCRC/EOF, pojedynczy tar z wyłącznie zerami po terminatorze, allowlist
i statusy. Nie tworzono nowej VM ani nie zmieniono surowego evidence.

Startowy015ddddf oraz późniejszą weryfikację rozdzielono w metadanych.
Nie przechwycono wersji modułu przy jego oryginalnym załadowaniu, więc
nie przypisuje się historycznemu runtime aktualnego verifiera. Wąski
patch integralności d422dc5d...83be6f root zastosował po review; mój
izolowany focused run:45PASS/1skip (opcjonalny pin NT35),46testówłącznie.
Obejmuje realne negatywne przypadki drugiego gzip/tar, CRC, obcięcia i
bomby ekspansji w czterech kolektorach. Oceny historyczne bez zmian.

Priorytet po fail02: readonly odczyt zachowanego qcow2 i wybranych hive
wyłącznie wRAM, bez raw-convert/mount/exportu plików Microsoftu. Obie
hive mają poprawny checksum i równe sequence. SYSTEM nadal oznacza
Setup jako aktywny (SystemSetupInProgress1/RestartSetup1); CmdLine jest
klasyfikowane wyłącznie jako GUI_SETUP_NEWSETUP. ProductId/owner/org
są niepuste i inne od oryginalnego SOFTWARE template; oryginał nie ma
ProductId. Żadnej wartości, długości ani hasha tych danych nie zapisano.
Sama obecność nie jest jeszcze dowodem przejścia prywatnej strony: trwa
audyt oryginalnego write-site/porządku GUI i warunku restartu. Bez tego
nie dopuszcza się zrzutu ekranu. Kolejna czynność będzie krótką diagnozą
zachowanego celu albo klasyfikatorem zwracającym tylko enum, bez kolejnej
ślepej pełnej instalacji.


## Doprecyzowanie diagnozy zachowanego Setup02 i integralności

Root zintegrował wspólną kontrolę gzip/tar jako16970e7c. Pełne122testy
coverage PASS (31.656s), z rzeczywistym pinem NT35 i zero skip. Ukończony
BusyBox transport NT351 R18f przeszedł dodatkowy metadata-only replay;
nie zmieniono historycznych ocen ani hash guardów.

Oryginalny SYSSETUP PL bfd24b69...759e9 ma PSP40B wRVA29bf8:
template102 (instalacja sieci), callback1d114. Przy WM_NOTIFY oraz
PSN_WIZNEXT(-207) wywołuje18730→14a58→14422→RegSetValueExW(ProductId).
Pozwala to powiązać dane zapisane w zakończonym target02 z natywnym
postępem GUI. Nie dowodzi widocznej strony po osobnym wznowieniu; metadane
product-write-order jawnie nie zezwalają na screenshot na tej podstawie.

Przygotowany obserwator używa lokalnego VNC do jednego framebuffer
transaction wRAM po300s. Bitmapa i tekst WinRT OCR pozostają wyłącznie
wRAM/anonimowym stdin pipe; wynik to zamknięty enum, bez wartości/hashy
danych produktu i bez framefile. OCR nie daje automatycznego zezwolenia
na zapis ekranu. Nie podaje klucza ani żadnych klawiszy. Każdy diagnostic
boot korzysta z nowego overlay, bazowy preserved02 jest backing read-only.

Diag01 zakończyła się CLASSIFIER_ERROR/ValueError i nie ustaliła strony.
Mój adapter nie negocjował QMP capabilities, więc quit zakończył fallback
terminate/rc1; poprawiono to przed kolejnym startem. Paused/noOS32MiB
fixture potwierdził RFB3.8,640×480 wyłącznieRAM i QMPquit/rc0.
Diag02 również nie ustaliła strony: RFB_NO_COMPLETE_FRAME,300.49s,
QMPquit/rc0. Nie ujawniono żadnego obrazu ani tekstu. To ograniczenia
obserwatora, nie nowe Windows/USB/LAN FAIL.

NoOS BIOS fixture po cont rzeczywiście odtworzył resize→raw720×400 i
QMPquit/rc0. Nowy localhost test pięciu queued DesktopResize wykazał,
że limit4 odpowiedzi odcina poprawną transakcję; bounded16 przechodzi.
Nie przypisuje się tego z pewnością do historycznej diag02, która nie
zachowała response enum. Host5/5 testów klasyfikatora syntetycznego oraz
5/5 testów rzeczywistego localhost RFB PASS. Wariant03 dodaje wyłącznie
closed failure/response enums i jeden odczyt końcowy. To kolejna krótka
diagnoza zachowanego obrazu, nie nowa pełna instalacja.


## Ukończone RAM diagnozy03/04 i kanał interaktywny05

Diag03 rzeczywiście uzyskała640×480 i zakończyła kontrolowanym QMPquit
rc0 po303.49s. Szeroki enum PRIVATE_PRODUCT_PAGE zachował ochronę, lecz
nie dowodzi licencji: pasował również do polskiego słowa klucz. Bitmapa
i OCR nie zostały zapisane ani pokazane. Diag04 zwróciła dokładniejsze
PRODUCT_ENTRY_UNSPECIFIED, title WINDOWS_NT_SETUP i tylko sygnały
KEY_LABEL/NETWORK_LABEL/ERROR_WORD. Nie wykryła ID/OEM/rejestracji/formatu
klucza ani Dalej. Nie wysłano Alt+D: taki wynik nie spełnia predykatu Next.
To może być klucz rejestru sieci; nadal nie przypisuje się konkretnego
komunikatu bez dopasowania oryginalnego resource/message-ID.

Osobny preflight porównał wartości tylko wRAM przez zatwierdzony adapter
prywatnego assetu index0. WINNT.SIF,~BT/WINNT.SIF oraz rzeczywisty
WINNT\SYSTEM32\$WINNT$.INF mają pojedynczy UserData/ProductId,
poprawny znany kształt OEM i dokładnie odpowiadają zatwierdzonemu assetowi.
Wszystkie3kopie są zgodne. RegisteredOwner/Organization w SOFTWARE
pasują do odpowiedzi. Nie zapisano wartości, fragmentu, długości ani
hasha klucza; żaden answer/hive nie został wyeksportowany. To wyklucza
błąd keyless znany zR7 oraz zgubienie danych w tym render/copy. SIF sam
nie jest dowodem przejścia natywnej strony.

Oryginalny COMCTL32 PL8a7ad6ca...70c5b ma wdialogu1020 przyciski
'< &Wstecz' i '&Dalej >'. Produkt używa default alt-n. Jest to rzeczywista
różnica mnemonika locale, jednak nie wdrożono poprawki wciemno. Root
upoważnił pojedyncze Alt+D na nowym overlay dopiero po potwierdzeniu
strony Next i zgodności3SIF.

V2 klasyfikatora ma7/7 actual WinRT OCR host PASS, wtym mały640×480tekst
i kontrprzykład Network+OEM. V3 porównuje wyłącznie publiczne oryginalne
resource/message patterns (1183 z7modułów, tekst tylkoRAM) i eksportuje
allowlistedID z zamkniętym rodzajem dopasowania. Test4/4 PASS obejmuje
oryginalny NETCFG5193, rozdzielenie registry error od OEMform, brak
transkryptu przy nieznanym tekście i odrzucanie dowolnych danych hostowo.
Kanał operatora ma3/3 semantic tests PASS: Next wymaga Dalej/brakbłędu/
zgodnych odpowiedzi, ACK wymaga dopasowanego oryginalnegoID, brak
ogólnego wprowadzania klawiszy lub dowolnych zapytań regex.

Root zlecił utrzymanie kolejnego obrazu wyłącznie wRAM oraz kanału
interaktywnego, aby nie bootować ponownie dla każdego pytania. Próba05
wTTY15282 uruchomiła jeden zwykły guard i512MiB, nowy overlay bez
naruszenia preserved02. Po pierwszym odczycie pozostanie kanał zamkniętych
pytań o TEN SAM RAMframe. Żaden wynik OCR nie udziela automatycznie
zezwolenia na screenshot. Nadal brak desktop/LAN/HID/MSC/hardware PASS.


## Zakończona diagnoza 05 i przygotowanie wrappera 06

Próba 05 zakończyła się kontrolowanym QMP quit/rc0 po 957.59 s, bez żadnej
akcji UI. Powtórne zamknięte pytania używały tego samego obrazu w RAM.
Rozszerzony bank 2409 publicznych wzorców i trzy warianty OCR nie dały
żadnego dopasowanego oryginalnego message-ID. Sygnał „klucz” nie rozróżnia
klucza produktu i rejestru, zatem nie wykonano Next/OK. Obraz i OCR zwolniono,
a maszyna nie zajmuje już RAM. To nie jest rozpoznany błąd licencji.

Na nowym własnym overlay przygotowano diagnostyczny NT4PAGE.EXE. Nie
zastępuje setup.exe: zmienia wyłącznie System\Setup\CmdLine na swój wrapper,
który uruchamia dokładne oryginalne `setup -newsetup`, czeka na zakończenie
native child i przekazuje jego rzeczywisty kod wyjścia. Plik SYSTEM jest
zmieniany w RAM; osobne hive ani zasoby Microsoftu nie są eksportowane.
Tymczasowy własny pełny dysk RAW pod G:\USOS-Kolekcja został po weryfikacji
usunięty. Readback potwierdził oczekiwany SYSTEM i własny EXE, niezmienione
setup.exe, SOFTWARE i logger. Porównano każdy pozostały wirtualny bajt;
qemu-img compare całego obrazu również PASS.

Końcowy SHA256 wrappera to
`7c198c04063adfc5a4de230735cda8877208f1e685de59885f267de18f14c4aa`
(32768 B); niezależne build06/build07 są identyczne. Wszystkie 34 importy
potwierdzono w oryginalnych NT4 PL i EN. Odczyt obejmuje wyłącznie tytuły,
STATIC i BUTTON przez bounded WM_GETTEXT/SendMessageTimeoutW: EDIT jest
wykluczony przed wysłaniem wiadomości. Limit wynosi 2 s na kontrolkę i 15 s
łącznie na jeden capture. Porównania z oryginalnymi zasobami odbywają się
w gościu; host dostaje wyłącznie zamknięte publiczne ID i booleany.

19 host tests PASS: 5 semantycznych rzeczywistego kodu C, 4 z oddzielnym
procesem Windows (w tym licznik 0 wiadomości WM_GETTEXT do EDIT i rzeczywisty
hung-control), 6 ścisłego protokołu UART i 4 zamkniętej polityki operatora.
To dowód narzędzia hostowego, nie poprawności Windows. Metadane i źródła:
`artifacts/nt4-success-review/nt4page/host-validation.json` oraz
`nativepage06-preparation.json`. Próba 06 jest diagnostic_only: zachowany
Setup, PS/2, bez NIC i bez interfejsu obrazu ekranu. Nadal brak potwierdzenia
pulpitu/LAN/HID/MSC na NT4 i brak wyników fizycznego sprzętu.


## Wynik wrappera 06 i poprawka niezależna od COM

Próba 06 zakończyła się OBSERVER_ENDPOINT_TIMEOUT po 480.15 s i kontrolowanym
QMP quit/rc0. Nie odebrano publicznych stanów ani ramek, nie wykonano żadnej
akcji. Przyczyna konkretnej strony pozostaje nieustalona. To błąd/ograniczenie
instrumentacji, nie nowy Windows FAIL. Wersja 06 NIE blokowała native child
przy błędzie COM: entry zawsze wywoływało CreateProcess, natomiast observe
pomijało całą obserwację przy niedostępnym COM. Serial Start=2 jest faktem
z zatrzymanej bazy; nie dowodzi samodzielnie przyczyny braku kanału.

Readback po zakończeniu 06 potwierdził zachowany własny EXE oraz przywrócone
CmdLine do dokładnego polecenia native. SYSTEM różni się od bazowego, Setup
nadal ma InProgress=1/RestartSetup=1/SetupType=0, SETUPLOG jest pusty.
Nie wyeksportowano hive ani wartości klucza. Tymczasowy własny dysk RAW
usunięto. Te fakty nie zastępują dowodu uruchomienia wrappera lub strony.

Nowy wrapper zapisuje wyłącznie publiczne identyfikatory i zamknięte stany do
własnego C:\USOS\NT4\NT4PAGE.LOG (CREATE_NEW, WRITE_THROUGH), niezależnie
od COM. Kanały mają jawne booleany, a reader nadaje osobny enum m.in.
FILE_ONLY_COM_UNAVAILABLE. Plik czyta się dopiero po potwierdzonym quit,
w RAM, z dokładnego allowlist path. Nie zapisuje się surowej kopii pliku.
Host odrzuca obce ID, dane niezgodne z ASCII grammar, fragment ramki,
niegotowy sink i dwuznaczny status native launch. Sam native-start bez
pełnej ramki nie daje rozpoznania strony; transport nie klasyfikuje strony
na podstawie samego ogólnego tytułu czy przycisku.

Końcowy build08/build09 ma identyczny SHA256
`9081b76eb870437a7f5ad0c9db2ead95ae19b65d85a1faf45f8f3a3219b7a22e`,
32768 B i komplet 34 importów w oryginalnych PL/EN. 24 host tests PASS:
6 actual-C semantics, 4 cross-process WM_GETTEXT, 6 protokołu, 4 operatora,
4 czytnika pliku. Jawny COM-open-failure test potwierdza uruchomienie native
child i dokładne exit codes 0/19/259/C0000005; drugi test potwierdza pełny
file capture przy braku COM. Nie zmieniano hubów ani sterowników.

Własny overlay nativepage07 jest przygotowany i jeszcze niebootowany;
pełny readback i porównanie innych wirtualnych bajtów PASS. Plan diagnozy:
obserwacja 60 s po native child, jeden endpoint po 150 s od startu, quit,
następnie tylko odczyt własnego pliku. Źródło do review:
`artifacts/nt4-success-review/nt4page/page.c`; metadane
`host-validation-file.json` i `nativepage07-preparation.json`. Nie ma
nowego desktop/LAN/HID/MSC ani hardware PASS.


## Handoff na koniec dnia: bez dalszych VM

Użytkownik kończy pracę; próba 07 NIE została uruchomiona. Żadna własna VM ani
listener 07 nie działa. Sesje 05 i 06 są zakończone. Guard RAM dla 07 jeszcze
nie był wykonywany; zwykły pojedynczy guard jest wymagany dopiero po wznowieniu.

Końcowa poprawka chroni całą ramkę mutexem. Po childexit ustawiany jest stop,
końcowy status czeka na END, sink jest flushowany i zamykany, a oczekiwanie na
observer wynosi najwyżej 1000 ms. Mutex nie obejmuje blokującego ReadFileCOM.
Actual-C test na rzeczywistych wątkach/zdarzeniach wymusza childexit w środku
BEGIN i potwierdza finalny native flag dopiero po END, z zachowaniem exit19.
Doszedł negatywny test odrzucania ramki bez potwierdzonej synchronizacji.
Łącznie 26 host PASS (7 C, 4 cross-process, 6 UART, 4 operator, 5 own-file).

Finalny build10/build11: SHA256
`37e151bf7879431653eae31462d9390acca9ee82262efb529b8b96771518db3e`,
33792 B, wszystkie 37 importów dostępne w oryginalnych NT4 PL i EN.
Finalny niebootowany overlay 07:
`G:\USOS-Kolekcja\_vm\nt4-setup02-nativepage07\final\target.qcow2`.
Pełny readback i porównanie innych wirtualnych bajtów PASS; native Setup,
SOFTWARE i logger niezmienione, tymczasowy własny RAW usunięty. Starszy
niebootowany overlay 07 sprzed synchronizacji pozostaje osobną historią;
przyszły runner wskazuje wyłącznie final/target.qcow2.

Własny snapshot C/headerów i 11 samodzielnych testów hostowych zapisano w
`tools/tests/coverage/nt4page_snapshot/`, z README i verification.json.
To WIP integracji diagnostycznej, nie zmiana aktywnego produktu/driverów.
Pełny zamknięty handoff:
`artifacts/nt4-success-review/nt4page/handoff-2026-10-22.json`.
Po wznowieniu jedyną przygotowaną akcją jest run_nativepage07.py: 150 s,
QMP quit, a dopiero potem odczyt własnego allowlist logu. Aktualnie zakaz startu.
06 transport-timeout nadal nie jest Windows FAIL. Pulpit i LAN NT4 oraz osobne
HID/MSC i sprzęt fizyczny pozostają niepotwierdzone.


## Wznowienie: loader-selected SYSTEM.SAV i ukończone próby07–10

Oryginalny NTLDR PL (SHA256263acfea3d3143a34fa4f2bfbda809898fb87883c1d317a7b52342f6c824748f)
przy Setup/RestartSetup REGDWORD>=1 ładuje WINNT/SYSTEM32/CONFIG/SYSTEM.SAV.
Dowód z oryginalnego kodu: chronione RVA14b00 tworzy ścieżkę config, 14b59/14b65
ładuje SYSTEM, 16a7e/16b48 odczytuje i testuje RestartSetup, 14bcd/14beb wybiera
SYSTEM.SAV. Wybrany SAV ma RestartSetup1 i SetupType1. Pozostałości SYSLINUX.CFG
są nieaktywne: rzeczywisty kod VBR ładuje NTLDR, zgodny bajtowo z oryginalnym CD.
Metadane bez surowych bajtów: nt4page/ntldr-restart-hive-dataflow-v2.json,
base-boot-chain-identity.json i base-vbr-filename-dataflow.json.

Próby06–08 nie zmieniały loader-selected SAV. Brak uruchomienia wrappera był
błędem instrumentacji wrong-hive, nie Windows FAIL ani dowodem problemu klucza.
07:150.36s/QMPquitrc0, 08:150.17s/QMPquitrc0, bez UIactions; własny log niedostępny.
Nie przepisano ich historycznych plików wynikowych. Wczesny model replay legacy
LOG miał trzy errors; wynik zachowano. Poprawione5 testów rozróżniają niezależne
primary/ALT i odrzucają rzeczywiście niezgodną geometrię LOG, bez udawania
potwierdzenia natywnego recovery.

09: na nowym overlay zmieniono wyłącznie CmdLine w SYSTEM.SAV oraz dodano własny
NT4PAGE.EXE. RestartSetup/primary/ALT/LOG i wszystkie inne wirtualne bajty poza
jawnie dozwolonymi zakresami niezmienione; readback/full compare PASS, RAW usunięty.
Jedna zwykła kontrola zasobów,150.17s, QMPquitrc0. Własny public-ID log odczytany
dopiero po quit: native child STARTED, pełna zsynchronizowana ramka, input desktop
attachedYES, FILE_ONLY_COM_UNAVAILABLE. SYSSETUP STR1 to ogólny tytuł; NETSETUP
DIALOG8170slot1 opisuje etap składników sieci. ModalOK pozostaje nierozpoznany:
PUBLIC_ERROR_MATCHfalse, żadnego Next ani ACK. To nie jest konkretny błąd rejestru
ani dowód przejścia Setup. Wszystkie12 zainstalowanych modułów oracle mają hashe
identyczne z oryginalnym PL CD. 5 rzeczywistych SAV dispatch tests i6 adaptera PASS.

10: ten sam natywny Setup/RestartSetup, tylko własny matcher publicznych szablonów
oraz native Serial Start2→1 w wybranym SAV na tym jednym overlay. Zmiana Serial
objęta4 rzeczywistymi testami, readback i pełnym porównaniem pozostałych bajtów.
Default=LKG1/Current0 przed startem; driverSerial Type1, oryginalny serial.sys SHA256
 aebf5f45aab49186182c4f60b2735353abf2856a3d73d8e06fa197b99dfd52ac.
Build12 SHA25666fca64af6d37fe4e14dd54dcf7e9e9aa7fa585529802d401871375e0925745f,
34816B, wszystkie37 importów w oryginalnych PL/EN. 7 testów bounded template C,
ponownie7 lifecycle/EDIT i4 rzeczywiste cross-process WM_GETTEXT PASS;4 operatora
oraz6 exact-path post-quit policy PASS. Parametry szablonów pozostają tylko RAM.

10 uzyskała działający UART i public-ID endpoint105.38s. Ramka nadal pokazuje
wyłącznie ten sam etap NETSETUP i nierozpoznanyOK. Zakończona FINISH/QMPquitrc0
po157.03s, actions=[], bez screenów i bez odczytu EDIT. Aktywnej VM nie zostawiono.
Aktualny zakres jest diagnostyczny: brak NT4 desktop/LAN/HID/MSC/hardware PASS.
Dalszy krok wymaga rozpoznania konkretnego publicznego komunikatu; samo dodanie
transportu nie odblokowało instalatora. Końcowy stan10: nativepage10-runtime/result.json.


## Ukończone11–12: oracle dostępny, modal nadal nierozpoznany

11: nowy bounded RT_MESSAGETABLE parser i NTDLL w tym samym wrapperze.
Oryginalny NTDLL z celu zgodny bajtowo z PL CD. Actual-C parser odczytał oryginalny
KERNEL32 MSG1010 w RAM; testy negatywne i1500 mutacji PASS. Pierwszy test adaptera
miał2 errors typu Python bytearray/ctypes; wynik zachowano, po poprawieniu konwersji
7 tests PASS. Pierwszy test protokołu odrzucał nowe nazwy flag z cyframi; ścisłą
allowlist zachowano, poprawiono klasę znaków i8 tests PASS. Parametry wiadomości
nie są eksportowane. Fragmenty publicznych literałów są diagnostyczne, bez ACK.

11 endpoint104.71s potwierdził ORACLE_MODULES_COMPLETE/ORACLE_MESSAGE1010_READ/
ORACLE_CODEPAGE1250=true oraz UNMATCHED_STATIC_PRESENT=true. Żadnego MSG ani
fragmentu, tylko dotychczasowy tytuł/NETSETUP8170. FINISH/QMPquitrc0, actions=[].
Hipoteza samej niedostępności FormatMessage/NTDLL nie wyjaśnia braku identyfikacji.

Statycznie znaleziono75 pomijanych nazwanych dialogów SETUPDLL, m.in.CRITERR.
12 włącza exactallowlist tych nazw, bez nowych dowolnych ścieżek. Actual-C test
potwierdził named FindResource→parser→publicznyID, unknownresource failclosed.
Build15 ce94990ed569aaeccbb68086c02d3e618eb98f512dfca837dcf21660517b6667,
46080B,38 importów oryginalnychPL/EN PASS. Readback i fullcompare SAVCmdLine/
SerialStart1/ownEXEonly PASS. Endpoint114.66s nie dodał MSG/fragment/namedDialog;
wszystkie trzy oracleflags nadaltrue. FINISH/QMPquitrc0 po174.67s, zeroUIactions.

Snapshot tools/tests/coverage/nt4page_snapshot zawiera aktualne własne źródła,
publiczny katalog samych identyfikatorów i38 samodzielnych hosttests PASS. Nie
uzyskano desktop/LAN/HID/MSC PASS. Dalszy plan zatwierdzony przez root: wąski
QEMU event breakpoint na statycznie ustalonym oryginalnym APIUI, wyłącznie enumAPI,
caller moduł/RVA i numerictemplateID. Bez lpText/EDIT/frame/stosu dowolnych
parametrów ani eksportu RAM. Najpierw synthetic adaptertest, dopiero potem
normalny guard i pojedynczy start diagnostyczny. Nie zaplanowano kolejnej
próby z samą szerszą listą zasobów. Żadna własna VM nie działa po12.


2026-10-22 — konkretna blokada natywnego Setup NT4 (UI event 13–16)

Próby 13–15 zakończyły się kontrolowanym QMP quit/rc0. Rozpoznały wywołanie
MessageBoxW, ale bez przypisania caller do pierwotnej listy modułów; nie są
dowodem błędu Windows ani ukończenia Setup. 16 utrzymała pojedynczy event
paused, bez kolejnych identycznych bootów. LOW16 nie dało unikatowego wyniku.
Ograniczona lista loadera (43 moduły, FS base → TEB → PEB → Ldr, układ
potwierdzony z oryginalnego NTDLL) wskazała TCPCFG.DLL/RVA1154F. Odczytano
BaseDllName tylko unikatowego modułu obejmującego caller, bez FullDllName.
Hash TCPCFG z niezmiennego targetu zgadzał się z oryginalnym PL ISO:
adbda98abbaf38f8272c28c312ffff559f023a8465f68e6f15b1c3cc4d424ad2.

Po odrębnej zgodzie roota wybrany EBP i dokładnie jeden DWORD [EBP+4],
przy udowodnionym helperze11502 i stack delta0x24, dopasowały parent return
11862 do publicznego STR25296 (0x62D0): nieprawidłowy adres IP parametru
instalacji bezobsługowej TCP/IP. Żadnych odczytów lpText, EDIT, dowolnych
parametrów, stack bulk, screenów ani eksportu RAM. Nie wykonano ACK/UI.
16 zamknięta QMP quit/rc0 po555.801s. Callerword pozostał wyłącznie RAM.

Wszystkie trzy SIF niezmiennego candidate02 mają zgodne USOS.TCPIP, znany
placeholder192.0.2.1 i maskę255.255.255.0; inne IP parametry są puste.
Oryginalny validator TCPCFG11562 wymaga pierwszego oktetu1..223, następnych
1..255, więc zero w drugim oktecie odrzuca staging. Poprawka renderera:
198.51.100.1. Końcowe DHCP/POST oraz sterowniki/huby pozostają bez zmian.

Walidacja: real no-OS adapter protected32/CPL3/pushEBP PASS z wcześniejszego
synthetic-protected02, następnie host8 low16 PASS, host8 loader policy PASS,
host3 exact frame-to-resource PASS. Pierwszy fixture loadera miał błędne
syntetyczne offsety; poprawiony przed użyciem na gościu. Actual-code host
regression:4 PASS w Unicorn x86 na oryginalnej funkcji, ograniczone CRT stubs;
stary adres odrzucony, nowy przyjęty, zera/granice/składnia sprawdzone.
Expanded MS bytes pozostają RAM; test standalone używa krótkotrwałego
compressed input wyłącznie w G:\USOS-Kolekcja\_audit\nt4-native-tcpip-test.
Pierwsze uruchomienie standalone oczekiwało SZDD zamiast rzeczywistego CAB;
poprawione na bounded7z→RAM przed końcowym4PASS. Zig test nowego kontraktu
renderera1/1PASS; dwa wcześniejsze wywołania miały zły module root/import
build_info, końcowy entrypoint src/test_nt4_setup_address.zig działa.

Pulpit/LAN/HID/MSC: nadal NIEPOTWIERDZONE. Następna świeża pełna próba USOS
q35/igb jest uzasadniona konkretną naprawą stagingu, nie samym kliknięciem OK.
Fullbuild/new frozen cache i wynik VM zostaną zapisane osobno.
