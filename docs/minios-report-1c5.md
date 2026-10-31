# MiniOS 1c5 — STOP z postępem; pełna bramka Win11/128 PASS

2026-10-26. Gałąź `codex/minios-etap1`. Wyniki wyłącznie QEMU/host, bez integracji, merge, push, deploy, G: i nośników fizycznych. Kod produkcyjny4431f6e6; późniejsze commity dokumentują zamknięte dowody. **Win11 WHPX/128MiB: pełne przygotowanie559,36s oraz obie natywne bramki Windows PASS.**

**STOP:** dodatkowa próba Pentium została przerwana wybranym przez autora limitem900s podczas skanu pustego dysku, przed formatowaniem. Nie jest to dowód niezgodności CPU ani zawieszenia. Osobno pełną próbę64MiB blokuje rezerwa100GiB wolnego miejsca. Nie ponawiano prób, nie uruchamiano dalszych pełnych instalacji/BCD/pierwszego startu. Wszystkie własne procesy QEMU zakończone; obrazy zachowane. To nie jest zaliczenie całego1c5 ani1c-3.

## Co naprawiono

Profilowanie jest domyślnie wyłączone. PM timer służy wyłącznie do jednorazowej, ograniczonej kalibracji RDTSC na starcie. Gorąca ścieżka nie czyta portu PM. Odczyt TSC ma kontrolę CPUID, oddzielną ścieżkę dla i486 bez TSC, sprawdzanie monotonii i kontrolę zgrubnym RTC tylko przy granicach postępu. Niepewny zegar daje jawny brak pomiaru. To pomiary zagregowane, bez serializacji instrukcji.

BIOS ma ograniczony, tylko odczytowy czytnik CMOS: spójne próbki, kontrola UIP/VRT/SET, BCD/binary, 12/24 h i daty. Nie zależy od obsługi IRQ zegara. Audyt instrukcji IA32/BIOS nadal odmawia SSE/CMOV i innych instrukcji niezgodnych z celem; wyjątkowo dopuszcza dokładnie sprawdzony, warunkowy blok RDTSC. Test gościa 486 pozostaje osobną bramką.

Runner zapisuje osobno czas gościa i czas hashowania dowodów po jego zamknięciu. Dodano jawny wybór najwyżej dwóch CPU; kontrolowane próby wykonano z maską12, BelowNormal, pojedynczy gość, bez równoległego kompilatora. Dwa inne goście miały maskę3; pozostawiono je bez zmian.

## A/B tego samego buildu

Pełne dane i ograniczenia: `docs/minios-performance-1c5-ab.md`. Odcinek porównawczy: pozycje10151→12613, dokładnie2462 wpisy, 2000 zasobów,10547056 B. Wszystkie te próby celowo przerwano diagnostycznie; żadna nie jest pełną instalacją.

|Para|Skan pustego dysku|Odcinek2462 wpisów|
|---|---:|---:|
|PM, profilowanie WYŁ.|62 s|3 s|
|Ta sama binarka PM, WŁ.|73 s|5 s|
|Nowy zegar, profilowanie WYŁ.|60,684 s|2,652 s|
|Ta sama binarka TSC, WŁ.|65,682 s|3,088 s|

Wcześniejsze3/41 s nie dowodzą13,7-krotnego narzutu PM: pomiar był zakłócony współdzielonymi CPU. Nowy zegar i zmiana CPU były badane osobno; nie przypisano całej regresji jednemu czynnikowi. Liczniki PM przy kalibracji i końcu każdej zakończonej próby A/B nowego zegara TSC są identyczne.

Bufor1MiB: z profilowaniem cel miał24894 wywołania wobec25715 bez bufora. Pierwsza para:0,092311 vs0,081703 ms/wywołanie celu; odwrócona:0,086728 vs0,082403. Średni czas całej fazy z profilowaniem28,1905 vs28,1700 s, praktycznie remis. Bez profilowania:24,916 s z buforem vs27,845 s bez. Zachowano istniejący wariant WŁ. z powodu lepszego zaobserwowanego czasu produkcyjnego i mniejszej liczby wywołań, bez twierdzenia o stabilnej przewadze statystycznej. Wyłączenie oszczędza dokładnie1MiB RAM. Nie przenosić wniosku o buforze UEFI/virtio na BIOS.

## Testy i pochodzenie dowodów

- Dawne721 testów1c1 to105 prep+616 pozostałych. Dawne228 z1c4 to207 prep+21 FAT32: pełnego zestawu projektu wtedy nie uruchomiono. Przed zmianami1c5 pełny zestaw miał846=207+21+618.
- Pełny końcowy Zig:862/862=223 prep+21 FAT32+618 pozostałych, w tym9 testów TSC i7 RTC. `1c5/logs/final-core05.log`, HEAD7104f3c6, czyste drzewo przed i po.
- Pełne odkrywanie Python:340/340, bez skip, z natywnym testem ABI, `1c5/logs/all-python-clean03.log`, HEAD33f43e01. Późniejsza poprawka rozpoznawania etykiety ELF:8 testów i rzeczywisty audyt BIOS. Późniejszy zapis czasu gościa: testy odpowiedniego runnera. Nie twierdzić, że340 testów powtórzono po tych dwóch zmianach.
- UEFI x64/IA32 build i audyt oraz BIOS build/link/pack i486 PASS. BIOS:261492 B payload, zaokrąglony koniec392704, stos od393216:512 B pozostałego odstępu. Nie jest to PASS wykonania BIOS.
- Wszystkie końcowe logi testów/buildów mają HEAD i WORKTREE_DIRTY0, bez zmiany HEAD podczas operacji; niższy priorytet, dwa CPU, Zig-j2. Surowe nieudane próby zachowano i odróżniono od finalnych PASS.

## Win11 x64, WHPX,128MiB

Pełne firmware ISO-na-NTFS→wybrany WIM→świeży GPT/ESP/MSR/NTFS zakończyło się PASS w559,355738 s pracy gościa, czyli9min19,36s, poniżej900s. Cały runner629,254441s obejmuje późniejsze sprawdzanie SHA; nie jest czasem apply. Profilowanie WYŁ., bufor WŁ.,1vCPU,qemu64,-xsave,QCOW2.

168751 wpisów=136696 plików+32055 katalogów;95405 zasobów,13243578352 B apply. SHA-1 wszystkich zastosowanych strumieni wybranej edycji oraz metadanych sprawdzone w trakcie pracy. Firmware wydał końcowy PASS dopiero po trwałym flush. Źródło i bazy niezmienione.

Peak12044492 B=11,4865MiB, wliczając własny stos1MiB; stack high-water417768B≈407,98KiB, canary OK, po zwolnieniu alloc_current0. To pamięć programu bez firmware, nie minimalny RAM całej maszyny. Licznik PM zakończył się na5336 tak jak przy kalibracji, profilowanie wyłączone.

Dowody względem puli: `1c5/win11-final/whpx128-01/{result.json,debug.log,serial.log}`. HEAD4431f6e6, czyste drzewo. EFI SHA-256 `058b08519d5a338f05104c51fd9eafbdc0bd12d9607c18cf8a4d85f29b30a196`; cel QCOW2 `8677e5452ba4d749a8f7873fc7da4855625bed819d5678e0524a6c3a50a47142`. To zakończenie rozpakowania, a nie pierwszy start Windows ani potwierdzenie F5.

## Usunięte obrazy1c4

Wyłącznie trzy wcześniej wskazane i zaakceptowane obrazy usunął ręcznie użytkownik, po dwóch odmowach automatycznego przeglądu poleceń kasowania. Potwierdzono brak dokładnych ścieżek; oryginalne SHA, logi, manifesty i receipt pozostały. Innych obrazów nie usunięto.

|Ścieżka względem puli|Bajty logiczne|SHA-256|
|---|---:|---|
|`1c4/host-baseline/target.raw`|34359738368|`18bd451dea6938bf1161d106beed70525d2e55988fe81a4d216c332e2e452c9c`|
|`1c4/probe-qcow/win11-128/target.qcow2`|8248950784|`1f8cb5b5bf8bc594e3727cf38a64849bac8d13898c86e95c25e224803ac5c69c`|
|`1c23/qemu-x64/win11-whpx128-01/target.vhd`|9055683072|`a6346851a830b7d546076123f56f1a37703880c5377a3b92a2e92881076d92b1`|

Spis: `1c5/accepted-1c4-cleanup.json`. Suma logiczna51664372224B; rozmiar pliku sparse nie jest ilością odzyskanego miejsca.

## Niezależna kontrola pełnego Win11

PASS, na tym samym czystym HEAD4431f6e6. Jedna końcowa kopia dynamic VHD15027732480B służyła kolejno kontroli FAT32 i NTFS, wyłącznie ReadOnly. Nie utworzono drugiej pełnej kopii. Przed użyciem aliasu Windows sprawdził tożsamość FileBackedVirtual, flagi nie-systemowy/nie-boot/read-only, dokładne32GiB i układ partycji. `chkdsk` BEZ przełączników: ESP FAT32=0, Windows NTFS=0.

Pełne168751 wpisów: brakujące0, dodatkowe0, różne0, błędy odczytu0. Sprawdzono82533 nazwy8.3. SHA, ADS, czasy, atrybuty, reparse i zabezpieczenia zgodne z niezależną wyrocznią i dotychczas jawnymi zasadami RP_FIX/root/aliasów hardlinków. Niezależny parser on-disk NTFS/SDS:377 deskryptorów i168751 odwołań, PASS. Źródła, bazy, oczekiwane manifesty i VHD nie zmieniły się podczas kontroli.

Receipt `1c5/native-win11-128/result.json`; FAT32 `native-partition-1/result.json`, NTFS `native-partition-3/result.json`, parser `raw-security.json`. VHD SHA-256 `7ff67181a910ee9461211ea5fe9b2e34958be41a30c102cd9356a40560848907`. Skrót dowodów z dokładnymi SHA: `docs/minios-win11-1c5-128.json`; opis: `docs/minios-win11-1c5-128.md`. Zamknięty kawałek otrzymał commitffe7620e.

## Pojemność i następna bramka

Preflight kolejnego pełnego Win11/64MiB odmówił PRZED utworzeniem obrazu i uruchomieniem VM: `Operation would violate the 100 GiB free-space reserve`. Zapisany stan: wolne110870654976B≈103,26GiB, rezerwa100GiB, budżet nowego celu18GiB. Log z czystego HEADffe7620e: `1c5/logs/next64-capacity01.log`; wynik `1c5/capacity-next64-01-result.json`. Projektowana pula z rezerwami mieści się w150GiB; blokuje faktyczne wolne miejsce na dysku, a nie czas gościa ani błąd instalacji.

Osobne pytanie o akceptację14 zamkniętych, starych celów testowych pozostaje oczekujące; brak odpowiedzi nie jest zgodą. Dokładne ścieżki, rozmiary i SHA z zamkniętych receipt: `1c5/capacity-cleanup-proposal.json`,37646828032B logicznie≈35,06GiB. To dwa cele zaakceptowanego1c1 oraz niepełne próby1c4/1c5. Nie usunięto żadnego z nich. Nowy pełny Win11 i jego VHD są poza propozycją. Wszystkie małe dowody pozostają. Nie rozszerzono puli, nie przenoszono niczego na inny dysk i nie naruszono rezerwy100GiB.

## Małe wykonanie finalnego BIOS na starych CPU

Obie próby użyły identycznej finalnej binarki BIOS SHA-256 `60111b65f563f3d73481ed52b21eee440fac6ba89cacfd5493707d86e1c6d1a7`, TCG,32MiB, czystego HEADffe7620e, maski12 i niższego priorytetu. Własny XPRESS:391plików+20katalogów, źródłowy ISO-na-NTFS z wcześniej niezależnie potwierdzonymi bajtami. Dysk wirtualny8GiB to dolna dozwolona granica obecnego instalatora; koszt pełnego skanu dominuje mimo małego zestawu plików.

|CPU|Wynik|Czas i pamięć|
|---|---|---|
|486|PASS wykonania firmware, bez natywnego chkdsk|890,115s; skan885s, apply3s; peak alokatora3949526B, physical_heap_peak3954224B; stos217072/253952B, guard4096 nienaruszony, końcowa pamięć0.|
|Pentium|NIEZALICZONA, timeout900s|Ostatni skan8321499136/8589934592B=96,875%,874s; ostatnia poprawna linia postępu to około9,08MiB/s. Brak formatowania i apply.|

486 zgłosił `no_tsc` i zero odczytów PM, więc rzeczywiście wykonał ścieżkę bez RDTSC. Pentium wykonał kalibrację TSC i kontynuował skan. Ustawiony przeze mnie900s limit okazał się zbyt ciasny dla drugiej próby; nie zaliczam jej na podstawie ekstrapolacji. Po zamknięciu porównanie logiczne `qemu-img compare` celu Pentium z jego pustym checkpointem dało0: wszystkie bajty wirtualnego celu nadal takie same. Źródła, bazy i entropia obu prób bez zmian. Nie ponowiono Pentium i nie uruchomiono zaplanowanego natywnego sprawdzania tych małych celów po nieudanej próbie.

Pełne receipt: `1c23/qemu-bios/tcg486-1c5-01/result.json`, `tcgpentium-1c5-01/result.json`; log porównania `1c5/logs/pentium-closed-compare01.log`. Podsumowanie: `docs/minios-bios-1c5.json`, commit53f676c7. To potwierdza minimalny przetestowany CPU486 i32MiB tylko dla własnego małego zestawu BIOS. Pełny Windows7/BIOS nadal nieuruchomiony. UEFI x64: zmierzona pełna próba128MiB/qemu64; IA32 ma build/audyt i486, bez pełnego uruchomienia1c5, zatem nie podaję nowego minimum RAM/CPU firmware IA32.

Nieblokujące ostrzeżenie GLib hosta pozostaje w surowym stderr; nie było przedmiotem dochodzenia.

## Stan F-a…F-i oraz pozostałe ograniczenia

|Punkt|Stan|Zakres dowodu/ograniczenie|
|---|---|---|
|F-a, maska UDF0x1800|PASS wcześniej, bez regresji w pełnym zestawie|Bit System pozostaje odczytywalny.|
|F-b, backup anchors|PASS testów|Po błędnej256: N-256 oraz N.|
|F-c, unsupported skip/count|PASS testów|Odmowa dopiero przy żądanym nieobsługiwanym wpisie; uszkodzone struktury nadal odmawiane.|
|F-d, limit drzewa|PASS testów|Wspólny walker,1M fizycznych wpisów.|
|F-e, oryginalny błąd Stream|PASS testów|Zachowany w logu i adapterze.|
|F-f, ATTRIBUTE_LIST/>128runów|PASS ograniczonego zakresu|Do8192 runów DATA pliku; wcześniejsza kopia Windows512runów/3extenty. ATTRIBUTE_LIST samego MFT nadal jawnie odmawiany.|
|F-g, ESD/SWM|PASS diagnostyki|Pełne solid ESD/SWM poza zakresem obecnej ścieżki.|
|F-h, SYS/CER|Audyt wcześniej PASS; integracja oczekuje|Referencja master0ba50f6e:34 vs74 na gałęzi. W1c5 zero zmian SYS/CER. Integracja wyłącznie cherry-pick ścieżek MiniOS, bez acpi.sys.|
|F-i, stare kopie VHD1c1|Usunięte we wcześniejszym etapie za osobną zgodą|4 pliki/47244642304B, osobny zachowany receipt; nie mylić z trzema obrazami1c4 usuniętymi teraz przez użytkownika.|

Pominięte metadane Win11 typu4 (F5) nadal wymagają potwierdzenia udanym pierwszym startem Windows; chkdsk0 nie zastępuje tej bramki. Pełne64MiB, Win10IA32, Win7BIOS, BCD kontra bcdboot, zapis boot files i pierwszy start Windows nie są zaliczone. Mały test BIOS z własnymi danymi nie jest instalacją Windows7.

Przegląd pomocniczego runnera pierwszego startu wykazał, że jego dotychczasowy budżet2GiB był sprawdzany dopiero po zakończeniu; QMP EOF nie budził całego oczekiwania, limit endpointu wynosił900s. Drugi agent przygotował jedynie projekt naprawy (bounded raw→QCOW, błędy/QMP EOF,10800s), poza śledzonym drzewem. Projekt NIE zastosowany i NIE testowany. Limit całego scope, w tym logów i zrzutu, nadal wymaga domknięcia przed pierwszym startem; nie zaliczać tej pracy jako gotowego narzędzia.

## Commity tego podejścia

|Commit|Zamknięty zakres|
|---|---|
|ffb1df78|Trzy brakujące dokumenty1c4, commit przed nowymi zmianami.|
|ac7230bb|Jedna binarka z przełącznikami diagnostycznymi profiler/bufor i celowym końcem próby.|
|ed8ab512|Jednorazowa kalibracja TSC, domyślnie wyłączone profilowanie, testy.|
|0edd8249|Pełne odkrywanie testów Python/izolowany import i rzeczywisty test timeout.|
|347de79b|RTC BIOS, wybór CPU, świeży eksport audytu IA32.|
|3ab4309c,33f43e01|Poprawki dwóch fixture RTC; błędne próby zachowane.|
|7104f3c6|Ścisłe rozpoznanie chronionego bloku TSC w audycie ELF.|
|1c61b0e0|Zamknięty raport kontrolowanych A/B.|
|4431f6e6|Czas gościa oddzielony od hashowania po jego zakończeniu.|
|ffe7620e|Pełny firmware i obie natywne bramki Win11/128 z pinami dowodów.|
|53f676c7|Wykonanie486 PASS, timeout Pentium i spis zachowanych obrazów.|

## Zamknięcie i zachowane dowody

Zachowano72 nowe obrazy/NVRAM/artefakty w puli,41489868800B logicznie≈38,64GiB. Dokładna lista z SHA i źródłem każdego hasha: `docs/minios-retained-images-1c5.json` oraz `1c5/retained-images.json`. Duże hashe pochodzą z zamkniętych, przypiętych receipt, małe obrazy przeliczono po zakończeniu wszystkich własnych operacji. To nie jest twierdzenie, że ponownie zahashowano każde duże stare źródło.

Punkt pomiaru `1c5/closed-capacity.json`: pula119400163110B≈111,20GiB z konserwatywnymi rezerwami nieczytelnych starych fixture, limit150GiB; wolne110705827840B≈103,10GiB. Małe kopie operatorów powstały po tym pomiarze; nie zmienia to zaokrąglonego wyniku ani spełnienia limitów. Nowych obrazów nie usunięto. Jedyną wykonaną w tym podejściu operacją usunięcia były3 zaakceptowane stare obrazy usunięte ręcznie przez użytkownika, wyszczególnione wyżej.

Końcowa tylko odczytowa kontrola pinów receipt, czystości logów i zakresu ścieżek: `1c5/logs/closed-evidence02.log`, HEAD53f676c7, PASS. Pierwsza próba tego pomocniczego sprawdzania błędnie wymagała SPDX dokładnie w pierwszym wierszu zamiast akceptować poprawny nagłówek dokumentacyjny Zig w drugim; poprawiono wyłącznie checker, log01 zachowano. Od początku1c5 zero zmian `.sys`/`.cer`, wspólnego legacy BIOS i globalnego packera. Projekt pierwszego startu i wszystkie operatory pozostają dowodami lokalnymi, nie zmianą produkcyjnego przebiegu.

**Dalsze wymagane kroki po decyzji użytkownika i wznowieniu:** rozstrzygnięcie niepełnej próby Pentium, pojemność, pełne Win11/64MiB, Win10IA32 i Win7BIOS z natywnymi bramkami; następnie BCD kontra rzeczywisty bcdboot, boot files, pierwszy start TCG i logi Panther/F5. Obecny raport nie daje PASS żadnemu z tych niewykonanych punktów. STOP bez automatycznej kontynuacji.

Raport i kompletne podsumowanie maszynowe: `docs/minios-report-1c5.md`, `docs/minios-evidence-1c5.json`. Przygotowany operator `native-1c5-bios-small.py` nie został uruchomiony. Finalne kopie operatorów i nieprzetestowany projekt pierwszego startu zachowano w `1c5/operators/`.
