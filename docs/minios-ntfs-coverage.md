<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# MiniOS — pokrycie NTFS, runda 1c7

Audyt od stanu21113b5b, aktualizacja po poprawkach1c7. To przegląd implementacji, nie deklaracja
pełnego sterownika NTFS. „Tak” dotyczy opisanej funkcji; ograniczenia są jawne.
Odczyt oznacza kod Zig wykonywany przez MiniOS, nie pomocnicze inspektory Python.
„Nie dotyczy” oznacza, że instalator nie wykonuje danej operacji; Windows po
starcie nadal musi otrzymać poprawne struktury. Wiersze do naprawy aktualizujemy
z testami i commitami w tej samej rundzie.

## Materiał i pochodzenie

Nowe ustalenia o NTFS pochodzą wyłącznie z lokalnego NT5:
`doors/Microsoft source code/nt5src/Source/XPSP1/NT/base/fs/ntfs/`.
Przegląd rozpoczęto od ntfsstru.h: opisuje VCB/FCB/SCB i inne obiekty pamięci,
więc nie traktujemy ich jako struktur na dysku. Definicje dyskowe są w ntfs.h.
Mechanizmy sprawdzane w attrsup.c, mftsup.c, indexsup.c, allocsup.c,
bitmpsup.c, checksup.c, colatsup.c, secursup.c, reparsup.c, objidsup.c,
ea.c, logsup.c oraz restrsup.c. Nie korzystamy z Internetu.

To własny kod Zig oparty na rozumieniu mechanizmu; nie przenosimy tekstu NT5.
Wcześniejsza implementacja ma również własne historyczne atrybucje, których nie
usuwamy ani nie przedstawiamy jako wyników tej analizy. NT5 nie jest opisem
wszystkich rozszerzeń Vista–11; brak potwierdzenia zaznaczamy, zamiast zgadywać.

## Macierz struktur i przypadków

|Struktura/przypadek na dysku|Zapis Zig|Odczyt Zig|Zakres, luka lub dowód|
|---|---|---|---|
|Boot sector/BPB i kopia końcowa|tak|tak|Writer512B/4KiB klastry; reader512/4096B sektory. Kod BIOS rozruchu to osobny etap. ntfs.h PACKED_BOOT_SECTOR.|
|Partycja, granice i geometria NTFS|tak|tak|Weryfikacja zakresów i przepełnień, nie montowanie hosta.|
|FILE record, USA/fixup i torn write|tak|tak|record.zig oraz walidacja czytnika; nie naprawiać uszkodzonych sektorów przy odczycie. ntfs.h FILE_RECORD_SEGMENT_HEADER, checksup.c.|
|Sequence number, base reference, extension record|tak|tak|Resolver sprawdza sekwencję, bazę, instance i kolejnośćVCN; odmowa duplikatu/luki/obcej bazy. mftsup.c/attrsup.c; testy syntetyczne i realny cel1c5.|
|$MFT DATA, dynamiczny wzrost i fragmentacja|tak|tak|Heapowy resolver listy własnego MFT, także lista nierezydentna. Rozszerzenia muszą być dostępne przez znany prefiks. Realny1c5:13runów, SHA przed/po bez zmian.|
|$MFTMirr|tak|nie dotyczy|Writer aktualizuje pierwsze rekordy. Reader sprawdza kopię przez testy; brak automatycznego naprawiania/replay.|
|$MFT:$BITMAP, reuse rekordów|tak|nie dotyczy|Allocator writer korzysta z bitmapy; boot-source nie przydziela rekordów.|
|0x10 $STANDARD_INFORMATION|tak|tak|Czasy, flagi i SecurityId. Pełna semantyka quota/USN nie jest zadaniem czytnika boot-source.|
|0x20 $ATTRIBUTE_LIST, rezydentny|tak|tak|DATA pliku i bootstrap MFT, typ/nazwa/VCN/instance/sequence/base. Ogólne rozszerzenia każdego typu atrybutu nie są zaimplementowane.|
|0x20 $ATTRIBUTE_LIST, nierezydentny|tak|tak|Fragmentowane dane listy, do256KiB, do8192runów. attrsup.c nie przenosi samej listy do osobnego rekordu; brak rekurencyjnego zgadywania jej mapy.|
|Lista z duplikatem, pętlą, luką VCN lub obcym rekordem|nie dotyczy|tak|Odmowa dla zwykłego DATA oraz bootstrap MFT; ograniczone długości i liczba segmentów.|
|0x30 $FILE_NAME, namespace0/1/2/3|tak|tak|Długie nazwy, aliasy8.3, porównanie Unicode; nie dublować aliasów w listowaniu.|
|Hardlinki i wiele FILE_NAME|tak|tak|Lookup przez każdą nazwę. Listowanie zachowuje różne nazwy tego samego MFT; pomija tylko alias namespace2. Poprawka i test1c7.|
|0x40 $OBJECT_ID|tak|nie dotyczy|WIM tagged ObjectID i indeks $ObjId:$O; boot-source nie rozwiązuje plików przez ObjectID.|
|0x50 $SECURITY_DESCRIPTOR|tak|nie dotyczy|Nowy wolumin3.1 używa SecurityId/$Secure, nie wymaga lokalnego SD w każdym rekordzie.|
|0x60 $VOLUME_NAME|tak|nie dotyczy|Własna etykieta; brak zmiany cudzej etykiety.|
|0x70 $VOLUME_INFORMATION, wersja i flagi|tak|tak|Writer dirty do finish. Reader dopuszcza3.0/3.1; odmawia dirty, resize-log, upgrade, delete-USN, repair-object-ID i nieznanych flag. Nie usuwa ich i nie wykonuje replay.|
|0x80 $DATA rezydentny, pusty plik|tak|tak|Małe dane i zerowa długość; kontrola granic rekordu.|
|0x80 $DATA nierezydentny, >4GiB|tak|tak|64-bitowe długości, strumieniowanie, bez bufora całego pliku.|
|Mapping pairs, signed LCN delta, wiele runów|tak|tak|Zwykłe LargeFile do8192 runów; małe metadane nadal fixed128. ntfs.h i attrsup.c.|
|ValidDataLength < FileSize|tak|tak|Heapowy reader zeruje ogon bez odczytu nośnika; dla MFT/listy metadanych wymaga pełnej inicjalizacji. read.c i test szpiegujący odczyty. Stare małe API odmawia.|
|0x90 $INDEX_ROOT dla $I30|tak|tak|Rezydentny mały katalog. ntfs.h INDEX_ROOT i indexsup.c.|
|0xA0 $INDEX_ALLOCATION + USA/INDX|tak|tak|Writer B+drzewo, wiele bloków; reader paginuje. Rozszerzenia tych atrybutów przez listę nie są jeszcze pełnym resolverem.|
|0xB0 $BITMAP indeksu $I30|tak|nie|Writer utrzymuje bitmapę. Reader przechodzi osiągalne wskaźniki INDX i sprawdza granice/USA/VCN; nie uzgadnia bitów bitmapy. Nie deklarować pełnego sprawdzania integralności indeksu.|
|Kolacja i indeksy inne niż $I30|tak|nie dotyczy|Writer secure_index dla $SII/$SDH/$O/$R/quota. Boot-source szuka ścieżek, nie wykonuje zapytań tych indeksów.|
|$Bitmap, ponowne użycie wolnych klastrów|tak|nie dotyczy|Writer runs/bitmap, brak założenia jednego ciągłego obszaru; testy fragmented/full disk.|
|$LogFile, świeży stan czysty|tak|nie dotyczy|Writer tworzy dwie chronione strony RSTR1.1, LFS_CLEAN_SHUTDOWN; utrzymuje volume dirty do flush/finish. Windows chkdsk0 i rzeczywisty start Win11 do usług potwierdzają akceptację świeżego logu. Bez pełnego czytnika LFS.|
|$LogFile replay istniejącego brudnego woluminu|nie dotyczy|nie|Cel zawsze świeży; źródło tylko do odczytu. Nie naprawiać ani odtwarzać transakcji bez osobnego zakresu.|
|$UpCase i kolacja Unicode|tak|tak|Heapowy reader ładuje rzeczywistą tabelę woluminu, do128KiB, w odczytach do64KiB; sprawdza rozmiar/idempotencję. Porównanie UTF16 z tabeli, także polskie znaki. Stary mały reader bez tabeli tylkoASCII.|
|$UpCase:$Info Windows8+|tak|nie dotyczy|Istniejący kod/historyczne testy. W przejrzanym NT5 brak opisu nowego mechanizmu; niczego tu nie zgadujemy.|
|$Secure:$SDS, duplikat i SecurityId|tak|nie dotyczy|Writer deduplikacja SD, native SDS/tree/SD PASS1c5. secursup.c/ntfs.h.|
|$Secure:$SII i $SDH, kolizje hashy|tak|nie dotyczy|Writer wieloblokowe indeksy, osobno kluczID/hash+ID. Boot-source nie jest menedżerem uprawnień.|
|0xC0 $REPARSE_POINT, junction/symlink|tak|tak|Writer zapisuje i indeksuje. Reader rozpoznaje SI/atrybut i jawnie odmawia podążania, również w katalogach źródła. Nie jest resolverem junctionów/symlinków; reparsup.c.|
|WIM RP_FIX|tak|nie dotyczy|Zakończone1c0; mechanizm WIM nie wynika z NT5 NTFS. Zachować już zweryfikowany kontrakt.|
|Sparse DATA/hole|tak|tak|Heapowy reader zeruje dziury bez IO. Sparse w metadanych MFT/listy odmawiany. Mapping pairs z ntfs.h/allocsup.c; test danych→dziura→dane i ogona VDL.|
|NTFS compressed DATA, pełne fizyczne jednostki|tak|tak|Writer zachowuje flagę, emituje pełne surowe16-klastrowe jednostki. Reader dopuszcza je; to nie LZNT1. rwcmpsup.c opisuje powrót do nieskompresowanego strumienia dla pełnej jednostki.|
|NTFS compressed DATA, jednostki faktycznie skompresowane LZNT1|nie|nie|Reader zwraca UnsupportedCompression dla krótkiego prefiksu fizycznego plus hole; nie wydaje skompresowanych bajtów jako pliku. Nie wymaga tego własny zapis WIM, który emituje pełne jednostki.|
|EFS/encrypted DATA|nie|nie|WIM preflight odmawia. Brak kluczy, nie obiecywać obsługi.|
|ADS/nazwane DATA|tak|nie|Writer i WIM zapisują ADS. MiniOS czyta ISO i pliki rozruchowe przez unnamed DATA; nie oferuje publicznego API odczytu ADS. Windows otrzymuje strumienie, co sprawdzają wcześniejsze bramki WIM/native.|
|0xD0 $EA_INFORMATION +0xE0 $EA|tak|nie dotyczy|Writer waliduje/zapisuje WIM EA; boot-source nie wykonuje zapytańEA. ea.c/ntfs.h.|
|0x100 $LOGGED_UTILITY_STREAM|nie|nie|Definicja jest w NT5 public/internal/base/inc/ntfsexp.h, NtOfsCreateAttributeEx. $AttrDef writera zna typ; brak tworzenia/logowania takich strumieni. Nie jest potrzebny do emisji zbadanych WIM; nie utożsamiać z TXF.|
|$BadClus:$Bad|tak|nie dotyczy|Świeży wolumin bez wad, sparse mapa logiczna; nie skanować fizycznego nośnika w tej rundzie.|
|$Extend/$Quota/$ObjId/$Reparse|tak|nie dotyczy|Tworzenie wymaganych pustych struktur i aktualizacja własnych rekordów/indeksów.|
|$UsnJrnl i transakcje/TXF nowszych Windows|nie dotyczy|nie|Nie tworzymy dziennika zmian użytkownika; nowszych rozszerzeń nie wyprowadzamy z braku definicji NT5.|
|Nieznany atrybut/flag/format|nie dotyczy|tak|Odmowa gdy potrzebny do celu; nigdy ciche czytanie niepełnego strumienia.|

### Odczyt ISO z pofragmentowanego woluminu Windows

Obraz skopiowany i pofragmentowany przez Windows, z 512 runami i trzema
extentami DATA, otrzymał wcześniej wynik `chkdsk` 0. Aktualny czytnik odmawia
otwarcia go z `UnsupportedVolumeState`: w `$VOLUME_INFORMATION` jest flaga
`0x0080`, której znaczenia nie znaleziono w przejrzanych źródłach NT5. To
ograniczenie także dla poprawnych woluminów; nie uznajemy wcześniejszego PASS
starszego czytnika za PASS obecnego. SHA obrazu przed i po odczycie identyczny.

W osobnej symulacji kontrolnie wyzerowano ten bit wyłącznie w jednym buforze
odpowiedzi czytnika, bez modyfikowania obrazu. Nowy czytnik odczytał 512 runów
i trzy extenty, a SHA-256 ISO zgodził się z niezależnym wynikiem. Ten test
potwierdza obsługę fragmentacji przy symulowanym stanie woluminu; nie wyjaśnia
znaczenia flagi ani nie dowodzi, że można ją ignorować na rzeczywistym dysku.

## Ustalone poprawki tej rundy

1. Resolver $MFT z listą i rekordami rozszerzeń, również lista nierezydentna;
   źródło: ntfs.h ATTRIBUTE_LIST_ENTRY, attrsup.c NtfsLookupExternalAttribute/
   NtfsMapAttributeValue, mftsup.c NtfsReadMftRecord. Test tylko do odczytu celu1c5.
2. Zera w dziurach sparse i ogonie nieinicjalizowanym oraz jednoznaczna odmowa
   reparse/encrypted/compressed, chyba że pełny mechanizm potwierdzimy w NT5
   i przetestujemy. Nie oznaczać takich przypadków jako zwykłych danych.
3. Pozostałe luki wymagane przez rzeczywisty install.wim/bootfiles ujawnią
   bramki; naprawiać w zakresie, do pięciu poprawek na rundę. Nie przekształcać
   instalatora w pełny działający sterownik Windows.

## Szczegółowe granice odczytu i zapisu

- Zapis dotyczy wyłącznie świeżo sformatowanego celu. Nie montuje istniejącego
  NTFS do modyfikacji i nie jest implementacją odzyskiwania po awarii.
- $AttrDef: writer emituje definicje systemowe; reader nie używa go do
  interpretacji nowych typów. Nieznany wymagany format kończy się odmową.
- Atrybuty rezydentne: kontrola długości/offsetów; nierezydentne:64-bitowe VCN,
  signed LCN delty, granice woluminu, brak nakładających się fizycznych runów.
  Heapowe DATA i MFT mają8192runów; legacy metadane/I30 mają128runów.
- I30: resident INDEX_ROOT, USA i VCN w INDX, cykle i limit256 odwiedzonych
  bloków. ATTRIBUTE_LIST dla INDEX_ROOT/INDEX_ALLOCATION/BITMAP nie jest
  ogólnym resolverem. Taki wymagany przypadek odmawia, nie czyta części danych.
- $MFTMirr i backup BPB są tworzone i sprawdzane przez wcześniejsze niezależne
  bramki. Reader nie zastępuje uszkodzonej kopii i nie zapisuje naprawy.
- $Secure/SII/SDH i inne indeksy systemowe są tworzone przez writer; czytnik
  źródła nie jest menedżerem ACL, quota, ObjectID ani logów transakcyjnych.
- EFS, replay brudnego woluminu, LZNT1 i współczesne TXF/WOF nie są obsługą
  domyślną. Nie wymyślamy nowych struktur Vista–11 na podstawie NT5.

## Ślad przeglądu lokalnego NT5

|Plik|Sprawdzony mechanizm / odniesienie w naszym kodzie|
|---|---|
|ntfsstru.h|VCB/FCB/SCB są strukturami w pamięci, nie formatem dysku.|
|ntfs.h|BPB/FILE/ATTRIBUTE_RECORD/ATTRIBUTE_LIST_ENTRY, SI/FILE_NAME, Volume, INDEX, typy0x10–0xE0.|
|attrsup.c|NtfsLookupExternalAttribute, NtfsMapAttributeValue, lista nie przenoszona do własnego rekordu; resolver DATA/MFT i limit listy.|
|mftsup.c|NtfsReadMftRecord: numer rekordu→offset w strumieniu MFT, referencje i odczyt; bez przenoszenia automatycznej naprawy mirror.|
|allocsup.c|NtfsLookupAllocation: VCN→LCN albo zakres nieprzydzielony; własne runlisty i sparse.|
|bitmpsup.c|Rozdzielenie przydziału/dealokacji bitmapy woluminu i rekordów; własne bitmapy i reuse.|
|indexsup.c / checksup.c|Typ i kolacja INDEX_ROOT, bounds INDEX_HEADER/ENTRY, FILE/INDX USA; własne B+drzewo i bounded reader.|
|colatsup.c / namesup.c|Porównywanie nazw przy pomocy tablicy Unicode woluminu; własny odczyt UpCase.|
|secursup.c|NtfsInitializeSecurity: SDS oraz SII/SDH z różnymi kolacjami; własny writer/indexy, wcześniejsze native SD/SHA.|
|reparsup.c / objidsup.c / ea.c|Indeksy R/O oraz resident/nonresident EA; zapis istniejących metadanych WIM, jawny brak podążania w readerze.|
|read.c / rwcmpsup.c|Zerowanie poza VDL, rozróżnienie fizycznie pełnej i faktycznie skompresowanej jednostki.|
|logsup.c / restrsup.c|Flush/clean checkpoint i restart/replay są osobnymi operacjami. Własny writer świeżego logu, brak replay źródła.|
|../lfs/lfsdisk.h|RSTR/restart area i LFS_CLEAN_SHUTDOWN istnieją w NT5; nie dopisujemy parsera nowszych wersji logu.|
|public/internal/base/inc/ntfsexp.h|0x100 LOGGED_UTILITY_STREAM, API z logowaniem; sama definicja nie oznacza implementacji TXF.|

## Stan bramek tej rundy

MFT: realny obraz1c5,13runów, trzy pliki boot ze zgodnym SHA1, bez zapisu.
Bootfiles: UEFI x64,140plików/35.5MB na nakładce, baza bez zmian.
Pierwszy Windows: doszedł do uruchamiania usług/setup.exe; setuperr puste.
To jeszcze nie PASS specialize→OOBE/pulpit, więc F5 nadal wymaga końcowej bramki.
Końcowe logi/HEAD i dalszy status znajdują się w RAPORT-MINIOS-1C7.md.
# BIOS program size after the NTFS reader changes

The reader increased the isolated BIOS installer's payload beyond its reserved
low-memory region. The existing, pinned UpCase mappings are now stored as
lossless runs; this changes their representation, not their values. The golden
full-table SHA-256 and all 65,536 individual lookup results are tested. The
generator uses the same runtime template, so regeneration retains the compact
representation and attribution. A BIOS build still has to pass its original
linker, payload and stack-reservation checks; it is not evidence of a Windows
first boot or physical-hardware support.
