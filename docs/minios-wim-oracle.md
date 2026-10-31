# MiniOS 1b-2: niezależna wyrocznia WIM

Zakres: przygotowanie wejść oraz niezależnych manifestów na hoście Windows.
To nie jest wynik zastosowania WIM przez usosprep ani test instalacji Windows.
Nie wykonano `apply`, montowania, zapisu celu NTFS ani wypakowania drzewa Windows.
Oba źródłowe ISO były otwarte z odmową zapisu/usunięcia; ich SHA-256 przed i po
wydzieleniu `sources/install.wim` są zgodne. Archiwa i pełne dowody zostają poza
repozytorium, w `<runtime>`.

## Rzeczywiste wejścia

| Wejście | Bajty ISO | SHA-256 ISO |
| --- | ---: | --- |
| `OS/Windows/Windows 10/Windows 10 22H2 19045.6396 PL x86.iso` | 4467318784 | `d45968dae085e7a28e6531b528b28810e2d8423d581b2629edb1e29367823d7a` |
| `OS/Windows/Windows 7/Windows 7 Ultimate SP1 PL x86.iso` | 2440128512 | `709d041ac53f57d44b5451a757491b9e730feac8b807cf0ace625aadde7e4675` |

Nazwa ISO Windows 7 nie określa wybranego indeksu: faktyczny WIM zawiera pięć
edycji. Jawnie wybrano najmniejszych zwykłych klientów, zgodnie z uzgodnieniem
z właścicielem etapu.

| Archiwum w runtime | Bajty WIM | SHA-256 WIM | Kompresja / indeksy / wybór |
| --- | ---: | --- | --- |
| `inputs/win10-x86/install.wim` | 3782183163 | `dd42df5a5d6b09529602b21f7095c0810ffdd6ff2ef3ca15f30d4ffa91164b38` | LZX, 32768 B; 15 indeksów; **2, Windows 10 Home N**, 19045.6396 x86 PL |
| `inputs/win7-x86/install.wim` | 2119698404 | `edc80120ba3b6325141a3fa1fb9087c7bfd9ccfa6040c7676e0ef26f78d72128` | LZX, 32768 B; 5 indeksów; **1, Windows 7 Starter**, 7601.17514 x86 PL |

`input.json` obok każdego archiwum zawiera źródło, pełne piny, rozmiary,
zamknięte wywołanie 7-Zip i wynik `wimlib-imagex info`. Oryginalne WIM mają
części `1/1`. Nie są split `.swm` ani solid `.esd`. Oba wejścia LZX nie
kwalifikują XPRESS; ten wymaga osobnego fixture i własnego pomiaru budżetu.

## Niezależność i dokładność

`tools/minios/wim_oracle.py` korzysta wyłącznie na hoście z zamrożonego
`wimlib-imagex 1.14.5` i `libwim-15.dll` tej samej wersji. Nigdy nie linkuje ich
z usosprep. Piny:

- EXE: `34c0c4165591ad1f592837ed99d08273c58d6ed3fe0ed6360cf34e7b0739b353`.
- DLL: `ba853ee1e3fc5f5798581f02e8e066ba07a0a2375f0bf444fe981431fd508495`.

Oba rzeczywiste `wimlib-imagex verify` zakończyły się kodem 0. Ta niezależna
weryfikacja czyta zasoby całych archiwów, także pozostałych indeksów. Nie
zastępuje wymagania, by własny rdzeń sprawdzał SHA-1 każdego zasobu, którego
sam używa, ani jego negatywnych prób uszkodzenia danych.

`dir --detailed` zachowano w całości, ale
[implementacja CLI 1.14.5](https://github.com/ebiggers/wimlib/blob/v1.14.5/programs/imagex.c)
drukuje czasy z dokładnością pełnych sekund. Dlatego strumieniowy JSONL
pochodzi z publicznego, niezależnego
[API iteracji wimlib](https://github.com/ebiggers/wimlib/blob/v1.14.5/include/wimlib.h),
przez hostowe ctypes. Natywny probe skompilowany z oryginalnym nagłówkiem
potwierdził ABI Win64: Resource 88 B, Stream 128 B, offset streams 248 B oraz
offsety SD, hardlink ID, czasów i object ID. Nie kopiuje ani nie tłumaczy kodu
Microsoftu.

Manifest zawiera ścieżki, atrybuty, nazwy 8.3, grupy hardlinków i liczbę
dowiązań, SHA-1/rozmiary/położenie każdego strumienia, nazwy ADS, tagi reparse,
surowe SD i ich SHA-256 oraz dokładne trzy FILETIME (100 ns). Wszystkie wpisy
obu wybranych obrazów mają część podsekundową. WIM nie przechowuje czwartego
czasu NTFS changedTime. Uzgodniona transformacja celu: changedTime równe
modifiedTime; osobny fixture NTFS ma zweryfikować cztery różne czasy. W PoC
usosprep nie tworzy nazw 8.3: źródłowe metadane należy walidować i jawnie
logować ich pominięcie, bez deklaracji pełnej zgodności instalacyjnej.

## Wynik manifestów i wymagania NTFS

| Cecha wybranego indeksu | Windows 10 Home N | Windows 7 Starter |
| --- | ---: | ---: |
| Wpisy drzewa | 99220 | 57146 |
| Pliki według faktycznego DIRECTORY bit | 77426 | 47685 |
| Katalogi według faktycznego DIRECTORY bit | 21794 | 9461 |
| Nazwy należące do hardlinków | 40085 | 27858 |
| Kompletne grupy hardlinków | 18941 | 13686 |
| Unikalne deskryptory zabezpieczeń | 328 | 250 |
| Reparse | 2: junction + symlink | 44: 43 junction + symlink |
| Nazwane ADS / EFS / WOF | 0 / 0 / 0 | 0 / 0 / 0 |
| Pliki z atrybutem NTFS compression | **63** | 0 |
| Pliki z atrybutem sparse | 0 | **47655** |
| Nazwy 8.3 | 53762 | 30285 |
| Zerowe pliki | 8 | 28 |

Windows 10 ma skompresowane XML-e w `Windows/servicing/Sessions`; Windows 7
ma dodatkowo dwa skompresowane **katalogi** WER. Atrybutów nie wolno po cichu
uznać za obsłużone na podstawie prawidłowego odczytu payloadu LZX. Pełne
histogramy atrybutów/tagów i przykładowe wpisy zachowano na K. Brak ADS/EFS/WOF
w tych obrazach nie kwalifikuje ich obsługi; ADS i inne wymagane cechy mają
osobne fixture NTFS.

Wszystkie ścieżki są unikalne, rodzice występują przed dziećmi, a grupy
hardlinków są kompletne i zgodne metadanymi. Liczników XML nie należy
utożsamiać z klasyfikacją reparse-directory według bitu DIRECTORY.

Dowody znajdują się w `oracle/win10-homen-index2` i
`oracle/win7-starter-index1`: `manifest.json`, `tree.jsonl`, `security.jsonl`,
`verify.*`, `dir-detailed.*`, `consistency.json`. SHA-256 drzew:

- Windows 10: `5dcc013ac8e45dff09b034025b61bf2ff0a7d289b3eeff456eca7d7a78a582e9`.
- Windows 7: `b51550b140c9e976ac5c1dc92497f3b039598efcd6bc4b9b097485ff539eca80`.

## Guardy i testy

Narzędzie odmawia urządzeń/UNC/ADS/traversal/reparse, obcego katalogu źródła,
nadpisania istniejących dowodów, błędnego pinu/wersji narzędzia, split WIM,
nieprawidłowego indeksu i brakujących/solid zasobów. Sprawdza UID Kioxii i
zostawia minimum 100 GiB wolnego miejsca. Wydzielono jedynie 5,90 GB archiwów,
bez wypakowania ~25 GiB Windows. Cały późniejszy budżet celu, nakładek i
dwóch kopii VHD do chkdsk nadal wymaga koordynacji puli 100 GiB z rootem.
Procesy kończą się blokującym oczekiwaniem; nie ma odczytów postępu.

Testy `test_minios_wim_oracle.py`: **15 PASS**, w tym natywne porównanie ABI,
ujemne guardy i dokładność SD/100 ns/hardlink/ADS/reparse. Uruchomienie:

```
$env:MINIOS_ZIG = '<dokładny lokalny zig.exe>'
python -I -B tools/tests/test_minios_wim_oracle.py
```

Osobny commit `871f036b` zaostrza wspólny health wszystkich źródeł entropii:
all0, allFF i powtórzone słowo 32-bit są odrzucane; kolejne bezpieczne źródło
zachowuje dotychczasową kolejność i gate QEMU. Dziewięć testów modułu PASS.
To detektor awarii, nie estymator entropii. Stary BIOS bez RDRAND pozostaje
fail-closed; zewnętrzny seed ze sticka + bootcounter są odłożonym zakresem,
bez nowego słabego fallbacku w tym etapie.

## Native Windows metadata gate

`tools/tests/minios_chkdsk_readonly.ps1 -ExpectedWimTreeJsonl <tree.jsonl>`
dodaje porównanie do dotychczasowego odczytu nowej, zamkniętej kopii obrazu.
Pozostałe parametry, read-only/file-backed/rozmiar/tożsamość/path guardy i
wywołanie chkdsk **bez przełączników** pozostają w mocy. Sam exit 0 chkdsk nie
oznacza akceptacji, jeżeli drzewo albo metadane różnią się od manifestu.

Hostowy `wim_ntfs_metadata.cs` otwiera tylko pliki z OPEN_REPARSE_POINT:
cztery FILETIME, surowy SD z OWNER/GROUP/DACL/SACL, identyfikator inode i liczbę
hardlinków, strumienie z SHA-1 oraz FSCTL_GET_REPARSE_POINT. Z reparse odcina
wyłącznie 8-bajtowy nagłówek tag/length/reserved, tak jak definiuje WIM; nie
przepisuje absolutnych targetów i nie przechodzi przez junction/symlink.
SD i atrybuty są na razie porównywane ściśle, bez cichej normalizacji API.
SeSecurityPrivilege jest włączany na czas odczytu SACL i przywracany; błąd
uprawnienia oznacza odmowę. Domyślny changedTime to WIM modifiedTime; osobny
fixture może jawnie podać czwarty czas w `changed_filetime`.

Mały natywny test tworzy tylko kilka własnych plików w runtime: znane `abc`,
własny ADS, dwa hardlinki, pusty plik i relatywny symlink. Nie stosuje WIM,
nie montuje obrazu i nie otwiera urządzenia. Dowód `oracle-native-mini03`:
12 warunków PASS, kompletne porównanie pięciu wpisów PASS i kontrolny błędny
SHA-1 FAIL dokładnie jednego wpisu. Cztery odrębne czasy 100 ns oraz surowy
SD zostały potwierdzone niezależnym GetFileSecurityW. Rozszerzona próba
`oracle-native-mini04` obejmuje także porównanie czterech jawnych czasów.
Wynik mini04: **13 warunków PASS**, oba kompletne porównania metadanych PASS,
kontrola błędnego SHA-1 nadal FAIL dokładnie jednego wpisu.

Zachowano wcześniejsze błędy samych testów: mini01 porównywał SD do .NET
Get-Acl, który dodawał SystemAclProtected; zastąpiono go natywnym
GetFileSecurityW. Mini02 miał ujemny literał Int32 dla tagu 0xa000000c;
poprawiono typ oczekiwania na UInt32. Nie były to awarie badanego NTFS.

`test_minios_wim_guard.py` wykonał 13 rzeczywistych ujemnych wywołań PS:
traversal/ADS path, zły FILETIME/SD/SHA1/rozmiar strumienia, zła nazwa ADS,
brak/duplikat root, physical-device path, zły rozmiar/hash raw i źródło z
zapisem. Wszystkie odmówiły **przed** utworzeniem Out/konwersją/montowaniem;
hash własnego 64 MiB raw pozostał zgodny. Dowód: `oracle-ps-guard01/result.json`.

## Oczekiwania osobnego fixture NTFS

`tools/minios/wim_feature_manifest.py` nie czyta obrazu ani wyniku naszego
formattera. Buduje oczekiwania wyłącznie ze stałego kontraktu publicznych
`populate`, `Pattern`, `securityDescriptor`, `reparseBuffer` w
`src/prep/wim_ntfs_tests.zig`, SHA-256
`1b813f1d22d49220de4571f3d5d599051fea49070a4aa2cc02a959f667ae3ca5`.
Zmiana kontraktu wymaga przeglądu przed ponowną generacją. SID/ACL/reparse
są niezależnie serializowane w Pythonie, a SHA-1 liczy hashlib strumieniowo.
Zestaw wartości potwierdził właściciel NTFS; nie użyto odczytu jego targetu
do ustalenia danych oczekiwanych.

Gotowe `feature-expected01/{tree.jsonl,security.jsonl,manifest.json}` w `<runtime>`

- 5014 wpisów: 5007 plików, 7 katalogów z root/junction.
- 5001 unikalnych SD, 5000 pustych `Security/s0000`–`s4999` z oddzielnymi SID.
- Dwie pozostałe nazwy hardlinka, każda z tymi samymi dwoma ADS; usuniętego
  `Links/original.bin` nie ma w oczekiwanym drzewie.
- Osobne sparse, dense-sparse, compressed, zero; SHA-1 jest obliczony z
  **logicznej** zawartości, bez założenia o działaniu naszego dekodera NTFS.
- Junction zachowuje `\??\C:\Links\Target`, symlink względne
  `..\Links\third.bin`; hash danych reparse wyklucza wyłącznie nagłówek 8 B.
- Cztery jawne czasy dla hardlinków, zero i junction, pozostałe domyślne.
  To oddzielny test cech NTFS, poza transformacją trzech czasów WIM.
- Raw SI/FILENAME attrs są zapisane osobno od atrybutów Windows API, gdzie
  DIRECTORY jest syntetyzowany. Root oczekuje 0x16, zwykłe katalogi 0x30,
  junction 0x410, symlink 0x420. SD nie są normalizowane.

Tree SHA-256: `d631ecf7a0053101598c14f3135775615b24cc37da7dab78c783a546105b5668`.
Security SHA-256: `8caf301c4a7cd1f90d0dbaabc97aaf050fbb0477f624226ed947a0096f70df53`.
Osiem testów kontraktu PASS, w tym znany wektor bajtów, niezależność SHA-1 od
granicy bufora, 5001 unikalnych SD, kompletne hardlinki/ADS i niezmienione
targety reparse. **To nadal oczekiwania, nie PASS targetu.** Osobny nowy
format/populate/finish oraz Windows read-only gate prowadzi root.

### Pierwszy rzeczywisty Windows gate: wykryty błąd

Root utworzył nowy 256 MiB target `feature-case01/target.raw`, SHA-256
`fd9754451574151474eb9ccd5d2831fed8bcffda56ee5743249a27160481c754`,
przez świeży COW → format → populate → finish z core `6e54614e`.
Pierwsza preflight odmowa dotyczyła braku atrybutu ReadOnly na oryginale;
nie zmieniono go. Utworzono osobny `oracle-input01.raw`, SHA identyczne,
z odmową zapisu/usunięcia źródła podczas kopiowania i hash przed/po. Tylko
własna kopia otrzymała ReadOnly. Zachowano preparation receipt.

`windows01` odczytał 5006 wpisów, po czym przerwał na błędzie otwarcia
strumienia. Wynik FAIL zachowano. Diagnostyczna poprawka samej wyroczni
raportuje teraz kontekst CreateFile/FindStream oraz traktuje błąd odczytu
jednego pliku jako FAIL, kontynuując wyłącznie pozostałe odczyty RO i osobny
chkdsk. Nie może z tego powstać akceptacja przez sam chkdsk exit 0.

`windows02` na **tej samej kopii i tym samym core** zakończył się:

- Dokładnie 5014 oczekiwanych i rzeczywistych nazw, brak missing/extra.
- 5000 własnych custom SD ma zgodne surowe SHA-256. Dwanaście domyślnych SD
  ma inny hash natywnego API; nie wprowadzono normalizacji ani PASS.
- CreateFile z GENERIC_READ odmawia otwarcia ADS `large-世界` pod oboma
  hardlinkami: `Links/third.bin` i `Streams/survivor.bin`.
- Odczytane pozostałe attrs, czasy, sparse/compressed i dane reparse są
  zgodne. To nie kwalifikuje dwóch plików z nieodczytanym dużym ADS.
- **Read-only chkdsk exit 3**: `Attribute records for file record segment
  13A8 are unsorted.` Nie użyto żadnego przełącznika naprawczego.
- Alias usunięty, VHD odmontowany; raw, manifest i VHD mają zgodne hashe
  przed/po. Źródłowy target pozostał bez zmiany.

To rzeczywisty **FAIL cech NTFS**, przekazany właścicielowi core z konkretnym
reproduktorem. Nie podjęto pełnego WIM apply. Obrazy, kopie i pełne dowody
`feature-case01/windows01` oraz `windows02` zachowane do raportu końcowego.

### Domyślny SD: raw na dysku a serializacja Windows API

`wim_security_readonly.py` odczytał **rzeczywiste** MFT5 SI oraz
MFT9 `$Secure:$SDS` z tej samej zamkniętej kopii raw, z pinem SHA przed/po.
Korzysta z istniejącego niezależnego hostowego parsera NTFS, bez importowania
writera, montowania ani ponowienia Windows gate. Root SI wskazuje securityID
256; nagłówek pierwszego SDS ma ten sam ID, offset 0 i długość 144 B. Primary
i kopia SD w SDS są identyczne, a surowy descriptor 124 B jest **dokładnie**
zgodny z fixed expected, SHA-256
`fad9d84f4bf8e3934696b419e32db665a7e519ce3043a300dce6f9554638d0d9`.

Różnica w hash API jest wyłącznie porządkiem serializacji sekcji:

| Pole | Raw NTFS | Rekonstrukcja formy API |
| --- | ---: | ---: |
| Control | 0x8004 | 0x8004 |
| DACL offset | 20 | 52 |
| Owner SID offset | 92 | 20 |
| Group SID offset | 108 | 36 |
| Długość | 124 B | 124 B |

Wszystkie bajty SID/ACE/ACL, revision i control pozostają niezmienione.
Rekonstrukcja z tymi samymi sekcjami daje dokładnie **wcześniej odnotowany**
API SHA-256 `405e5a6992f06e338514ab9b0f03a37dbf855a46a9062af866548fd1b857108b`.
To rozróżnienie dwóch serializacji, bez zmiany oczekiwań i bez ukrywania
strict API-hash FAIL. Nie dowodzi PASS całego NTFS; niesortowane atrybuty i
nieodczytany ADS pozostają rzeczywistym błędem. Dowód:
`feature-case01/default-security-diagnostic01.json`.

### Dwie niezależne bramki SD

WIM-mode wymaga teraz obu argumentów `-ExpectedWimTreeJsonl` i
`-ExpectedWimSecurityJsonl`; brak sidecaru odmawia przed konwersją/mount.
Raw gate `wim_security_readonly.py --tree` używa istniejącego, niezależnego
parsera `inspect_ntfs.py`, bez importów writera i bez montowania. Sprawdza
oba egzemplarze `$SDS`, nagłówki/offsety, NTFS hash, dokładne surowe SD oraz
odniesienie każdej oczekiwanej ścieżki przez MFT SI do jej securityID.
Dodatkowe nieużyte SD są jawnie raportowane, nie zastępują brakującego SD.
Osobne JSONL zachowują każdy raw SD i każde odniesienie pliku.

Windows API musi zwrócić te same revision, wszystkie bity control,
RMcontrol i **bajtowo identyczne** owner/group SID oraz SACL/DACL. Dozwolona
jest tylko inna pozycja zwalidowanych sekcji; nie sortujemy ACE, nie
usuwamy flag i nie zmieniamy payloadu. Niewłaściwe długości, częściowe
nakładanie się sekcji i niezerowe bajty poza nimi są odrzucane. Pełny alias
tego samego owner/group SID jest poprawny. Każdy wpis zapisuje osobno
`api_reordered_sd`, `api_security_sections_exact` oraz oba SHA-256.
Ta równoważna serializacja **nie zastępuje raw gate**: końcowy PASS wymaga
jednocześnie raw SD exact, API sections exact, pozostałych metadanych,
odczytu wszystkich strumieni i read-only chkdsk exit 0.

Pierwszy pełny raw gate na niezmienionym feature01 dał 5001/5001 SD i
5014/5014 odniesień, bez braków/dodatków i bez zmiany źródła:
`feature-case01/raw-security-all01.json`. Nie zmienia to historycznego FAIL
ADS/chkdsk tego core.

Dziewięć testów Python obejmuje również zmianę SID/RMcontrol/kolejności
ACE, overlap SID wewnątrz ACL, niezerowe padding i uszkodzenie hash/offsetu
lub duplikatu SDS. Natywny `oracle-native-mini05` wykonał 21 warunków PASS,
w tym tę samą parę znanych SD/hash i siedem negatywnych mutacji, rzeczywisty
hardlink, ADS, raw GetFileSecurityW, cztery różne czasy oraz odmowę traversalu
reparse/physical path. `oracle-ps-guard02` ma 15/15 odmów PASS, w tym brak
sidecaru i niezgodny SHA SD. Żadna z tych odmów nie osiągnęła konwersji/mount.

### Feature02 po naprawie sortowania ADS: Windows PASS

Core `f267dd7c` naprawia NTFS collation nazw atrybutów (UpCase primary,
raw tie), bez zmiany kontraktu `populate`. Nowe asercje testowe zmieniły SHA
całego pliku źródłowego fixture; **nie regenerowano** `feature-expected01`.
Root wykonał świeży format/populate/finish w 0,393 s, proces exit 0:

- `feature-case02/target.raw`, 268435456 B, SHA-256
  `ed814d2693ee3ae673f058d11146bfd0b4aca429105ae6913aadbb454d9ec456`.
- Program SHA-256
  `05bdd4a6aa0cfbbd9e04486d04c04d1dacdc850a8636375c7abf0d9bf68b77ef`;
  exact command/pin w zakończonych `inputs.json` i `core-result.json`.
- Osobna `oracle-input01.raw` ma identyczny SHA, tylko ta kopia otrzymała
  ReadOnly. Kopiowanie pod source deny-write/delete lock; źródłowe bajty
  i atrybuty unchanged. Reserve obejmował kopię i oba VHD oraz 100 GiB.

`feature-case02/windows01` zachowuje **błąd launchera wyroczni**, przed
konwersją/mount: Get-Command zwrócił dwa wpisy python.exe, które omyłkowo
połączono w jedną nazwę programu. Zmieniono wyłącznie wybór pierwszego
rzeczywistego EXE. Żaden target/core/expected nie został zmieniony.

`feature-case02/windows02/result.json` faktycznie zakończył się exit 0/PASS:

- Dokładnie 5014/5014 nazw i metadanych; missing/extra/different/read-errors 0.
- Odczytane oba duże ADS `large-世界` i Zone.Identifier obu hardlinków,
  zgodne logiczne rozmiary i SHA-1 wszystkich strumieni, link-count/FileId,
  attrs, cztery czasy i surowe reparse data/tag bez target fixup.
- Raw gate: 5001/5001 dokładnych SD, 5014 securityID refs, zgodne primary/
  duplicate/hash NTFS, brak dodatkowych SD; osobny `raw-security.json` PASS.
- Windows API: 12 jawnych `api_reordered_sd`, 0 niezgodnych sekcji; oba hashe
  zachowane. Oczekiwania raw/tree/security pozostały niezmienione.
- Native read-only chkdsk **bez przełączników**, exit 0, `Windows has scanned
  the file system and found no problems.` Pełny stdout zachowany.
- Tymczasowy alias usunięty, VHD odmontowany; raw/VHD/tree/security SHA
  identyczne przed/po. VHD SHA-256
  `6b57217455c1bcd856663a5f837c908fb1f9d63cad35580b965892843ff79ddc`.

To PASS własnego małego fixture cech NTFS. Nie jest jeszcze PASS pełnego
apply obu rzeczywistych WIM ani firmware/GUI. Wszystkie poprzednie odmowy,
obrazy i dowody zachowano do raportu końcowego.

### Rzeczywisty Win10: restrykcyjny ACL i korekta odczytowej wyroczni

Finalny host apply02 zakończył się core PASS na źródle Win10 wskazanym
wyżej. `win10-apply02/target.raw` ma 8589934592 B, SHA-256
`9c3f0afcdb8e2ec778410a3df76aa011eda31386c069c0c2851aa5427d439677`.
Źródło jest zamknięte i otrzymało jawnie ReadOnly; przez całą weryfikację
launcher trzyma dodatkowo read handle odmawiający zapisu/usunięcia. Nie
tworzymy zbędnej kopii raw: wyłącznie dwa nowe VHD, zachowane do raportu.

Pierwsze `windows01` zakończyło się FAIL wyroczni: natywna enumeracja
odmówiła dostępu do `Windows/System32/LogFiles/WMI/RtBackup`. Raw gate
potwierdził dokładnie 328 oczekiwanych SD i 99220 odniesień plików; dodatkowy
nieużyty SD to domyślny formattera, osobno raportowany. Taki restrykcyjny
ACL należy **zachować**, a nie zastępować uprawnieniami administratora.
Chkdsk nie został wtedy uruchomiony; alias usunięto, VHD odmontowano,
wszystkie piny raw/VHD/tree/security pozostały zgodne. Wynik zachowany.

Wyrocznia włącza teraz tymczasowo `SeBackupPrivilege` obok
`SeSecurityPrivilege`, przed pierwszą enumeracją. Odtwarza oba poprzednie
stany tokenu również przy błędach; nie włącza `SeRestorePrivilege`.
[Implementacja .NET FileSystemEnumerator](https://raw.githubusercontent.com/dotnet/runtime/v10.0.0/src/libraries/System.Private.CoreLib/src/System/IO/Enumeration/FileSystemEnumerator.Windows.cs)
otwiera katalogi z backup intent. Własne uchwyty danych/metadanych mają
`FILE_FLAG_BACKUP_SEMANTICS` i wyłącznie dostęp odczytowy.

Własny `oracle-native-mini06` potwierdził pozytywną enumerację SYSTEM-only
katalogu po włączeniu SeBackup, ale wykrył odmowę `FindFirstStreamW`.
Zachowano FAIL; ten API ponownie otwierał plik po ścieżce. Używany jest teraz
[GetFileInformationByHandleEx z FileStreamInfo](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getfileinformationbyhandleex)
na istniejącym uchwycie backup read. [FILE_STREAM_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_stream_info)
jest parsowany z ograniczeniem bufora/entry/name/offset, a dane ADS nadal
otrzymują strumieniowy SHA-1 przez read-only backup handles.

`oracle-native-mini08`: **26/26 PASS**, w tym negatywna kontrola dostępu
przed SeBackup, odczyt SYSTEM-only directory/attrs/SD/stream bez zmiany ACL
i ponowna odmowa po przywróceniu tokenu. ACL zmieniano wyłącznie na świeżym
własnym mini-fixture. Późniejszy audit ujawnił, że stare przywrócenie .NET mogło być no-op: mini06–08 pozostają zachowane jako ograniczone ACL fixture (opaque 16 MiB każdy). Nie zmieniano ich podczas audytu ani żadnego ACL WIM/targetu. Poprawiony test jawnie oznacza przechwycony DACL jako zmodyfikowany przed odtworzeniem i sprawdza zwykłą enumerację bez SeBackup.

Parametr `-PreparedVhdResult` wraz z wymaganym SHA-256 umożliwia odczyt
**tego samego**, zamkniętego i odmontowanego VHD, bez kolejnych dużych kopii.
Wymagane są poprzedni result pin, source path/size/hash, zgodne conversion/
copy/VHD hashes, ReadOnly/regular/non-reparse/non-sparse, fixed VHD i dokładny
rozmiar. VHD i prior result są dodatkowo chronione read handles; konflikt
udziałów powoduje odmowę. Każdy kolejny mount ponownie wymaga file-backed
virtual, exact size, ReadOnly oraz non-system/non-boot i dokładnego aliasu.
Nowy Out przechowuje wyłącznie nowe dowody; poprzedni result nie jest nadpisywany.

`oracle-ps-guard03`: **22/22 odmów PASS**, w tym brak pinu reuse, zły hash,
niezamknięty prior result, inny source/size, unsafe VHD path i inny typ pliku.
Żadna nie osiągnęła konwersji/mount. Błąd enumeracji/metadanych jest teraz
zachowany jako FAIL, ale niezależny read-only chkdsk nadal jest wykonywany,
jeśli wszystkie guardy volume/alias/RO przeszły. Nie można uzyskać łącznego
PASS przez samo chkdsk exit 0. Commit wyroczni: `a2c2f381`.


### Dwa rzeczywiste apply02: zachowany FAIL NTFS i korekta pełnego SACL

Zakończony `win10-apply02/windows02` odczytał 99220/99220 wpisów, bez
missing/extra/read-error. Dane wszystkich strumieni, czasy, hardlinki i reparse
zgodne; 294 różnice składają się z 122 SACL i 172 atrybutów. Zakończony
`win7-apply02/windows01` odczytał 57146/57146 wpisów bez błędów odczytu,
z 46 różnicami SACL, bez pozostałych różnic metadanych. Surowy `$Secure`
i securityID każdego pliku są dokładnie zgodne z niezmienionymi oczekiwaniami.
**Oba native read-only chkdsk zwróciły 3**, wskazując niepoprawne informacje
rekordu MFT 5; nie jest to PASS. Wszystkie source/VHD/tree/security hashes
pozostały zgodne, aliasy usunięto, VHD odmontowano. Surowe wyniki FAIL i obrazy
zachowano; naprawę root FILE_NAME prowadzi osobno właściciel NTFS.

Dotychczasowe `OWNER|GROUP|DACL|SACL_SECURITY_INFORMATION` (15) filtruje
mandatory-label ACE 17 i resource-attribute ACE 18. Zgodnie z dokumentacją
[SECURITY_INFORMATION](https://learn.microsoft.com/en-us/windows/win32/secauthz/security-information)
odczyt żąda teraz `BACKUP_SECURITY_INFORMATION` (0x10000), z read-only handle,
READ_CONTROL/ACCESS_SYSTEM_SECURITY oraz tymczasowymi uprawnieniami wyroczni.
Nie zmienia SD ani ACL targetu. Porównanie nadal wymaga dokładnego surowego SD
na dysku oraz dokładnej zawartości owner/group/SACL/DACL, revision/control/RM;
do zamiany położeń niezmienionych sekcji służy osobny jawny licznik.

`oracle-native-mini09` **30/30 PASS**, `mini10` **35/35 PASS**. W obu własny
mały plik zawiera znany SACL z ACE mandatory-label i resource-attribute:
pełny odczyt przez handle jest bajtowo zgodny z oczekiwanym ACL i niezależnym
GetFileSecurityW; stare żądanie 15 demonstracyjnie pomija te ACE. Testy nie
montują obrazów ani nie stosują WIM do zwykłego folderu. DACL świeżego własnego
SYSTEM-only fixture jest teraz rzeczywiście przywracany i kontrolowany bez
backup privilege. Żadnego starego mini06–08 nie zmieniano.

Win10 ma również oczekiwane regularne pliki z WIM attrs 0. Windows API
raportuje na nich syntetyczny NORMAL 0x80. Wyrocznia dopuszcza wyłącznie tę
parę wartości i wyłącznie po niezależnym sprawdzeniu **każdej** takiej ścieżki:
raw SI=0, wszystkie raw FILE_NAME=0, obiekt regularny. Wynik raw zawiera pełną
listę ścieżek i wartości; expected attrs oraz target pozostają 0. Native wynik
loguje oba atrybuty oraz `api_synthesized_normal`, licznik i listę ścieżek.
Nie ma maskowania pozostałych bitów ani katalogów. Brak raw proof, jego FAIL,
inny tree pin lub inna ścieżka powodują FAIL porównania (cztery negatywne
native kontrole). Python testuje odmowę niezerowego SI/FN i katalogu.

Ta korekta wyroczni nie zmienia starych wyników w PASS i nie kwalifikuje
jeszcze końcowego apply rzeczywistych WIM po naprawie root MFT5.


Końcowy odczyt `win10-apply02/windows02/raw-zero-proof01.json` zakończył się
exit 0/PASS: **172/172 regularnych expected0 ścieżek** mają raw SI=0 i wszystkie
FILE_NAME=0, bez wyjątków. Odczyt objął ponownie 99220 security refs i 328
oczekiwanych raw SD; source oraz oba sidecary unchanged. Root/katalogi są
raportowane surowo, lecz nie biorą udziału w mapowaniu NORMAL. Receipt SHA-256:
`85113f8575da435ea65de901c58aa614592950a313594927581717c8eedd15e6`.


### Zamknięta kontrola root metadata06: nadal chkdsk FAIL

Po sourcefix zachowującym formatterowe root FILE_NAME HIDDEN|SYSTEM wykonano
osobny świeży apply małego, niezależnego XPRESS WIM (set01/image1), bez
modyfikowania wcześniejszych targetów. Program final06 SHA-256
`5526b4b576616e9d3a75e325916ab8cfd31d53c4ebfc87d4594b3d1bf3295534`.
Target `root-metadata06-smoke/target.raw`, 268435456 B, SHA-256
`39c5eff763974d5a0795d48297d6dc301a8f67aaa030e7909ae28b32f820b05b`.

`windows01` rzeczywiście zakończył się exit 1 po 9,63 s:

- Native pełny tree/metadata/stream SHA-1 **411/411 PASS**, 0 brakujących,
  dodatkowych, różnic i błędów odczytu; niezależny raw SD/reference gate PASS.
- Raw root5: SI attrs 0, FILE_NAME attrs `0x10000006`; native root attrs 16.
  Poprawka jest obecna, więc jej braku nie można podać jako przyczyny wyniku.
- **Native read-only chkdsk bez przełączników exit 3**, ponownie
  `Incorrect information was detected in file record segment 5.`
  Samo zachowanie flag root FN6 okazało się niewystarczające.
- Source oraz sidecary niezmienione; VHD SHA-256
  `d792ce1a3fa178a5918b0663f16ee5fdf62cd171710c66ead47ee6e95f17d54e`
  zgodny przed/po. Alias usunięty i VHD odmontowany. Nie wykonano naprawy
  woluminu, nowych dużych prób ani dodatkowej kopii raw.

Wyniki są w `root-metadata06-smoke/windows01/{result.json,
chkdsk-stdout.txt,raw-security.references.jsonl}` oraz zamkniętym
`windows01-evaluation.json`; launcher i pełna komenda/piny zachowane obok.
Ten konkretny FAIL przekazano właścicielowi NTFS. Nie kwalifikuje finalnego
apply ani nie unieważnia osobnego PASS małego fixture feature02.


### DIAG07: wyłącznie root SI0→6 rozstrzyga błąd chkdsk

Root przygotował nowy, świeży 128 MiB apply final06 tego samego małego XPRESS
WIM. Diagnostyczna delta to **jeden bajt** pod offsetem 1070192: root5 SI
flags 0→6. Pełny reconstructed-source proof potwierdza identyczność wszystkich
pozostałych bajtów, w tym FILE_NAME i USA trailers. Target jest ReadOnly,
SHA-256 `9e4c1a79563a7de760262469ce36ee449abcc24781bae352ffdc86a64f35821d`.
Nie zmieniono oryginalnych sidecarów WIM; to nie jest produkcyjny apply PASS.

`root-si6-diagnostic07/retry128/windows01` jest faktycznie zakończony:

- Native read-only chkdsk **exit 0** i `Windows has scanned the file system
  and found no problems.` Sprawdził wszystkie trzy fazy, bez napraw/switches.
- Wszystkie 411 wpisów odczytane, 0 missing/extra/read-error. **Dokładnie jedna
  oczekiwana różnica**: root attrs WIM16 / native22. Żadne mapowanie root nie
  zostało dodane do wyroczni. Surowy root ma SI6/FN0x10000006, rawSD/refs PASS.
- Surowy ogólny wynik helpera pozostaje FAIL przez tę różnicę WIM. Również
  początkowa konserwatywna ewaluacja diagnostyczna pozostaje zachowana:
  dotychczasowe pole `readonly_chkdsk_pass` było agregatem wraz z metadata,
  więc przy celowej różnicy ma false mimo rzeczywistego chkdsk exit 0.
- Nowy, osobny `windows01-diagnostic-conclusion.json` jednoznacznie zapisuje
  `diagnostic_hypothesis_supported=true`, `production_wim_pass=false`, piny
  starych wyników i logu. Żadnego historycznego wyniku nie nadpisano.
- Source, tree/security oraz VHD unchanged; VHD SHA-256
  `de42beb3f6cc5e14c109dd575da3dd5c0c9acfe8aa16c26faacafd2f39d343ff`.
  Alias usunięty, VHD odmontowany. Nie utworzono dodatkowej kopii raw.

To kontrolowany dowód przeciwstawiony zachowanemu smoke06 SI0/chkdsk3.
Naprawa source i jawna polityka metadanych root wymagają osobnego wdrożenia
oraz końcowych rzeczywistych WIM gates; nie zmieniamy oczekiwań po cichu.


### Jawny kontrakt root NTFS po DIAG07 (final07)

DIAG07 uzasadnia konkretny invariant metadanych NTFS: root MFT5 zachowuje
HIDDEN|SYSTEM (6). Source row WIM pozostaje **bajtowo niezmieniony**.
Nie jest to równoważna reprezentacja ani ogólna normalizacja atrybutów.
Niezależny raw gate wymaga wyłącznie dla ścieżki pustej i katalogu MFT5:

- SI flags dokładnie `(WIM.attributes & ~DIRECTORY) | 6`;
- jeden FILE_NAME z dokładnymi flagami `SI | 0x10000000`;
- osobno niezmienione surowe SD i poprawne odniesienie securityID.

Pod takim proof Windows API ma zwrócić dokładnie `WIM.attributes | 6`.
Wynik każdej ścieżki zachowuje `expected_attributes` (source),
`expected_native_attributes`, rzeczywiste `attributes` oraz jawne
`root_reserved_metadata_flags=6`. Native i raw wyniki raportują zastosowanie
polityki. Pozostałe bity root pozostają ścisłe; inne ścieżki nie otrzymują
tego wyjątku. Wąski, niezależny przypadek regularnego raw0/API NORMAL80 jest
nadal oddzielnie udowadniany i logowany. Wymagany jest również chkdsk exit0.

`oracle-native-mini11` **41/41 PASS**: root-only positive oraz odmowy
brakującego proof, rekordu innego niż5, złego SI/FN lub źródłowych attrs.
Python raw-security **11/11 PASS**, w tym odmowa ordinary path/directory
mismatch i kontrola zachowania dodatkowego bitu ARCHIVE. Własne native
fixture testuje kontrakt komparatora; nie udaje surowego proof obrazu.
Rzeczywisty odczyt `retry128/windows01/raw-root-reserved-proof02.json`
potwierdził ten root proof oraz wszystkie 411 security refs, bez mount,
zmiany obrazu lub sidecarów. Pierwotny DIAG07 rootattrs mismatch pozostaje
w oryginalnych wynikach jako dowód sprzed wprowadzenia jawnego kontraktu.

Dla przyszłych prób pole `readonly_chkdsk_pass` oznacza teraz wyłącznie
rzeczywiste ukończenie chkdsk0 na guardowanym NTFS. `passed` nadal wymaga
koniunkcji wszystkich raw/native metadata i chkdsk gates oraz poprawnego
cleanup/hash. Żaden historyczny false ani FAIL nie został nadpisany.


### Expected feature final07: wyłącznie odnowiony source pin

Po core `836e5ae9` pełny plik `wim_ntfs_tests.zig` ma SHA-256
`a77bbe896a79687610e3ff7c5e22701794bace7e870486130b512e33c2fb14cf`.
Jedyna zmiana generatora to przypięcie tego aktualnego pliku po nowych
prywatnych asercjach root. Cały publiczny kontrakt przed backendem `Memory`
(populate/Pattern/securityDescriptor/reparseBuffer/times) jest bajtowo zgodny
z oryginalnym plikiem o SHA `1b813f1d…3ca5`, z commitu `8f58feda`;
publiczny fragment ma SHA `5489cffa38f399f9bb11e76234e29f55d6e2c389ec69958a9e6c34e640700439`.

Wygenerowano osobny `host-final07/expected-feature07`; stary expected01
pozostaje niezmieniony. Rzeczywisty byte-by-byte compare potwierdza identyczne
`tree.jsonl` (SHA `d631ecf7…5668`) i `security.jsonl` (SHA `8caf301c…df53`),
5014 wpisów, 5001 SD oraz wszystkie stream SHA-1. Manifest różni się tylko
`fixture_sha256` i `generator_sha256` (nowy `157fd43c…6d04`). Pełny proof
jest w `expected-unchanged-receipt.json`; generator 8/8 testów PASS.
Nie czytano NTFS, nie stosowano WIM ani nie przebudowano programu.
To odnowienie pochodzenia oczekiwań, bez zmiany oczekiwanych danych i bez
przyznania PASS jeszcze niewykonanym końcowym Windows gates.


### Rzeczywisty Win10 final07: pełny Windows RO gate PASS

Nowy świeży apply final07 użył tego samego rzeczywistego WIM Win10 x86 PL,
HomeN index2 (LZX); program SHA-256
`d0ad2608603f47e87388867741ffaadf831e7100ca419125a00b6475990c802b`,
core PASS 204,417 s. Target `win10-final07/target.raw`, 8589934592 B,
SHA `2314f056b91d73e234c9833d969cf80836c19239688b76ebb48e196a0b2b8a3a`.
Native gate `windows01` zakończył się faktycznie exit0/PASS po 756,70 s:

- **99220/99220** wpisów; missing/extra/different/read-error 0. Wszystkie
  strumienie SHA-1, logiczne rozmiary, czasy, attrs, hardlinki i reparse zgodne.
- Raw `$Secure` 328 oczekiwanych SD i 99220 file references dokładnie zgodne.
  Pełny native SACL/owner/group/DACL zgodny; APIreorderedSD=0. Dodatkowy
  nieużyty domyślny SD formattera pozostaje jawnie oddzielony od oczekiwanych.
- Tylko rootMFT5 stosuje zadeklarowane reserved6: WIMattrs16 pozostają
  niezmienione, native22, rawSI6/FN0x10000006. Wszystkie **172** regularne
  rawSI0/allFN0 są osobno zalogowane jako Windows NORMAL128.
- **Native read-only chkdsk bez przełączników exit0**;
  `readonly_chkdsk_pass=true`, koniunkcja wszystkich gates `passed=true`.
- 53762 źródłowe nazwy 8.3 są jawnie ignored/logged; nie deklarujemy ich
  utworzenia. Źródło przez całą próbę ma deny-write/delete readhandle.
- Source/tree/security i zamontowany VHD SHA unchanged, alias usunięty, VHD odmontowany.
  VHD SHA `5a0dbbd16017b666ae17dae04937b56e09fb70a0f0f4960726d3fa27c717eaa3`.
  Result SHA `2e195328ca4ccb721b3ec69fb1d2ced112b039a528f23881877d2dc243880615`.

Oryginalny raw jest ReadOnly i zachowany; dodatkowej kopii raw nie tworzono.
Plan12/pula150 GiB zatwierdzone, minimum100 GiB wolnego pozostaje wymagane.
To kwalifikacja transformacji WIM→NTFS przez usosprep, bez uruchamiania
Windows lub kwalifikacji urządzeń. Stare apply02 FAIL pozostają zachowane.


### Rzeczywisty Win7 final07: pełny Windows RO gate PASS

Nowy świeży final07 użył rzeczywistego WIM Win7 SP1 x86 PL, Starter index1
(LZX), ten sam program `d0ad2608…802b`; core PASS 106,916 s, jawny MBR.
Target `win7-final07/target.raw`, 6442450944 B, SHA-256
`f6e553eb650a36216c924bf2a211b14cc9bd96324e3a1d28777ebb598e9813f6`.
Native `windows01` zakończył się rzeczywiście exit0/PASS po 508,22 s:

- **57146/57146** wpisów; missing/extra/different/read-error 0. Wszystkie
  strumienie SHA-1, rozmiary, czasy, attrs, hardlinki i reparse zgodne.
- 250 oczekiwanych raw SD i 57146 file references dokładnie zgodne; pełne
  owner/group/SACL/DACL przez Windows API zgodne, APIreorderedSD=0, NORMAL=0.
- Jawny rootMFT5: WIMattrs16, native22, rawSI6/FN0x10000006; inne wartości
  metadanych nie otrzymują ogólnego maskowania. 30285 źródłowych 8.3 names
  pozostaje jawnie ignored/logged.
- Read-only chkdsk bez przełączników **exit0**, osobne chkdsk gate i overall
  PASS. Source i sidecary unchanged, deny-write/delete readhandle zachowany
  przez całą próbę; alias usunięty, VHD odmontowany.
- VHD SHA przed/po
  `0e243f01ebc7e96a729c8fa6d4d9c70104de8ed48ffa8678016dc2f345b234d4`.
  Result SHA `74eaa023b681befc00032d5b2bebb19bdc3c2343c2b5ee454aecd221bfdbd98f`.

Dwa rzeczywiste WIM mają zatem pełny końcowy Windows RO PASS na **nowych**
final07 targetach. Obrazy i wszystkie poprzednie apply02/diag FAIL zachowano;
nie ponawiano ich ani nie nadpisywano wcześniejszych ocen. Ta kwalifikacja
nadal dotyczy WIM→NTFS, bez bootowania Windows i bez fizycznych urządzeń.


### Dziewięć host final07: pełne Windows gates 9/9 PASS

Po rzeczywistych Win10/Win7 wykonano kolejkę wyłącznie dziewięciu zamkniętych
nowych targetów `host-final07`. Piny producenta i expected w
`windows-handoff.json` (SHA `dc3ba4c6…d4f4`); feature używa osobnego,
byte-identycznego `expected-feature07`. Każdy case miał globalny mutex,
`pool.enforce` z pinned plan14 (pula150 GiB, minimum100 GiB wolnego), source
ReadOnly i deny-write/delete handle, nowy `case/windows01`, bez raw duplicate.

| Case | Wszystkie wpisy | Oczekiwane raw SD | Native chkdsk |
|---|---:|---:|---:|
| features | 5014 | 5001 | 0 |
| smoke/xpress | 411 | 2 | 0 |
| smoke/lzx | 411 | 2 | 0 |
| smoke/lzms-nonsolid | 411 | 2 | 0 |
| smoke/multi-index2 | 23 | 2 | 0 |
| large/xpress | 1228 | 2 | 0 |
| large/lzx | 1228 | 2 | 0 |
| large/lzms-nonsolid | 1228 | 2 | 0 |
| ads/xpress | 15 | 2 | 0 |

Wszystkie dziewięć zakończyło się native exit0/overall PASS, 0 różnic,
brakujących/dodatkowych wpisów i read-errors. Dokładne stream SHA-1, czasy,
attrs, hardlinki, reparse, surowe SD/security refs oraz native SD sections.
Feature zachowuje 12 jawnych przestawień położenia niezmienionych sekcji SD;
pozostałe cases mają0. Duże przypadki zawierają1208 plików, największy
134217851 B; ADS case obejmuje oba named streams, w tym Unicode196609 B.

Zamknięty `windows-queue01-summary.json` ma SHA-256
`8a34051a5c67a53a19dfefe9b7c5c63c893849e61215b3d60f0966853da1c578`.
Osobny `windows-qualified-summary01.json` o SHA
`b6094f91f0ba723fc902794429e268cb22bd59a4b701cdbfa9571c7c2dd9f766`
wiąże target/VHD/result hash każdego case i liczniki. Wszystkie source oraz
VHD unchanged, aliasy usunięte i VHD odmontowane. Kolejka faktycznie zakończyła
się exit0, mutex oddano właścicielowi jedenastu firmware gates. Nie przyznaje
to jeszcze PASS tym firmware/RAM przypadkom. Niczego nie usunięto.


### Dwa minimum-RAM COW: przygotowanie i rzeczywisty Windows PASS

Najpierw przygotowano jednorazowy `ram-windows-final07/verify_winners01.py`,
SHA-256 `98b5ed4b582fe5bf042fe6457fcb1ee44dd470b5604b76c2d349beed9f978495`.
Składnia i 21 testów guardów metadanych przeszły przed wykonaniem;
`launcher-preparation.json` zapisuje ten osobny etap. Podczas przygotowania
nie odczytywano aktywnych prób RAM ani obrazów. Dopiero po potwierdzonym
zamknięciu wszystkich 12 prób i osobnym poleceniu właściciela uruchomiono
launcher dokładnie raz z `handoff-winners01.json`, SHA-256
`db6fcd8d782a187b72142e805210f0557f97a04763659aa929692e4774866563`.

Wyeksportowano tylko dwa zwycięskie COW dla dużego fixture LZMS non-solid,
bez nowego apply ani uruchamiania VM. Granice ustalone przez właściciela
prób to x64: 49 MiB PASS / 48 MiB FAIL, IA32: 48 MiB PASS / 47 MiB FAIL.
Są to minima wykonanych profili QEMU i tego fixture, nie ogólna gwarancja
tych limitów dla dowolnego WIM lub fizycznego firmware.

| Profil | RAM | Pełne wpisy | Różnice / błędy odczytu | Read-only chkdsk |
|---|---:|---:|---:|---:|
| UEFI x64, `x64-m049` | 49 MiB | 1228/1228 | 0/0 | 0 |
| UEFI IA32, `ia32-m048` | 48 MiB | 1228/1228 | 0/0 | 0 |

Oba Windows gates rzeczywiście zakończyły się exit 0 i overall PASS. Wszystkie
stream SHA-1, rozmiary, czasy, attrs, hardlinki i surowe reparse zgodne;
missing/extra = 0. Niezależny raw gate potwierdził po dwa oczekiwane SD i 1228
referencji plików oraz dokładne native owner/group/SACL/DACL. Nieużyty SD
formattera pozostaje osobno zalogowany. API reordered SD i NORMAL mapping = 0.
Tylko jawny kontrakt root MFT5: źródłowe WIM attrs 16, native 22,
raw SI 6 i FN `0x10000006`; źródłowych manifestów nie zmieniono.

Każdy case miał globalny mutex, `pool.enforce` z przypiętym plan14
(pula 150 GiB, scope 2 GiB, minimum 100 GiB wolnego), deny-write/delete
uchwyty COW/bazy/metadanych i dokładny dwuwarstwowy łańcuch QCOW2 → RAW.
Nowy eksport RAW ma 268435456 B i ReadOnly. SHA, rozmiary i atrybuty wszystkich
źródeł przed/po są identyczne; RAW i oba VHD również unchanged. Tymczasowe
aliasy usunięto, VHD odmontowano, proces kolejki zakończył się exit 0.

Piny zamkniętych wyników w `ram-windows-final07`:

- `x64/target.raw`: `e854138b32869541cec115837ed314423ff311500eed30ceb97a2f62090793df`;
  `x64/windows01/result.json`: `d38d6c7e0bdb51d3e4a5c7c19ae11ddac73d9324b52c5607dcd5f9f5d1cf323d`.
- `ia32/target.raw`: `282bbb8156c12d00c879bb48dbbd199d962d96ac06be78755db3a77b89f86c41`;
  `ia32/windows01/result.json`: `bf19c2c3a3aee82306444db5a6c1b18a874f2649f89874a7dc1b8932d5e9b1da`.
- `summary.json`: `3f967b873c904ed9ec9d25f570668f8e205d3a495ee2f8fb295c32e35c10d817`;
  zawiera oba evaluation, dokładne source/COW/base piny i końcowe closure.

To końcowa odczytowa kwalifikacja wyników dwóch prób RAM, bez bootowania
Windows. Wszystkie obrazy i wcześniejsze FAIL dowody pozostają zachowane;
niczego nie usunięto.
