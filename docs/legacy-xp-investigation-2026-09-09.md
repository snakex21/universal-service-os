# Legacy Windows XP — historia diagnozy i punkt wznowienia

Stan na: **2026-09-09**

Ten dokument utrwala drogę dojścia do bieżącej decyzji dla Windows XP w Legacy BIOS. Ma zapobiec ponownemu otwieraniu zamkniętych koncepcji i pomóc odróżnić fakty potwierdzone testem od hipotez.

## 1. Cel

Docelowy tor XP ma instalować 32-bitowy Windows XP z ISO bez emulacji urządzenia blokowego ISO i bez własnego zamiennika NTLDR/SETUPLDR. USOS przygotowuje lokalne źródło instalatora na dysku docelowym, a dalej korzystamy możliwie blisko z oryginalnego toru Microsoft NT 5.2.

Kanoniczne źródło do walidacji to czysty `windows_xp_professional_service_pack_2_x86_pl.iso`. Zmodyfikowany SP3 NiKKA służy wyłącznie jako dodatkowy test zgodności stagingu i nie jest clean-room wzorcem.

## 2. Co zostało potwierdzone przed problemem CHS

### 2.1 `WINNT32 /makelocalsource`

Kontrolna instalacja czystego XP SP2 PL w VirtualBox potwierdziła, że `WINNT32.EXE /makelocalsource /noreboot` przygotowuje poprawne lokalne źródło:

- `$WIN_NT$.~BT`,
- `$WIN_NT$.~LS\I386`,
- `BOOTSECT.DAT`,
- `setupldr.bin`,
- `ntdetect.com`,
- `txtsetup.sif`,
- `winnt.sif`.

Klon kontrolnego obrazu uruchomił Text Mode Setup bez podłączonego ISO. To zamknęło potrzebę emulowania ISO dla XP.

### 2.2 Odtworzenie BT/LS przez USOS

Produkcja `$WIN_NT$.~BT` została odtworzona na podstawie `DOSNET.INF [FloppyFiles.*]`, a `$WIN_NT$.~LS\I386` przez kopię pełnego `I386`. Test porównawczy dla czystego SP2 nie wykazał różnicy w zestawie wymaganych plików BT poza plikami generowanymi/maszynowymi.

### 2.3 Pierwszy poprawny staging XPSETUP

Tor:

`USOS -> micro-Linux -> prepare_xp_target.sh -> XPSETUP FAT32 -> Microsoft NT52 VBR/stage2 -> SETUPLDR`

osiągnął w SeaBIOS/TCG ekran wyboru partycji bez źródłowego ISO.

Przy okazji wykryto niezależny problem geometrii FAT32 tworzony przez `mkfs.fat` na ~120 GB targetach. 2 GiB XPSETUP przy złym `spc=64` miało graniczne `65518` klastrów danych i XP błędnie pokazywał `0 MB wolnych`, po czym zgłaszał brak 1024 KB na pliki startowe. Produkcja została poprawiona na `spc=8`, minimum `65525` klastrów oraz realny zapas z FSInfo. Po poprawce XP widział około 1,5 GB wolnego i przechodził do kopiowania plików.

To był osobny błąd FAT32, nie późniejszy problem CHS.

## 3. Fizyczny Socket 939 — problemy po drodze

### 3.1 Enumeracja dysku

Pierwszy fizyczny staging zatrzymał się na `[1/5] STARTING ENVIRONMENT` z `NO NON-USOS TARGET DISKS DETECTED FOR LEGACY XP STAGING`, mimo podłączonego SSD.

Diagnostyka wykazała, że problem nie leżał w samym guardzie targetu, lecz w braku właściwego sterownika dla kontrolera SATA na MS-7100. Fizyczny chipset zgłosił NVIDIA CK804 `10de:0054/0055`; potrzebny był `sata_nv`. Z tego powodu środowisko przygotowawcze zostało przełączone z Alpine `virt` na stockowy kernel LTS z pełną rodziną `drivers/ata` i ładowaniem sterownika przez PCI modalias.

Po tej zmianie fizyczny target pojawił się jako normalny `/dev/sdX` candidate.

### 3.2 Identyfikacja targetu BIOS/Linux

USOS zaczął przekazywać do mikro-Linuksa inwentaryzację BIOS INT 13h i wiązać ją z dyskiem Linux po rozmiarze/identyfikacji. Dla testowego targetu 120034123776 B w SeaBIOS typowy wynik wynosił:

- BIOS drive `0x81` przy wpiętym Kingstonie,
- EDD obecne,
- `234441648` sektorów po 512 B,
- `AH=08 = 1023/255/63` w środowisku, w którym geometria BIOS odpowiadała geometrii BPB.

## 4. Problem właściwy: Microsoft NT52 i rozjazd CHS

Na fizycznym MS-7100 zaobserwowano konfigurację, w której BIOS dla targetu zwracał geometrię legacy `240/63`, podczas gdy FAT32 BPB przygotowany dla XP używał `255/63`.

Instrumentowany test odtworzył ten przypadek dokładnie w SeaBIOS:

- BIOS/AH=08: około `1023/240/63`,
- BPB: `255/63`,
- odczyt wskazanego LBA przez EDD: poprawny,
- konwersja CHS według bieżącego `AH=08`: poprawny sektor,
- konwersja tego samego adresu według BPB `255/63`: inny sektor,
- stock Microsoft NT52 ładował w RAM złą zawartość NTLDR/stage2 przy tym rozjeździe.

Kanoniczna regresja odtwarzająca fizyczny błąd to `tools/tests/legacy_bios/run_seabios_xp_geometry_mismatch_nt52.ps1`. Test potwierdza, że to nie uszkodzenie plików stagingu, lecz zależność stock NT52 od niespójnej geometrii CHS.

## 5. Eksperyment EDD-only — diagnostyka, nie kierunek produkcyjny

Powstał test `run_seabios_xp_geometry_mismatch_nt52_edd.ps1`, który modyfikuje Microsoft NT52 minimalnym patchem EDD-only. W wymuszonej topologii `240/63 BIOS` + `255/63 BPB` patch potrafił załadować dokładny obraz i przejść dalej do XP Text Mode.

Ten wynik był ważny diagnostycznie: potwierdził, że źródłem błędu jest ścieżka CHS NT52. **Nie jest to zatwierdzony backend produkcyjny.** Nie dokładamy własnego loadera NTLDR ani nie utrzymujemy forka Microsoft bootcode jako rozwiązania docelowego.

## 6. Próba opcji 1 — zmiana rozmiaru/końca XPSETUP

Sprawdzono koncepcję, że odpowiednio większy/zmieniony layout XPSETUP pozwoli wymusić w MBR sentinel końcowego CHS `FEFFFF`, dzięki czemu Setup miałby nie przeliczać geometrii w problematyczny sposób.

Test 8 GiB pokazał jednak, że Windows XP Setup normalizuje/obcina cylinder do wartości reprezentowalnej dla własnej logiki. Zamiast oczekiwanego `FEFFFF` (`75E1FF` jako odpowiadający badanej pozycji w innym zapisie diagnostycznym) otrzymywany koniec nadal nie dawał właściwości, na której opierała się koncepcja; w stagingu 8 GiB obserwowano m.in. końcowy CHS `FEFFFE`.

Wniosek: **rozmiar partycji nie naprawia problemu. Opcja 1 jest zamknięta.**

Wszystkie testy 8 GiB / `FEFFFF`, które miały być zielonym gate dla opcji 1, należy usunąć lub zdegradować do wyłącznie historycznej diagnostyki. Nie mogą blokować ani zatwierdzać obecnego toru.

## 7. Opcja 3 / shim — zamknięta

Badano także możliwość utrzymania zgodności przez shim/translator geometrii lub inny własny kod pomiędzy BIOS-em i stock NT52.

To również zostało odrzucone jako kierunek produkcyjny. Wyniki instrumentacji i shimów zostają jako materiał diagnostyczny do zrozumienia NT52, ale nie wolno cicho wracać do tej architektury, jeżeli nowy tor nie przejdzie walidacji.

**FAIL obecnego planu = STOP i raport. Nie wracamy automatycznie do opcji 1, 3 ani własnego loadera NTLDR.**

## 8. Kluczowa obserwacja fizyczna z Kingstonem

Najważniejszy późniejszy odczyt zmienił ocenę ryzyka dla pierwszego etapu:

**gdy Kingston/USOS jest wpięty, AH=08 dla dysku Intel/targetu zwraca `255/63`, czyli geometrię zgodną z BPB `255/63`.**

To oznacza, że przy topologii z USOS jako pierwszym dyskiem stock NT52 nie ma rozjazdu `240/63` vs `255/63` na tym etapie. Dla pierwszego Text Mode Setup nie ma więc potrzeby własnego loadera ani EDD patcha.

Ta obserwacja jest podstawą obecnej decyzji architektonicznej.

## 9. Opcja 5 — zatwierdzony kierunek

Drugi etap ma być koordynowany z pendrive'a USOS, analogicznie do klasycznego schematu używanego przez WinSetupFromUSB/Easy2Boot, ale bez kopiowania ich loadera i bez emulacji ISO.

Docelowa sekwencja użytkownika:

1. boot z USOS,
2. staging XP na target,
3. reboot,
4. boot z USOS,
5. stock XP Text Mode Setup z przygotowanego XPSETUP,
6. wybór/format partycji Windows i kopiowanie plików,
7. reboot,
8. ponowny boot z USOS,
9. drugi etap USOS przekazuje sterowanie na target tak, aby Windows GUI Setup mógł kontynuować,
10. następny reboot już z targetu,
11. OOBE / pierwszy pulpit.

Użytkownik wybiera XP tylko raz. Koordynacja etapów ma być automatyczna, ale musi istnieć bezpieczna możliwość wyjścia do zwykłego menu. Legacy Core nie może polegać na BIOS `INT 16h`; wejście obsługujemy istniejącym pollingiem 8042 w PM32.

Ważne: Legacy Core obecnie montuje ESP/FAT32 read-only. Nie wolno projektować stanu faz jako prostego zapisu `phase=` na ESP z poziomu Core bez rozwiązania tej własności. Stan lifecycle musi być wyprowadzony z bezpiecznego źródła, które da się wiarygodnie odczytać i/lub zapisać przez odpowiedni etap.

## 10. Dwie topologie, które muszą być rozdzielone

### Topologia A — USOS wpięty

- Kingston/USOS jest BIOS drive `0x80`.
- Target jest kolejnym BIOS drive, typowo `0x81`.
- Fizyczna obserwacja: target zgłasza przez AH=08 `255/63`, zgodne z BPB.
- To topologia dla stagingu, pierwszego Text Mode i przyszłego drugiego etapu koordynowanego przez USOS.

### Topologia B — target sam

- Kingston/USOS jest całkowicie odpięty.
- Target staje się BIOS drive `0x80`.
- Na badanym sprzęcie może wtedy wrócić geometria `240/63`.
- To topologia krytyczna dla końcowego, samodzielnego startu zainstalowanego XP.

Nie wolno uznać sukcesu topologii A za dowód, że gotowy XP uruchomi się sam w topologii B.

## 11. Brama 24 — obecnie najważniejszy test

Zanim zostanie zaimplementowany pełny lifecycle opcji 5, najpierw trzeba odpowiedzieć na jedno pytanie:

> Czy już zainstalowany XP z obecnego RAW po fizycznym przebiegu potrafi uruchomić się do **pierwszego pulpitu** z samego targetu jako BIOS `0x80` przy geometrii `240/63`?

To jest **brama 24**.

### PASS

PASS wymaga dojścia do pierwszego działającego pulpitu Windows XP z:

- tylko targetem podłączonym do VM/testowej topologii,
- bez USOS/Kingstona,
- targetem jako BIOS `0x80`,
- wymuszonym/odtworzonym zachowaniem `240/63`,
- bez shimu CHS,
- bez EDD-only patcha Microsoft NT52,
- bez własnego NTLDR/loadera,
- bez modyfikacji źródłowego RAW.

Jeżeli ten test przejdzie, można inwestować w pełny lifecycle opcji 5.

### FAIL

Jeżeli zainstalowany XP nie dochodzi do pulpitu z samego targetu przy `240/63`, **STOP**. Raportujemy dokładny etap i dowody. Nie wracamy cicho do shimu, opcji 3 ani opcji 1.

### Wynik wykonania bramy 24 — 2026-09-09

Pełny klon fizycznego Intela po Text Mode został zapisany jako:

`zig-out/legacy-bios/gate24-inspect/intel-posttextmode-gate24-source.raw`

Rozmiar: `120034123776` B. Krytyczne sektory MBR, XPSETUP VBR, EBR i NTFS VBR zostały porównane z fizycznym Intelem odczytem i były identyczne. Fizyczny Intel nie był używany jako dysk VM i nie wykonano na nim żadnego zapisu.

Kontrola tego samego klona przy `255/63` przeszła:

- target jako jedyny BIOS disk `0x80`,
- bez USOS,
- zapisy gościa wyłącznie do QCOW2 overlay,
- QEMU przeszedł z real mode do protected mode,
- bezpośrednia instrumentacja NT52 pokazała `M/V/2/F/N/J = PASS`,
- `CRC RAM=49E52C53 EXPECT=49E52C53 SAME=YES`.

Brama przy `240/63` nie doszła do pulpitu i na nieinstrumentowanym klonie wizualnie pozostawała na `SeaBIOS -> Booting from Hard Disk...` z migającym kursorem. Instrumentacja tego samego klona wyjaśniła jednak, że nie jest to wcześniejsza awaria MBR/VBR:

- `M DL=80` — MBR wykonuje się,
- `V DL=80` — oryginalny MBR znajduje aktywny XPSETUP i uruchamia Microsoft VBR,
- `2 DL=80` — Microsoft VBR uruchamia stage2,
- `F DL=80` — stage2 dochodzi do odczytu katalogu FAT32,
- `N DL=80` — NTLDR zostaje znaleziony,
- `J DL=80` — stage2 dochodzi do oryginalnego skoku do załadowanego NTLDR,
- ale `CRC RAM=1E5F267F EXPECT=49E52C53 SAME=NO`.

Bez shimu, przy rzeczywistym QEMU `AH=08 H=240/S=63`, kontrolny odczyt LBA `1123648` pokazał:

- EDD: poprawny,
- CHS wyliczony z `AH=08 240/63`: poprawny (`SAME=YES`),
- CHS wyliczony z BPB `255/63`: błędny/nieczytelny (`SAME=NO`).

Wniosek: **brama 24 FAIL wynika z tej samej klasy problemu co wcześniejszy przypadek NT52 — rozjazd geometrii BIOS `240/63` i FAT32 BPB `255/63` powoduje błędne załadowanie NTLDR. Nie jest to nowa awaria MBR ani VBR.**

Dodatkowo Text Mode zmienia stan boot files:

- rootowy `NTLDR` ma po Text Mode `250624` B zamiast tymczasowego setup-loadera `262400` B,
- Microsoft NT52 stage2 pozostaje bit-identyczny z wcześniejszym wzorcem,
- VBR różni się od wzorca tylko zlokalizowanymi polskimi komunikatami błędów; kod maszynowy NT52 poza oknem tekstów jest identyczny.

Z tego powodu diagnostyka została poprawiona tak, aby rozmiar NTLDR był pobierany z rzeczywistego pliku i patchowany do runtime CRC, a lokalizacja komunikatów VBR nie była mylona ze zmianą kodu loadera.

### Eksperyment BPB heads-only — 2026-09-09

Na sparse klonie po Text Mode zmieniono wyłącznie pole `BPB heads` w VBR partycji XPSETUP: `255 -> 240` (`FF 00 -> F0 00`, więc faktycznie zmienił się tylko bajt VBR offset `26`). Kontrola przed bootem potwierdziła:

- MBR: bez różnic,
- XPSETUP VBR: jedyna różnica na offset `26`,
- Microsoft NT52 stage2: bez różnic,
- EBR: bez różnic,
- NTFS VBR: bez różnic i nadal `255/63`,
- partycje i NTLDR: bez zmian.

Czysty, nieinstrumentowany boot targetu jako jedynego BIOS disk `0x80` przy `240/63` przeszedł do protected mode (`CR0.PE=1`) i przełączył VGA do `640x480`, czyli NTLDR rzeczywiście przejął sterowanie i wykonał kod po punkcie `J`.

Osobna diagnostyczna kopia tego samego patched RAW dała:

- `M/V/2/F/N/J = PASS`,
- BIOS/AH=08: `240/63`,
- XPSETUP BPB: `240/63`,
- LBA `1123648`: AH08-CHS i BPB-CHS wyliczyły identycznie `C=74 H=75 S=44`, oba odczyty `SAME=YES`,
- `CRC RAM=49E52C53 EXPECT=49E52C53 SAME=YES`.

Wniosek: **zmiana wyłącznie XPSETUP BPB heads `255 -> 240` naprawia dokładnie awarię ładowania NTLDR w topologii target-only `240/63`, bez shimu, bez EDD-only patcha i bez własnego loadera.** NTFS VBR pozostawiony na `255/63` nie blokuje przejścia przez NTLDR w tym teście.

Pierwotny wynik bramy 24 (`255` w BPB przy BIOS `240`) pozostaje ważnym negatywnym testem, ale znaleziono minimalny warunek naprawczy. Pełny warunek bramy 24 nadal wymaga pierwszego pulpitu XP; obecny eksperyment potwierdza już poprawny boot za NTLDR/protected mode.

### Strategia B — MBR korygujący BPB wyłącznie w RAM

Powstał eksperymentalny MBR `xp_geometry_fix_mbr.S`. Pierwsza działająca wersja miała 146 bajtów; po dodaniu fail-safe walidacji odpowiedzi `INT 13h AH=08` bieżący kod ma 172 bajty (nadal jest dopełniany do 440 bajtów i zachowuje tablicę partycji/sygnaturę dysku). Po relokacji własnego sektora do `0000:0600`:

1. wykonuje `INT 13h AH=08` dla bieżącego `DL`,
2. przelicza `DH(max head) + 1` na liczbę głowic,
3. znajduje aktywną partycję w tablicy MBR,
4. ładuje jej VBR przez `INT 13h AH=42` pod `0000:7C00`,
5. nadpisuje tylko RAM-owe `word [7C00+1Ah]` aktualną liczbą heads,
6. przekazuje `DL` i skacze do oryginalnego Microsoft VBR.

Na dysku XPSETUP pozostał bez zmian: `BPB H=255 S=63`. Przy BIOS `240/63`:

- czysty boot przeszedł do protected mode,
- `M/V/2/F/N/J = PASS`,
- `CRC RAM=49E52C53 EXPECT=49E52C53 SAME=YES`.

Kontrola przy BIOS `255/63` również przeszła do protected mode, więc dynamiczna korekta nie psuje zgodnej topologii.

Wniosek: **Strategia B działa przy niezmienionym BPB na dysku i usuwa potrzebę przewidywania przyszłej geometrii podczas stagingu.**

Odporność `AH=08` jest fail-safe: MBR koryguje heads tylko wtedy, gdy BIOS zwróci sukces, `SPT=1..63`, SPT zgadza się z BPB oraz `DH` mieści się w zakresie `1..254` (czyli 2..255 heads). W przeciwnym razie nie modyfikuje BPB w RAM i przekazuje sterowanie do Microsoft VBR z oryginalnym `255/63`. Test `tools/tests/legacy_bios/test_xp_geometry_fix_mbr_ah08.py` wykonuje dokładny produkcyjny artefakt 440 B w 16-bitowej emulacji i potwierdza 6/6 przypadków: poprawne `240/63`, błąd CF, `DH=0`, `DH=255`, `SPT=0`, niezgodne SPT. Każdy przypadek dochodzi do handoffu VBR; przypadki błędne zostawiają `255/63`.

### Strategia A — XPSETUP powyżej progu CHS

Na osobnym disposable sparse klonie przeniesiono cały 2-GiB XPSETUP z `LBA 2048` na `LBA 18874368` (9 GiB). Rozmiar partycji pozostał bez zmian. Zaktualizowano wyłącznie metadane konieczne do relokacji: start LBA/CHS wpisu P1 oraz FAT32 `HiddenSectors` w głównym i backup VBR. `BPB heads` pozostał `255`, `SPT=63`.

Fixture celowo nadpisuje fragment kopii NTFS, bo `LBA 18874368` leży w jej obecnym zakresie; służy wyłącznie do dowodu ścieżki NT52, nie do pełnego bootu XP.

Przy BIOS `240/63`:

- czysty boot przeszedł do protected mode,
- stock MBR znalazł przeniesiony aktywny XPSETUP,
- `M/V/2/F/N/J = PASS`,
- `CRC RAM=49E52C53 EXPECT=49E52C53 SAME=YES` mimo `BPB heads=255`.

Binary trace QEMU potwierdził rzeczywistą ścieżkę Microsoft NT52:

- `7CE2: CMP EAX,[BP-08]` — wykonane,
- `7CE6: JB 7D34` — warunek CHS nie został podjęty,
- `7D1F: MOV AH,42` / `7D26: INT 13h` — wykonane,
- blok CHS od `7D34` i jego `INT 13h` przy `7D5C` — nie został wykonany.

Na badanym SeaBIOS `AH=08` zwraca `Cmax=1022, H=240, S=63`; NT52 zwiększa cylinder count do `1023`, więc rzeczywisty próg testu to `1023*240*63 = 15467760`, nie `15482880`. `LBA 18874368` jest bezpiecznie powyżej tego progu. Analogicznie przy 255 heads próg dla tego BIOS-u wynosi `16434495`.

Wniosek: **Strategia A również działa i NT52 rzeczywiście przechodzi wtedy na EDD; nie jest to wariant wcześniejszej opcji 1 o zmianie rozmiaru partycji.** Produkcyjnie wymaga jednak innego layoutu targetu, bo obecne położenie XPSETUP przy początku dysku nie może zostać po prostu przesunięte na 9 GiB bez przebudowy rozmieszczenia Windows/NTFS.

#### Strategia A jako formalny plan B

Strategia A nie jest bieżącą implementacją i nie ma być automatycznym fallbackiem w produkcji. Jest udokumentowanym planem B na wypadek, gdyby Strategia B okazała się niekompatybilna z konkretną klasą BIOS-u mimo walidacji `AH=08`.

Warunki wejścia w plan B:

1. reprodukowalny FAIL Strategii B na prawdziwym sprzęcie,
2. potwierdzenie, że awaria leży w ścieżce geometrii/NT52, a nie w sterowniku dysku, NTFS lub samym GUI Setup,
3. zachowany dowód, że ten sam nośnik przechodzi ścieżkę EDD po przeniesieniu XPSETUP ponad próg CHS,
4. osobna decyzja o zmianie layoutu targetu — bez cichego przesuwania partycji istniejącego użytkownika.

Jeżeli plan B zostanie aktywowany, layout musi od początku zarezerwować XPSETUP powyżej bezpiecznego progu EDD dla obsługiwanej geometrii BIOS, z pełnym guardem kolizji z partycjami danych. Nie przenosimy istniejącej partycji NTFS ani nie nadpisujemy jej fragmentu jak w fixture dowodowym.

### NTFS po Text Mode

Ponowny odczyt dokładnie tego samego post-TextMode RAW potwierdził:

- logical NTFS VBR = `LBA 4209093`,
- `BPB SPT=63`,
- `BPB heads=255`,
- SHA-256 VBR `C067E10DAB3662CBEB9BE794839EAE984C6734153248245BF21CFC228B500E9D`.

Czyli hipoteza, że XP Setup wpisał do NTFS `240`, jest fałszywa dla naszego fizycznego przebiegu.

Nie oznacza to jednak automatycznie drugiej awarii VBR: aktywny pozostaje XPSETUP FAT32, a jego `boot.ini` kieruje NTLDR do `multi(0)disk(0)rdisk(0)partition(2)\\WINDOWS`; NTFS VBR nie jest kolejnym chainloadowanym bootsectorem. W 12-sekundowym trace Strategii B przy BIOS `240/63` po uruchomieniu NTLDR pojawiło się 21658 odczytów od `LBA >= 4209093`, w tym bezpośrednio od `4209093..`, więc NTLDR potrafi już czytać logiczny NTFS mimo jego `BPB heads=255`.

To nadal nie zastępuje pełnego testu do pulpitu, ale falsyfikuje prosty wniosek „NTFS BPB=255 => natychmiast ten sam błąd przy finalnym boocie”.

## 12. Obecny `run_seabios_xp_target_only.ps1` nie jest jeszcze bramą 24

Istniejący `tools/tests/legacy_bios/run_seabios_xp_target_only.ps1` jest użyteczny, ale jego bieżąca definicja jest za słaba dla bramy 24:

- klonuje źródłowy RAW do `target-only.raw`,
- uruchamia `prepare_xp_target_only_fixture.py`, czyli przygotowuje/instrumentuje boot fixture,
- jego zielony warunek to przejście przez `NTDETECT` i pojawienie się ekranu Setup,
- nie wymaga dojścia do zainstalowanego pulpitu,
- nie jest testem niezmodyfikowanego, już zainstalowanego targetu.

Dlatego brama 24 powinna użyć obecnego RAW z fizycznego przebiegu jako **read-only source**, zrobić wyłącznie file-backed clone/overlay do QEMU i uruchomić zainstalowany system bez wstrzykiwania loadera diagnostycznego.

## 13. Marker „instalacja zakończona” — nie jest wymagany w bieżącym lifecycle

Bieżąca produkcyjna ścieżka nie utrzymuje USB jako automatycznego drugiego etapu. Po udanym stagingu marker `xp-target-ready.ini` jest kasowany, użytkownik wyjmuje USOS, a przygotowany target startuje sam jako BIOS `0x80` z produkcyjnym MBR Strategy B. Text Mode, GUI Setup i kolejne restarty należą już do instalowanego dysku.

W tej architekturze USOS nie musi rozpoznawać „pierwszego pulpitu” i nie potrzebuje markera zakończenia instalacji. Jeżeli kiedyś wrócimy do wariantu z drugim etapem uruchamianym z USB, wybór markera musi ponownie przejść osobną bramę i nie może być zgadywany na podstawie częściowo zainstalowanego systemu.

## 14. Co jest historyczne i nie może być zielonym gate obecnego planu

Poniższe rzeczy pozostają cennym materiałem diagnostycznym, ale nie mogą zatwierdzać bieżącego lifecycle:

- testy opcji 1 oparte na 8 GiB / `FEFFFF`,
- shim `240/63 <-> 255/63`,
- EDD-only patch Microsoft NT52,
- własne/instrumentowane VBR/stage2 używane do pomiaru,
- test `target_only`, który kończy się tylko po `NTDETECT`/ekranie Setup,
- sukces Text Mode w topologii A jako zastępstwo testu samodzielnego bootu targetu.

## 15. Ograniczenia bezpieczeństwa na obecny etap

- **Nic nie zapisujemy na fizycznych dyskach.**
- Nie uruchamiamy `prepare_xp_target.sh`, `CREATE XPSETUP`, instalatora/updatera ani żadnego skryptu fizycznego write.
- Fizyczne obrazy/RAW mogą być wyłącznie źródłem read-only do utworzenia file-backed clone/overlay.
- QEMU ma pracować wyłącznie na plikach w repo/`zig-out`.
- FAIL = stop; bez automatycznych obejść.

## 16. Punkt wznowienia

Brama B/24 ujawniła awarię stock Microsoft NT52 przy rozjeździe `BIOS 240/63` vs `BPB 255/63`; MBR, VBR i stage2 dochodzą do skoku do NTLDR, ale NTLDR jest wtedy załadowany z błędnych sektorów.

Eksperyment `BPB heads-only 255 -> 240` na klonie usunął tę awarię: CRC NTLDR jest poprawne i czysty boot przechodzi do protected mode. Nie użyto shimu, EDD-only patcha ani własnego loadera.

Problem „skąd staging ma znać przyszłe `240`” nie jest już wymaganiem Strategii B: MBR mierzy geometrię przez `AH=08` dopiero w faktycznej topologii target-only i koryguje BPB tylko w RAM. Z tego powodu plan pomiaru `AH=48`/DPTE został porzucony jako zbędny dla tego kierunku.

Strategia A również jest potwierdzona jako EDD-only powyżej progu, ale wymaga przebudowy layoutu targetu. Na obecnych dowodach Strategia B jest mniejszą zmianą architektoniczną.

Bieżący świeży przebieg na tym samym sprzęcie QEMU przeszedł Text Mode i wystartował GUI Setup przy `240/63` ze Strategią B. Do ekranu klucza produktu kod MBR 0..439 nadal ma dokładny SHA-256 bieżącego artefaktu Strategy B, więc Setup nie nadpisał go na tym etapie. Użytkownik zaakceptował dojście do obowiązkowego ekranu klucza jako wystarczającą bramę dla poprawności toru boot/Text Mode/GUI Setup; dalsza finalizacja jest zwykłą fazą instalacji zależną od legalnego klucza i nie jest już blokadą wdrożenia USOS. Ryzyko ewentualnego późnego zapisu LBA0 po tym ekranie pozostaje nieudowodnione eksperymentalnie i nie może być opisywane jako zamknięte. Produkcyjny staging instaluje Strategy B bezpośrednio na targetcie i wymaga bitowego readbacku przed przekazaniem użytkownikowi komunikatu o wyjęciu USOS.


## 17. Regresja czarnego ekranu menu — 2026-09-09

Odczyt fizycznego Kingstona potwierdził, że aktualizacja B260909-124828-F76C0F2E wgrała Core SHA-256 1E818CE0C72B05A2C8624B52FFDBF03B0F10BE883176BA775234240A2A51928C. To wariant XpMenuAutoTest, nie menu produkcyjne. Runner prepare_legacy_xp_menu_fixture.ps1 budował go do współdzielonego zig-out/legacy-bios, nadpisując artefakt później pakowany do instalatora.

Reprodukcja na plikowym fixture NTFS/SeaBIOS ze standardową grafiką potwierdziła: VBE 1280x800 uruchamia się, autotest zgłasza FAIL expected exactly safe.sif in XP unattended catalog, po czym core_main zatrzymuje się w pętli. Screenshot ma wszystkie kanały RGB równe zero. Na identycznym fixture wymiana tylko Core na produkcyjny 2A3370700D055F98770501CF034778B2D6C23D8631AD27F9529EBAC8A0FB6E72 przywraca pełne menu. Ten hash jest identyczny z Core sprzed ostatniej fizycznej aktualizacji. Problem nie wynika z MBR Strategy B dysku XP.

Naprawa: osobny test-core wewnątrz katalogu fixture; builder odrzuca autotest kierowany do katalogu produkcyjnego (także przez alias ścieżki); generator payloadu i instalator odrzucają Core zawierający marker autotestu. Pełny build wykonuje regresję izolacji, a fingerprint uwzględnia narzędzia budowania/pakowania Legacy.

Dowody tej sesji: zig-out/repair-bios-20260909/: zachowany wadliwy Core, odczyt pierwszego MiB Kingstona, logi menu-old.serial.log / menu-fixed.serial.log oraz screenshoty menu-old.png / menu-fixed.png. Plik kingston-readonly-copy.raw jest niepełną kopią diagnostyczną, nie pełnym backupem nośnika i nie służy do odtwarzania.

Aktualizacja fizycznego Kingstona wykonana w tej sesji: B260909-133837-AFE8F546, RESULT=PASS. Niezależny odczyt potwierdził produkcyjny Core 2A3370700D055F98770501CF034778B2D6C23D8631AD27F9529EBAC8A0FB6E72 i niezmienione MBR/GPT. Użytkownik został poproszony o fizyczne sprawdzenie menu. Pełna macierz Zig/UEFI, testy Go, regresja boot/header/CRC, menu NTFS, izolacja autotestu i 6/6 AH08: PASS. Świeży XP SP2 staging 120 GB + start z samego targetu doszły do kopiowania plików. Na życzenie użytkownika dalsze etapy przeniesiono do VirtualBoxa, żeby nie czekać na wolny TCG.

## 18. Korekta po pełnym Text Mode w VirtualBox — 9 września 2026

Nowy test na czystym SP2 PL, świeżym targetcie 120034123776 B i BIOS LCHS 1024/240/63 obalił założenie, że Strategy B zawsze przetrwa pierwszy etap. Przy utworzeniu w Setup nowej partycji Windows (16 GiB; XP umieścił ją jako logiczną w rozszerzonej) Text Mode ukończył kopiowanie, zastąpił kod MBR stockowym Microsoft i po reboocie zatrzymał się na czarnym ekranie. SHA-256 pierwszych 440 B zmienił się z D065FD99272307E1B1AA7335C18F3F2F3C658A28BC7BAD50B18AA3A15CF5FA5C na 5431084B7014A6D05FF8632A63AC55FD48D7E6BCE3ED22E39DB6AB3A674B6677. BPB pozostał 255/63. Przywrócenie samych 440 B na kopii od razu uruchomiło GUI Setup, następnie ekran ustawień regionalnych i pusty ekran klucza produktu. To nie jest dowód ukończenia instalacji/OOBE.

Wdrożony przepływ:
1. Staging zapisuje tożsamość przygotowanego targetu jako EFI/USOS/xp-resume.ini (zamiast usuwać jedyny egzemplarz xp-target-ready.ini).
2. Po wyjęciu USOS target startuje jako BIOS 0x80 i przechodzi Text Mode.
3. Po ukończeniu kopiowania i reboocie użytkownik ponownie bootuje USOS. Core pokazuje CONTINUE XP; ENTER uruchamia dedykowane usos.legacy_action=xp-resume, ESC wraca do normalnego menu.
4. legacy_xp_resume.sh weryfikuje model, serial, rozmiar, disk signature, XPSETUP slot/start/aktywną flagę, istniejący FAT32 i stan mounted/swap przez wspólny target_disk_guard. USOS USB jest wykluczony. Czyta boot.ini, ntldr, ntdetect.com; rozwiązuje ARC najpierw przez zwykłe primary, następnie logical (np. ARC partition(2) -> /dev/sdb5), montuje Windows NTFS tylko do odczytu i sprawdza kernel oraz rejestr SYSTEM.
5. Akceptuje tylko znany stock MBR XP z testu lub identyczny Strategy B. Kopiuje pełny stary sektor do ESP pod nazwą z SHA-256 całego sektora, zapisuje wyłącznie 440 B i porównuje pełne 512 B z oczekiwanym wynikiem. Nie uruchamia stagingu ani formatowania. Dopiero po PASS przenosi marker do xp-resume-completed.ini.
6. Po komunikacie gotowości użytkownik wyjmuje USOS, naciska ENTER, włącza komputer i kontynuuje GUI Setup z samego targetu.

Odmowa zapisu jest celowa przy nieznanym MBR, braku zakończonego Text Mode, niezgodności tożsamości lub niespójnym układzie. Starszy target przygotowany bez xp-resume.ini wymaga odzyskania zweryfikowanej tożsamości; nie należy ponownie formatować XPSETUP w celu samego wznowienia.

Dowody w zig-out/repair-bios-20260909:
- vbox-posttext-mbr.bin i vbox-posttext-vbr.bin: awaria po Text Mode;
- vbox-stage2-key.png i vbox-key-mbr.bin: ręcznie naprawiona kopia dotarła do klucza, Strategy B nadal obecny;
- resume-staging: pełny aktualny staging PASS, nowy marker zachowany;
- resume-success2: produkcyjne menu (ENTER oraz ESC), realny Linux i produkcyjny skrypt wznowienia PASS na overlay oryginalnego post-Text-Mode VDI; pełne MBR 440..511 zachowane;
- resume-wrong-serial, resume-wrong-id, resume-before-text: STOP oraz qemu-img compare potwierdzający identyczność całego logicznego dysku z wejściem;
- virtualbox/xp-usos-resumed.vdi i vbox-usos-resumed-gui.png: wynik naprawy wykonanej przez USOS wystartował w GUI Setup w VirtualBox przy 240/63, bez ISO ani pendrive’a.

VirtualBox działa z lokalnym VBOX_USER_HOME w katalogu dowodów. QEMU VDI 1.1 ma nagłówek 384 B; pierwsze zapisywalne otwarcie w VBox rozszerza go do 400 B i zeruje niezadeklarowane LCHS. patch_vdi_geometry.py ustawia teraz także cbHeader=400, sprawdzając brak kolizji z mapą bloków. Cztery testy sprawdzają stare/nowe nagłówki oraz odmowę modyfikacji nieznanego lub nakładającego się układu. To zmiana kontenera testowego, nie sektorów gościa.

## 19. Instalacja od zera z wyborem dysku w USOS

Użytkownik potwierdził uruchomienie GUI Setup na fizycznym Intelu po wcześniejszej naprawie. Dalsze zmiany i formatowania testowano wyłącznie na obrazach; aktualna instalacja Intela nie była kasowana.

Wariant uproszczony jest domyślny po wybraniu XP bez własnego pliku Unattended. USOS pokazuje model, serial i pojemność dysku. Wybór numeru oraz potwierdzenie `TAK` czytają właściwe `/dev/tty1`, zamiast serialowego stdin `/dev/console`. Przed pierwszym zapisem planowane są dwie przestrzenie: 2 GiB XPSETUP oraz nowa primary NTFS w największym wolnym obszarze (minimum 8 GiB, koniec najwyżej 128 GiB). Nie ma automatycznego kasowania ani zmniejszania istniejących partycji. Brak miejsca/wpisów primary zatrzymuje operację przed zapisem.

Całkowicie nieprzygotowany dysk może otrzymać MBR po potwierdzeniu, tylko gdy brak sygnatur partycji/systemu plików i pierwsze/ostatnie 1 MiB są zerowe. Guard ponownie sprawdza ten stan, tożsamość i snapshot przed zapisem. Nowy identyfikator MBR jest stabilny względem serialu i pojemności. Nie jest to tryb odzyskiwania danych ani zgoda na czyszczenie nieznanego układu.

Nowy `prepare_xp_windows_partition.sh` dodaje wyłącznie zaplanowany 16-bajtowy wpis MBR, porównuje cały sektor, odświeża tablicę w kernelu i weryfikuje start, rozmiar i rodzica obu węzłów partycji. Dopiero potem formatuje nową NTFS. Pełne `$WIN_NT$.~LS` jest kopiowane na NTFS i porównywane rekursywnie przed usunięciem kopii z XPSETUP. `$WIN_NT$.~BT` pozostaje na XPSETUP; dostaje wewnętrzny `xp_selected_partition.sif`.

Kluczowa reguła pochodzi z dokumentacji XP Deployment Tools (`ref.chm`, lokalnie `zig-out/xp-doc-probe/ref-html/u_data.htm`): przy pominięciu AutoPartition Setup wybiera partycję zawierającą lokalne `$WIN_NT$.~LS`. Profil zawiera `[Unattended]`, `Repartition=No`, `FileSystem=LeaveAlone`, `UnattendMode=ProvideDefault`. Nie ma klucza produktu ani wymyślonych danych użytkownika. Własny SIF pozostaje kopiowany dokładnie i zachowuje wcześniejszy tryb; nie łączymy go automatycznie z wewnętrznym profilem. Text Mode nadal wykonuje normalne kopiowanie i przygotowanie Windows, lecz nie wymaga ręcznego wyboru partycji.

Potwierdzone wyniki:

- `zig-out/xp-selected-partition-probe2-20260909`: początkowy eksperyment z lokalnym źródłem na NTFS. Text Mode bez wejścia z klawiatury, następnie GUI po restarcie.
- `zig-out/xp-auto-blank-20260909`: normalny backend od zerowego dysku 120034123776 B, nowy MBR, XPSETUP primary 1 od LBA 2048 i Windows primary 2. Staging zakończył się PASS. W VirtualBox 1024/240/63, bez ISO/USOS i bez wciskania klawiszy, Text Mode doszedł do kopiowania i po restarcie do ekranu powitalnego GUI (`gui-check.png`). Pierwsza wersja harnessu czekała na nieobecny testowy marker zatrzymania mimo rzeczywistego PASS; obraz zakończono przez monitor i wyeksportowano. Harness teraz rozpoznaje również normalny ekran gotowości.
- `zig-out/xp-auto-interactive-20260909`: produkcyjne pytania obsłużone emulowaną klawiaturą na tty1 (bez testowej autoselekcji). Wcześniejsza primary 1 z danymi kontrolnymi, XPSETUP primary 2 od LBA 67584 i Windows primary 3. Staging PASS, Text Mode automatyczny. Wszystkie 3700 bajtów danych kontrolnych pozostały identyczne także po Text Mode.
- Oba przebiegi Text Mode zapisały stockowy kod MBR `5431084B7014A6D05FF8632A63AC55FD48D7E6BCE3ED22E39DB6AB3A674B6677`. Na pustym układzie GUI wystartowało bez pomocy; przy XPSETUP od LBA 67584 restart zakończył się czarnym ekranem. Nie wolno więc twierdzić, że automatyczny wybór partycji gwarantuje zachowanie Strategy B lub bezobsługowy restart dla każdego układu.
- `zig-out/xp-auto-existing-resume2-20260909`: produkcyjny backend CONTINUE XP na kopii drugiego przypadku PASS, ARC partition(3) poprawnie rozpoznana, zapis tylko 440 B, reszta MBR zachowana. Test użył bezpośredniego startu aktualnego mikro-Linuksa (`test_xp_resume.py --direct-linux`); menu ENTER/ESC było sprawdzone osobno w sekcji 18. Wynik tej naprawy uruchomił GUI w VirtualBox 1024/240/63 (`gui-check.png`), bez ISO/USOS.
- `test_xp_windows_plan.py`: 13 testów planowania PASS, w tym zachowanie starej partycji od LBA 63, zajęte sloty, nakładanie, brak miejsca, limit 128 GiB, wadliwy reuse i GPT.
- `zig-out/xp-blank-guard-20260909`: sześć odmów guarda PASS (wyłączona inicjalizacja, brak właściwego potwierdzenia, inny serial, zmieniony MBR, metadane GPT i metadane na końcu dysku); końcowy snapshot identyczny.
- Pełny build, testy Go, testy jednostkowe USOS, startup selftest oraz QEMU UEFI x86_64/ARM64 PASS. Wydanie `B260909-154713-0F21E3CB`; initramfs SHA-256 `E23E08C88565C10B1C9D0F0E495F5727EC1CEB843355951AAD3A6EEF506F3973`.
- Kingston PhysicalDrive8, GPT `31c644bf-74dd-4807-9cb2-46745adeadd4`: aktualizacja i odczyt wszystkich plików PASS (`zig-out/xp-auto-kingston-update.log`). Geometria GPT i identyfikatory partycji bez zmian. Nowa instalacja na fizycznym sprzęcie i zakończenie OOBE/pulpitu nie zostały jeszcze potwierdzone.
- Końcowy odczyt ESP znalazł pozostały `legacy-xp-menu-test.ini`, który omijał wybór i potwierdzenie dysku. Po ponownej weryfikacji Kingstona zapisano identyczną kopię do `zig-out/xp-auto-fixture-marker-backup`, a plik testowy usunięto z ESP. Odczyt kontrolny potwierdził brak autoselekcji, storage-probe i starego xp-target-ready.ini oraz zgodność wersji i SHA-256 initramfs. Marker wznowienia istniejącej instalacji nie był usuwany.

Instrukcja dla tej wersji: przy ekranie CONTINUE XP naciśnij ESC, jeśli zaczynasz od zera. Wybierz XP, obraz oraz brak własnego Unattended; następnie dysk i `TAK`. Po przygotowaniu wyjmij USOS i włącz komputer z dysku. Pierwszy etap wykona się sam. Jeśli po jego restarcie zamiast GUI jest czarny ekran, uruchom USOS i użyj CONTINUE XP zgodnie z sekcją 18. Obecnie to świadomy kompromis, a nie pełne usunięcie etapu Text Mode.
