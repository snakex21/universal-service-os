# NT4: oddzielna kwalifikacja USB MSC/FAT16

Wynik: osobny zainstalowany NT4 MSC/FAT16 PASS dla startowego nośnika,
hotplug, własnego zapisu i odczytu po ponownym włożeniu. Natywne Shutdown,
ekran safe-off i QMP exit0 potwierdzone. LAN, HID na tym sterowniku,
pełny fresh-flow i sprzęt fizyczny pozostają poza tą oceną.

Test `nt4-installed03-usb-msc04` używa zatrzymanego oryginalnego candidate03
(`cf04c232df2dc3bcbc2775c0d31963fd1fc4abd4daf7a2967eba9be1f8af2a21`)
jako rodzica COW. Nie jest potomkiem izolowanego HID01 ani wariantu NET05.
To diagnostyczny cold boot BIOS/q35/AHCI z PS/2, różny od normalnego świeżego
przepływu USOS OVMF/CSM. Nie kwalifikuje LAN, hotplug HID ani sprzętu fizycznego.

## Dokładny zakres przygotowania

Własny zamrożony `USOSUSB.SYS` ma 43648B i SHA256
`3139522926f054946b280c14c962593062817a0ca71170a5aeeb8551a6fab2a1`.
To gotowy kandydat MSC z cache
`B261020-200536-968CCBE8-nt4-msc`, initrd SHA256
`6d1f6740dc7b9cb329e03be7f03cd95a6db489d0a2c33b441d5f98e7f8857778`.
Źródła sterownika/hubów nie zostały zmienione ani przebudowane.

Jedyny zmieniony oryginalny plik to `WINNT/SYSTEM32/DRIVERS/USOSUSB.SYS`.
Jego poprzedni przydział 32768B nie mieścił nowego pliku; PyFatFS przydzielił
drugi klaster wyłącznie dla własnego pliku. Dwa jawne nowe pliki celu to
`USOS/NT4/MSC4TEST.EXE` oraz `USOS/NT4/MSC4TEST.ON`.
Pełna strumieniowa inwentaryzacja potwierdziła identyczną zawartość pozostałych
2051 oryginalnych plików. Pełny SYSTEM pozostał binarnie identyczny:
SHA256 `2d21d5a50281d6330d5292168711a48ce733c523159c7a9d253652b0ad15ac14`,
Select Current/Default 1; i8042prt/usosusb/kbdclass/mouclass Start1,
NDISLoop Start3. PS/2 pozostaje dozwolone w tym teście MSC. Windows zmienił
SYSTEM podczas normalnego runtime; identyczność binarna dotyczy przygotowania,
a stopped readback ponownie potwierdza wyżej wymienione wartości usług.

Porównanie całego zmodyfikowanego raw z COW: `Images are identical`.
Niezależny ponowny odczyt całego COW potwierdził SYSTEM, pliki i inwentaryzację.
38 importów sterownika oraz 14 importów obserwatora rozwiązano względem
rzeczywistych oryginalnych NTOSKRNL/HAL/KERNEL32, czytanych wyłącznie w RAM.
Samodzielnych modułów/hive Microsoft nie eksportowano. Whole-disk scratch
na G usunięto po sprawdzeniu dokładnych własnych ścieżek.

Próba przygotowania01 zatrzymała się przed zapisem na limicie inwentaryzacji:
oryginalny PAGEFILE ma 548405248B. Limit strumieniowego haszowania zwiększono
do mniejszej z 1GiB oraz faktycznej pojemności FAT16, przy niezmienionych
małych limitach odczytu modułów i SYSTEM w RAM. Przygotowanie02 było tylko
próbą offline. Nie uruchomiono dla01/02 VM. Wariant03 dodał poprawny root
volume-label obok BPB i sprawdzenie wyniku CloseHandle obserwatora. Osiągnął
pulpit i odczyt START, ale nie ukończył całej kwalifikacji: własny token COM1
został doklejony do prefiksu BIOS `DSsDSsDSsDSs` bez newline. Ścisły parser
odrzucił wiersz, a runner zakończył się timeoutem i QMP quit, bez nativeShutdown.
Zamknięte `msc03-refusal.json` oraz serial zachowują ten ujemny wynik harnessu.
Wariant04 zmienił tylko framing własnego obserwatora: leading CRLF oraz flush
COM1. Regresja odtwarza rzeczywisty prefiks BIOS; nie rozluźnia dopasowania tokenu.

## Obserwator i nośniki

Własny `MSC4TEST.EXE` 5120B, SHA256
`75cef5e2e8be39b1cdc3d52a0f414464a86cd85fb0513de1139133fc3ac6429e`,
jest aplikacją GUI4.00 bez okna/CRT. Przed operacjami na nośniku wymaga NT4.0,
znacznika obok EXE i jawnego etapu `/startup`, `/hot` lub `/replug`.
Na hoście trzy rzeczywiste uruchomienia odmówiły działania (`REFUSED_OS`).
Log `MSC4LOG.TXT` powstaje obok EXE. COM1 służy wyłącznie testowemu
jednorazowemu sygnałowi zakończenia, uzbrojonemu przed konkretną akcją.
Nie jest to element produktu ani automatyczne oczekiwanie na wolumin.

Obserwator przegląda istniejącą maskę liter tylko raz. Nie zakłada litery
napędu. Wymaga dokładnej etykiety, FAT i prywatnego znacznika; zapisuje tylko
jeden jednoznacznie dopasowany własny wolumin. START.TXT/HOTPLUG.TXT oraz
MSC4VOL.ON odczytano niezależnie przed startem. Oba nośniki mają 64MiB,
MBR typ06/FAT16 oraz zgodną etykietę BPB i katalogu głównego.

Hot nośnik używa nazwanego trwałego `-blockdev`, implementacja wspólnego
fixture z `d62eb0c6`. Usuwane/dodawane jest tylko własne urządzenie USB,
z zachowaniem tego samego backendu i serialu. Starszy `-drive` nie nadaje
się do tej próby replug, gdyż znika wraz z urządzeniem.

Ukończone etapy runtime: natywny Explorer/plik START, podłączenie HOT,
odczyt HOTPLUG, własny ROUNDTRIP przez Write/Flush/Close/Read, odłączenie,
ponowne podłączenie i ponowny odczyt plików. Każdy etap jest jednorazową
akcją z oddzielnym future; nie ma pętli sprawdzania woluminu ani postępu.

Dowody lokalne: `artifacts/nt4-msc/{preparation,stopped-readback,evaluation}.json`,
`artifacts/nt4-msc/build04/build.json`, `artifacts/nt4-msc/MSC4LOG.TXT` oraz runtime
`artifacts/coverage/vm/nt4-installed03-usb-msc04`.
Testy hostowe: 3 testy kontraktu/operatora i kolejności rzeczywistych futures,
3 odmowy obserwatora na hoście; formatowanie patcha sprawdza `git diff --check`.

## Ukończone dowody runtime04

| Zdarzenie | Dowód |
| --- | --- |
| Startowy FAT16 rzeczywiście czytelny jako D: | Explorer03, native Notepad05: START payload, STARTUP:0 |
| HOT faktycznie podłączony i czytelny jako E: | nowy Explorer08, Notepad09: HOTPLUG payload, HOT:0 |
| Write/Flush/Close i ponowny odczyt | własny log oraz Notepad10: ROUNDTRIP payload |
| Wyjęcie po zamknięciu Notatnika | DEVICE_DELETED i nowy Explorer12: tylko D:, bez E: |
| Ten sam backend/serial/port po ponownym włożeniu | nowy Explorer14: E: wrócił, REPLUG:0 |
| Trwały plik ponownie czytelny | native Notepad15: ROUNDTRIP payload oraz stopped FAT readback |
| Bezpieczne zamknięcie | natywny dialog16, safe-off17, TTY95937 exit0 i QMP quit |

Oba FAT16 mają zgodne BPB/root label i prywatne znaczniki. Stopped readback
ponownie potwierdza START/HOTPLUG oraz ROUNDTRIP SHA256
`003fd2202119eff8ac1e0e241942c8a9ce4ad2465f57339143e3557eb84efe15`.
Actual target po wyłączeniu:
`a6807a432891b47ea20a4eb1650fc981ae8b7fdade6cec138d9ef03818b1de5c`.
Rodzic cf04 pozostał niezmieniony. Każdy start miał normalny guard 2GiB RAM
oraz 8GiB rezerwy i realny PTY. Po uzbrojeniu przyszłego zdarzenia oczekiwano
blokująco; nie odpytywano postępu.

Granica używalności: istniejące okno Explorera nie odświeżyło listy nośników
automatycznie. Nowe okno pokazywało rzeczywistą aktualną listę. Nie deklarujemy
automatycznych powiadomień powłoki PASS. WINVER nie wykonywano w tej próbie.

## Do ręcznego potwierdzenia użytkownika

- Czy natywny Explorer pokazuje plik START po starcie: TAK/NIE.
- Czy nośnik HOT pokazuje HOTPLUG i zapisany ROUNDTRIP: TAK/NIE.
- Czy po wyjęciu/włożeniu ten sam plik pozostaje czytelny: TAK/NIE.

Powyższe czynności zostały potwierdzone przez operatora testowego w VM.
Odpowiedzi użytkownika dotyczą własnej oceny używalności; nie są zastępowane
samą odpowiedzią QMP ani obecnością urządzenia w topologii. Nie kwalifikujemy
równocześnie HID starego2d455 i MSC313952 jako jednego działającego pakietu.
