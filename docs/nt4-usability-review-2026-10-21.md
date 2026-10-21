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
