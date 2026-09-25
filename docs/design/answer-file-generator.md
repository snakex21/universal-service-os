# Generator plików odpowiedzi (projekt, 2026-09-24)

Stan: **projekt**, bez kodu. Zastępuje punkt 5 („Generator unattended”)
starszej listy w `ROADMAP.md` w katalogu głównym. Miejsce w kolejności prac:
[docs/ROADMAP.md](../ROADMAP.md). Generator jest jednym z etapów wspólnego
pipeline'u: [refactor-os-pipeline.md](refactor-os-pipeline.md) (etap
`answer_file`).

## 0. Cel i granice

Użytkownik wybiera obraz, odpowiada w menu USOS na kilka pytań i dostaje
instalację bez ręcznego pisania `winnt.sif` / `autounattend.xml` /
`msbatch.inf`. Warunki brzegowe wynikające z obecnego kodu:

- **Menu czyta DATA wyłącznie do odczytu** (własny czytnik NTFS w Core
  i przez BlockIo w UEFI). Menu nie zapisze więc pliku obok ISO. Zapisywać
  może: ESP (FAT32, `settings_store.zig`), mikro-Linux (WORK i dysk
  docelowy) oraz instalator Go na Windows (DATA w trybie zapisu).
- **Pliki użytkownika są święte.** Dziś `extract.sh` kopiuje wybrany plik
  1:1 jako `Autounattend.xml` i porównuje `cmp`; XP odrzuca
  `AutoPartition=1` / `Repartition=Yes` (`tools/xp_unattended_policy.sh`),
  a ścieżka XP UEFI-CSM w ogóle blokuje własny SIF
  (`manual_summary.zig`, `summary_xp_no_unattended`). Generator nie może
  tego osłabić: gotowy plik użytkownika bez żądania scalenia nadal idzie
  1:1.
- **Bez sekretów w logach.** Klucz produktu i hasła nigdy nie trafiają do
  logu szeregowego, `drivers.txt`, `pae-install.log` ani logów WORK
  (wzorem `usos_xp_sif_risks`, który nie wypisuje treści pliku).
- **Brak kluczy w payloadzie.** USOS nie dostarcza kluczy produktu.
  Wybór edycji odbywa się przez indeks/nazwę obrazu w WIM, a nie przez
  klucz. Klucz wpisuje (albo dostarcza jako `.key`) użytkownik.
- **Partycjonowanie tylko świadomie** (sekcja 5).

## 1. UX: co menu pyta

Nowy krok między „Plik odpowiedzi” a „Podsumowanie”
(`manual_unattended.zig` dziś pokazuje listę plików z `Unattended\`).
Lista wyborów:

1. `Bez pliku odpowiedzi` (domyślne tam, gdzie tak jest dziś).
2. Pliki z `Unattended\` profilu i pliki-towarzysze obrazu (sekcja 2).
3. **`Utwórz automatycznie…`**: formularz generatora.
4. `Utwórz na podstawie <plik>…`: formularz wstępnie wypełniony z pliku
   użytkownika (scalanie, sekcja 4).

Formularz jest jedną stroną z wierszami, obsługiwaną tak jak inne strony
menu (strzałki, pad, dotyk, mysz). Pola tekstowe edytuje się w nakładce
z klawiaturą ekranową (pad/dotyk) albo fizyczną klawiaturą z wybranym
układem (sekcja 7). Pola zależą od profilu OS; pola nieobsługiwane przez
format danego systemu nie są pokazywane (zasada „pokazuj tylko to, co
działa” z podsumowania).

| Pole | NT5 (2000/XP/2003) | 6.x–11 | 98/Me | Domyślnie |
|---|---|---|---|---|
| Nazwa użytkownika / właściciela | `[UserData] FullName` | `LocalAccount Name`, `RegisteredOwner` | `[NameAndOrg] Name` | `Użytkownik` (z locale) |
| Organizacja | `OrgName` | `RegisteredOrganization` | `Org` | puste |
| Nazwa komputera | `ComputerName` | `ComputerName` | `[Network] ComputerName` | `USOS-XXXX` (4 znaki losowe), walidacja NetBIOS ≤ 15 znaków ASCII |
| Hasło konta | `AdminPassword` | `LocalAccount Password` | – | puste; ostrzeżenie o przechowywaniu tekstem jawnym |
| Język / regiony | `[RegionalSettings]` | `Microsoft-Windows-International-Core(-WinPE)` | `[System] Locale` | z języka UI USOS |
| Układ klawiatury | `InputLocale` | `InputLocale` | `[System]` / `KeyboardLayout` (do weryfikacji) | z locale |
| Strefa czasowa | indeks NT5 | nazwa Windows (`Central European Standard Time`) | `TimeZone` | z locale |
| Klucz produktu | `ProductKey` (2000: `ProductID`) | `ProductKey` (opcjonalny) | `ProductKey` | pusty = Setup zapyta |
| Edycja | – (jedna na ISO) | indeks z `install.wim` (lista z XML WIM, już czytanego przez `wim_setup.zig`) | – | brak = Setup zapyta |
| Dysk docelowy | wybór w menu mikro-Linuksa (jak dziś) | `nie partycjonuj` / `dysk wybrany w USOS` (sekcja 5) | wybór w menu USOS (jak dziś) | `nie partycjonuj` |
| OOBE | `OemSkipWelcome`, `OEMSkipRegional` | `HideEULAPage`, `HideOnlineAccountScreens`, `ProtectYourPC=3`, `SkipMachineOOBE` (tylko ≤ 7) | `Express=1` | tak (pomiń ekrany) |
| Win11: obejścia wymagań | – | `LabConfig` (TPM, Secure Boot, RAM, CPU), konto lokalne | – | **wyłączone**; widoczne tylko dla Win11 |
| Po instalacji | `GuiRunOnce` → folder `PostInstall` | `FirstLogonCommands` → `PostInstall` | `RunOnce` (do weryfikacji) | wyłączone (pozycja roadmapy „post-install”) |

Na końcu formularza: **Podgląd** (pełna treść pliku z zamaskowanym
kluczem/hasłem, przewijana) i **Zapisz jako…** (sekcja 2). Podsumowanie
startu pokazuje wiersz „Plik odpowiedzi: wygenerowany (Windows 11,
pl-PL, konto lokalne)” zamiast ścieżki.

Instalator Go dostaje ten sam formularz (Win32 UI) na ekranie
„Pliki odpowiedzi” z zapisem na DATA; to druga, wygodniejsza droga dla
użytkownika przy komputerze z Windows.

## 2. Przechowywanie

Trzy źródła, w kolejności pierwszeństwa przy wyświetlaniu:

1. **Plik-towarzysz obok obrazu** (pomysł z E2B, pozycja roadmapy
   „sidecar”): dla `Systems\Windows\Windows 11\Images\Win11_25H2.iso`:
   - `Win11_25H2.xml`: gotowy `autounattend.xml` (6.x+),
   - `Win11_25H2.sif`: `winnt.sif` (NT5),
   - `Win11_25H2.inf`: `msbatch.inf` (98/Me); rozszerzenie `.inf` jest
     rozpoznawane jako odpowiedź tylko w profilach 9x,
   - `Win11_25H2.key`: sam klucz produktu (jedna linia, bez logowania),
   - `Win11_25H2.answers.ini`: **odpowiedzi formularza** (nie gotowy plik),
     z których generator renderuje plik przy każdym starcie.
   Skan DATA (`image_scan.zig` / `catalog_ntfs_directory_source.zig`)
   i tak czyta katalog `Images`; towarzysze są przypinane do obrazu po
   nazwie bez rozszerzenia (porównanie bez rozróżniania wielkości liter),
   bez osobnego skanu.
2. **Pliki w `Unattended\` profilu**: bez zmian.
3. **Odpowiedzi wygenerowane w menu w tej sesji.** Menu nie pisze na DATA,
   więc zapisuje `EFI\USOS\answers\last-<system-id>.ini` na ESP (małe,
   FAT32, przez `settings_store`-podobny zapis atomowy). Plik zawiera
   **odpowiedzi**, nie wyrenderowany XML, i nie zawiera hasła ani klucza,
   chyba że użytkownik zaznaczy „zapamiętaj klucz na tym pendrivie”.
   „Zapisz obok obrazu” w menu jest widoczne tylko jako instrukcja:
   instalator Go (Aktualizuj USOS) przenosi `last-*.ini` z ESP do
   `<obraz>.answers.ini` na DATA, jeśli użytkownik tego chce.

**Gdzie renderowany jest plik docelowy** (zawsze w chwili przygotowania,
nigdy wcześniej, żeby DiskID / litery były aktualne):

| Ścieżka | Kto renderuje | Gdzie ląduje |
|---|---|---|
| 8/10/11 przez WORK (`prepare_work.sh` → `extract.sh`) | mikro-Linux (`usos-fb-ui --render-answer`) | `WORK:\Autounattend.xml` (to samo miejsce co dziś), `cmp` z renderem w RAM |
| Vista/7 UEFI, Vista/10 BIOS (wimboot bez mikro-Linuksa) | WinPE: `usos-answer.exe` (ta sama biblioteka Zig skompilowana dla `x86_64-windows`/`x86-windows`, jak dziś `pae.exe` przez `zig cc`); menu wstrzykuje tylko `answers.ini` | `usos-unattend.xml` obok `windows_iso_startup.cmd` w RAM WinPE (plik, którego skrypt już szuka) |
| 7 BIOS (mikro-Linux + kexec wimboot) | mikro-Linux | jw. |
| XP/2000/2003 (BIOS i UEFI-CSM) | mikro-Linux | `$WIN_NT$.~BT\WINNT.SIF` (scalenie z bazowym SIF, sekcja 4) |
| 98 SE (BIOS DOS Setup) | Core (Zig) | `C:\WIN98\MSBATCH.INF` przed `SETUP /IS` |

Renderer jest **jedną biblioteką Zig** w `src/flow/answer/` (bez
alokatora, bufory o stałym rozmiarze, jak reszta `src/flow`), linkowaną
do menu UEFI (podgląd), `usos-fb-ui` (mikro-Linux), małego
`usos-answer.exe` dla WinPE oraz Legacy Core wyłącznie dla profilu 98
(`msbatch.inf` to prosty INI; zmieścić w zapasie 43 KiB, pilnowanym
przez `build_legacy_bios.ps1`, albo odłożyć 98). Instalator Go
ma własną implementację formularza i renderu; zgodność gwarantują
**wspólne wektory testowe**: `src/flow/answer/testdata/*.answers.ini` →
oczekiwane pliki wyjściowe, czytane przez test Zig i test Go (ten sam
wzorzec co `windows7_pe_rules.tsv` z testami po obu stronach).

## 3. Szablony per OS

Szablony są **danymi** (pliki tekstowe z nazwanymi miejscami
`{{computer_name}}` i sekcjami warunkowymi `{{#if local_account}}`),
osadzanymi w buildzie, jeden na rodzinę formatu. Wartości są zawsze
escapowane dla formatu (XML: `& < > " '`; INF/SIF: cudzysłowy, brak `;`
i znaków nowej linii; odrzucenie znaków spoza dozwolonego zestawu
zamiast cichego obcinania).

### 3.1 NT5: `winnt.sif` (2000, XP x86/x64, Server 2003)

Baza = dzisiejszy `tools/xp_selected_partition.sif` (sekcje `[Data]`
i `[Unattended]` z `Repartition=No`, `FileSystem=LeaveAlone`, bez
`AutoPartition`) plus to, co dziś dopisuje `build_xp_uefi_csm_trial.py`
(`[SetupParams] UserExecute` dla PAE, `[GuiRunOnce]`). Generator dodaje:

```ini
[GuiUnattended]
AdminPassword="{{admin_password|*}}"
OEMSkipRegional=1
OemSkipWelcome=1
TimeZone={{nt5_timezone_index}}

[UserData]
FullName="{{full_name}}"
OrgName="{{org_name}}"
ComputerName={{computer_name}}
ProductKey="{{product_key}}"          ; 2000: ProductID=

[RegionalSettings]
LanguageGroup={{language_group}}      ; np. 2 = Europa Środkowa
SystemLocale={{lcid}}                 ; 00000415
UserLocale={{lcid}}
InputLocale={{input_locale}}          ; 0415:00000415

[Identification]
JoinWorkgroup=WORKGROUP

[Networking]
InstallDefaultComponents=Yes
```

Różnice w rodzinie (szczegóły w [nt5-uefi-family.md](nt5-uefi-family.md)):
Windows 2000 używa `ProductID` zamiast `ProductKey`, domyślnie
`TargetPath=\WINNT`; Server 2003 wymaga `[LicenseFilePrintData]
AutoMode=PerServer|PerSeat` (inaczej Setup zatrzymuje się na stronie
licencjonowania) i ma `[Display]`/`[TerminalServices]`; XP x64 i 2003 x64
mają katalog `AMD64` zamiast `I386`, ale ten sam format SIF.
`UnattendMode` zostaje `ProvideDefault` (nie `FullUnattended`: zmienia
tryb GUI, odrzuca niepodpisane sterowniki i zatrzymuje się przy braku
odpowiedzi, co jest udokumentowane w `windows-xp-uefi-csm-pae`).
NT4 (`unattend.txt` dla `winnt /u`) ma zbliżony, starszy format
i dostanie własny szablon dopiero razem z pozycją roadmapy NT4.

### 3.2 NT6+: `autounattend.xml` (Vista, 7, 8/8.1, 10, 11)

Jeden szablon z warunkami per wersja (wersja z `<WINDOWS><VERSION>` XML WIM,
tak jak klasyfikuje dziś `winmedia` / `wim_setup.zig`), architektura
w `processorArchitecture` (`amd64`/`x86`) z `<ARCH>` WIM:

- `windowsPE`: `International-Core-WinPE` (UILanguage, InputLocale,
  SystemLocale, UserLocale); `Setup` → `UserData` (`AcceptEula=true`,
  `ProductKey` tylko gdy podany, `WillShowUI=OnError`),
  `ImageInstall/OSImage/InstallFrom/MetaData` (`/IMAGE/INDEX` = wybrana
  edycja), `InstallTo` tylko w trybie „dysk wybrany w USOS” (sekcja 5).
- `specialize`: `Shell-Setup` (`ComputerName`, `RegisteredOwner`,
  `TimeZone`).
- `oobeSystem`: `International-Core`, `Shell-Setup/OOBE`
  (`HideEULAPage`, `ProtectYourPC=3`, `HideOnlineAccountScreens` dla 8+,
  `HideWirelessSetupInOOBE`, `SkipMachineOOBE`/`SkipUserOOBE` wyłącznie
  dla Vista/7, bo od 8 są przestarzałe), `UserAccounts/LocalAccounts`
  (konto w grupie `Administrators`).
- Vista: własny przepływ `windows_vista_install.c` generuje już
  odpowiedź serwisową i weryfikuje payload hashami; generator **nie
  zastępuje** tej odpowiedzi, tylko dostarcza fragmenty `windowsPE`/
  `oobeSystem`, które ten przepływ scala (osobny krok migracji).
- Windows 7 przez WinPE (PE7/PE10): istniejący `usos-unattend-drivers.exe`
  dopisuje `DriverPaths`; wygenerowany plik przechodzi przez to samo
  scalenie, więc sterowniki użytkownika działają bez zmian. Uwaga
  z `docs/drivers.md`: wymuszenie `/unattend` na stock PE7 powoduje pytanie
  o klucz. Jak wygenerowany plik bez klucza ma się zachować na stock PE7
  (pominięcie strony klucza, `WillShowUI`), trzeba ustalić testem w QEMU
  przed włączeniem formularza dla Windows 7.

**Windows 11: obejścia wymagań (opcjonalne, domyślnie wyłączone).**
Pokazywane z opisem „instalacja na sprzęcie niespełniającym wymagań nie
jest wspierana przez Microsoft; aktualizacje funkcji mogą wymagać
ponownego obejścia”. To ustawienia rejestru, a nie łamanie zabezpieczeń
ani licencji; są powszechnie stosowane (Rufus, E2B `skip TPM.xml`):

- `windowsPE` → `Deployment/RunSynchronous`: `reg add
  HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck|BypassSecureBootCheck|
  BypassRAMCheck|BypassCPUCheck /t REG_DWORD /d 1` (każde osobnym
  przełącznikiem; tylko te, które użytkownik zaznaczył),
- konto lokalne bez konta Microsoft: `LocalAccounts` w `oobeSystem`
  (działa z plikiem odpowiedzi niezależnie od `BypassNRO`) oraz opcjonalnie
  `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE BypassNRO=1`
  w `specialize`. Zachowanie `BypassNRO` zmienia się między buildami
  (Microsoft usuwa kolejne obejścia), więc każdy build 11 trzeba
  potwierdzić w QEMU przed oznaczeniem jako działający.
- Nowy Setup 24H2+ nadal honoruje `autounattend.xml` z katalogu głównego
  nośnika (WORK); test QEMU musi to potwierdzić dla każdego wspieranego
  wydania.

### 3.3 9x: `msbatch.inf` (98 SE, 98, Me)

Zgodnie z planem w `docs/research/win98-feasibility.md` §11.1:
`SETUP C:\WIN98\MSBATCH.INF /IS` (dziś Core uruchamia `SETUP /IS`).

```ini
[Setup]
Express=1
InstallDir="C:\WINDOWS"
InstallType=1
EBD=0
ChangeDir=0
ProductKey="{{product_key}}"
TimeZone="{{win9x_timezone_name}}"

[NameAndOrg]
Name="{{full_name}}"
Org="{{org_name}}"
Display=0

[Network]
ComputerName="{{computer_name}}"
Workgroup="WORKGROUP"
Display=0
```

Klucze `[System]` dla locale/klawiatury i format `TimeZone` w 9x trzeba
potwierdzić na podstawie `DEPLOY.TXT`/Resource Kit z ISO użytkownika
i testem w VM; do tego czasu profil 98 pokazuje tylko pola z tabeli
powyżej, które przejdą test. Klucz produktu 98 jest obowiązkowy dla
bezobsługowego Setup; bez niego Setup zapyta sam.

## 4. Scalanie z plikami użytkownika

Trzy tryby, jawnie wybierane:

1. **Plik użytkownika 1:1** (dziś): bez zmian, z obecnymi politykami
   (`xp_unattended_policy.sh`, odmowa pliku celującego w dysk USOS
   w `usos-unattend-drivers.exe`).
2. **Wygenerowany**: tylko szablon + odpowiedzi.
3. **Scalony**: plik użytkownika jako baza, formularz nadpisuje wybrane
   pola. Reguły:
   - XML: scalanie po kluczu `(pass, component name,
     processorArchitecture, ścieżka elementu)`. Elementy listowe
     (`LocalAccount`, `RunSynchronousCommand`, `SynchronousCommand`,
     `PathAndCredentials`) są dopisywane z kolejnym `Order`/`wcm:keyValue`,
     nigdy nie zastępują istniejących. Brak parsera DOM w firmware:
     parser strumieniowy o stałej pamięci (limit 1 MiB pliku, jak INF
     w `inf_package.zig`), a wynik jest ponownie parsowany i walidowany.
   - SIF/INF: scalanie po `(sekcja, klucz)`, porównanie bez rozróżniania
     wielkości liter, komentarze i nieznane sekcje zachowane.
   - **Klucze należące do USOS** nie mogą być nadpisane przez użytkownika
     ani formularz: NT5 `[Data]`, `Repartition`, `FileSystem`,
     `AutoPartition` (zawsze nieobecne), `[SetupParams] UserExecute`
     (PAE), wpis PAE w `[GuiRunOnce]`, `OemPnPDriversPath` (budowany przez
     etap sterowników); NT6 `DriverPaths` od USOS, `LabConfig` tylko
     z formularza. Konflikt = czytelny komunikat, nie ciche nadpisanie.
   - Po scaleniu uruchamiane są te same polityki co dla pliku
     użytkownika. Scalony SIF odblokowuje ścieżkę XP UEFI-CSM, która dziś
     odrzuca własny SIF, bo klucze USOS są gwarantowane.
4. Każdy render zapisuje obok pliku docelowego `usos-answer.log`
   (skrót SHA-256 wyniku, lista źródeł i nadpisanych pól **bez
   wartości** klucza/hasła).

## 5. Bezpieczeństwo wyboru dysku

Największe ryzyko generatora: plik odpowiedzi z `WillWipeDisk=true` na
złym dysku (E2B ma wprost próbki `ZZDANGER_Auto_WipeDisk0`). Zasady:

- **Domyślnie brak `DiskConfiguration` i `InstallTo`**: Setup pokazuje
  własną listę dysków. Tak jest dziś i to zostaje domyślne.
- **Tryb „dysk wybrany w USOS”** jest dostępny tylko tam, gdzie USOS ma
  już własny, przetestowany wybór dysku z guardem
  (`target_disk_guard.sh`, `target_disk_identity.sh`: model, numer
  seryjny, pojemność, wykluczenie pendrive'a USOS, zamontowanych
  partycji i swapu) i jedno potwierdzenie „ANULUJ” domyślnie
  (wzorzec XP/98).
- **Numer dysku w WinPE nie jest numerem z Linuksa.** Dlatego
  generator nigdy nie wpisuje `DiskID` z Linuksa. Plik zawiera
  wyłącznie znacznik tożsamości (serial, rozmiar w bajtach, podpis MBR
  lub GUID GPT zapisany przez mikro-Linux przy przygotowaniu dysku),
  a `DiskID` wiąże dopiero `usos-answer.exe` w WinPE (uruchamiany przez
  skrypt startowy USOS tuż przed `setup.exe`): wylicza dyski,
  szuka **dokładnie jednego** pasującego, odmawia, gdy pasuje zero lub
  więcej niż jeden, albo gdy trafiłby w dysk z `.usos-work`/ESP USOS,
  i dopiero wtedy wpisuje `DiskID` do kopii pliku w RAM. Ścieżka WORK
  (8/10/11) startuje dziś niezmieniony `boot.wim` bez skryptu USOS, więc
  tam tryb jest niedostępny, dopóki pomocnik nie zostanie wstrzyknięty
  (osobna decyzja: zmiana `boot.wim` na WORK albo start przez wimboot).
- Mikro-Linux sam tworzy układ partycji na wybranym dysku (jak w XP), a
  XML używa `InstallTo` na istniejącą partycję zamiast
  `WillWipeDisk`. `WillWipeDisk=true` nie jest generowane nigdy.
- NT5: bez zmian względem dzisiejszego, zweryfikowanego modelu:
  instalacja na partycję z `$WIN_NT$.~LS` przygotowaną przez USOS,
  `AutoPartition` nigdy.
- 98: wybór dysku w menu Core jak dziś; `msbatch.inf` nie zawiera
  żadnych ustawień partycjonowania.

## 6. Walidacja

- Pola: długości i zestawy znaków (NetBIOS, format klucza
  `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`, bez sprawdzania ważności klucza),
  zależności (konto lokalne wymaga nazwy).
- Wynik: ponowne sparsowanie, sprawdzenie par pass/komponent znanych dla
  wersji (tabela danych), polityki bezpieczeństwa (sekcja 5), rozmiar.
- Testy: wektory Zig/Go (sekcja 2), testy polityk, oraz **zaliczenie
  wg starej roadmapy**: wygenerowany plik przechodzi rzeczywistą
  instalację w QEMU bez ręcznych poprawek, osobno dla 11, 10, 7, XP, 2000
  i 98, zanim profil pokaże pozycję `Utwórz automatycznie…`.

## 7. i18n

- Etykiety formularza, podpowiedzi i błędy walidacji: nowe klucze
  `boot.answer.*` w istniejącym katalogu 27 locale (`src/i18n`,
  generowany przez `usos-i18n-gen`, `lang.bin`), z oznaczeniem
  tłumaczeń maszynowych jak dziś.
- **Język UI USOS ≠ język instalowanego systemu** (zasada ze starej
  roadmapy, pkt 4). Formularz proponuje locale systemu z języka UI, ale
  lista locale pochodzi z obrazu: `<LANGUAGES>` z XML WIM (6.x+),
  `TXTSETUP.SIF`/`[Strings]` i znaczniki ISO dla NT5, wersja językowa
  dyskietki 98. Nie da się wybrać `pl-PL` na angielskim nośniku bez
  pakietu językowego.
- Tabele danych (jeden plik TSV, czytany przez Zig i Go): locale → LCID,
  tag BCP-47, grupa językowa NT5, domyślny KLID klawiatury, strefa
  czasowa Windows, indeks strefy NT5, nazwa strefy 9x. Wartości spisać
  z dokumentacji Microsoft („Default Input Profiles”, „Time Zone Index
  Values” dla NT5) i sprawdzić testem jednostkowym na kilku znanych
  parach (pl-PL → `0415:00000415`).
- Układy klawiatury dla pól tekstowych w menu (pozycja roadmapy
  „keyboard layouts”): UEFI `SimpleTextInputEx` podaje znaki wg układu
  firmware (zwykle US), więc menu mapuje kody skanów przez własną
  tabelę układu (QWERTY-PL, QWERTZ, AZERTY na start). Wpisywana nazwa
  i hasło są ograniczone do znaków, które docelowy format przyjmuje.

## 8. Kolejność wdrożenia

1. Biblioteka renderu + wektory + tabela locale (Zig, Go), bez UI.
2. Towarzysze `.xml`/`.sif`/`.key`/`.txt` (samo rozpoznawanie, 1:1).
3. Formularz 10/11 przez WORK (najczęstszy przypadek, bez trybu dysku).
4. Scalanie XML; Windows 7 (z `usos-unattend-drivers.exe`).
5. NT5: scalony SIF (odblokowuje własny SIF w XP UEFI-CSM).
6. Tryb „dysk wybrany w USOS” z pomocnikiem WinPE.
7. 98 `msbatch.inf` (po weryfikacji kluczy w VM), Vista (scalanie z
   odpowiedzią serwisową), 2003/XP x64 razem z rodziną NT5.

## 9. Generator Schneegansa (dodane 2026-09-25)

Użytkownik korzysta z <https://schneegans.de/windows/unattend-generator/>.
Źródło: <https://github.com/cschneegans/unattend-generator>, biblioteka
C#/.NET Core (katalogi `modifier/` i `resource/` z szablonami XML).
**Licencja: MIT** (plik `LICENSE.txt` w repozytorium, sprawdzone na stronie
GitHub 2026-09-25). MIT pozwala na użycie i przetwarzanie z zachowaniem
noty o prawach autorskich i tekstu licencji.

Decyzje:

- **Nie osadzamy jego kodu ani .NET.** USOS nie dostaje zależności od
  runtime .NET ani kopii biblioteki. Wykorzystujemy **wiedzę**: katalog
  ustawień (co generator umie ustawić i pod jakimi nazwami) i kształt XML
  dla każdej wersji Windows (pass, komponent, element). Jeżeli
  przenosimy konkretne fragmenty (np. tabelę ustawień albo szablon XML)
  do naszego kodu lub danych, dołączamy notę MIT i link do źródła
  (plik `THIRD_PARTY` / `licenses/unattend-generator/LICENSE`, wzorem
  `EFI/USOS/licenses/`). Sprawdzić licencję ponownie przed każdym takim
  przeniesieniem; przy zmianie licencji na niezgodną zostaje tylko
  zgodność formatu, bez kopiowania.
- **Pliki z generatora Schneegansa muszą działać jako importowane pliki
  odpowiedzi** (tryb „plik użytkownika 1:1” z sekcji 4 i baza do
  scalania). Przypadek odniesienia: plik użytkownika
  `L:\Systems\Windows\Windows 10\Unattended\win10-11 best-ustawienia.xml`
  (sprawdzona kopia o tej samej nazwie w
  `zig-out/usb/Systems/Windows/Windows 11/Unattended/`, 69 764 B):
  - brak `DiskConfiguration` (wybór dysku zostaje w Setup, zgodnie
    z sekcją 5),
  - wszystkie 6 komponentów z `processorArchitecture="amd64"`,
  - wszystkie 7 przebiegów (`windowsPE` … `oobeSystem`, także `audit*`),
  - generyczny klucz edycji w `ProductKey` (nie tajny, ale i tak nie
    logujemy treści),
  - komentarz z pełnym adresem URL generatora z parametrami
    (`...unattend-generator/?LanguageMode=...&ProcessorArchitecture=amd64...`)
    i skryptami PowerShell zakodowanymi w URL. Import może z niego
    odczytać ustawienia do podglądu, ale **nigdy go nie wykonuje** ani nie
    przepisuje; plik idzie 1:1.
  Test regresji: wektor z tym plikiem (lub jego zanonimizowaną kopią) przez
  całą ścieżkę 10/11 (WORK i natywny wimboot), porównanie bajtowe
  `Autounattend.xml` / `usos-unattend.xml` z oryginałem.
- **Ostrzeżenie o architekturze.** Plik tylko z komponentami `amd64`
  użyty z nośnikiem x86 (albo odwrotnie) nie robi nic: Setup pomija
  komponenty o innej architekturze bez komunikatu. Podsumowanie startu
  porównuje zbiór `processorArchitecture` z pliku z architekturą obrazu
  (`MediaInfo.arch`, już wykrywaną z `boot.wim`) i pokazuje ostrzeżenie
  (nie blokadę). Przypadek z X470 2026-09-25 (ISO Windows 10 x86) jest
  dokładnie tym scenariuszem.
- **Pełny kreator w instalatorze Go (Win32).** Ekran „Pliki odpowiedzi”
  instalatora dostaje pełny formularz (wzorowany na katalogu ustawień
  Schneegansa, w naszej kolejności) i zapisuje wynik do
  `DATA\Systems\Windows\<system>\Unattended\`. To główna droga do
  bogatych ustawień.
- **Szybka opcja w menu USOS na urządzeniu:** tylko nazwa konta, język
  (UI, locale, klawiatura, strefa czasowa z jednego wyboru) i „ręczny
  wybór dysku” (brak `DiskConfiguration`). Plik jest generowany **w
  chwili startu** (just in time) do RAM-dysku wimboot / WORK, bez zapisu
  na DATA (menu czyta DATA tylko do odczytu, sekcja 0).
- **Jeden model ustawień**, tłumaczony na `WINNT.SIF` dla XP/2000 i na
  `autounattend.xml` dla 7/10/11 (tabela z sekcji 1 jest jego pierwszą
  wersją). Model żyje w danych współdzielonych przez Zig (menu) i Go
  (instalator), sprawdzanych testem zgodności jak `os_profiles`.
- **Zakres na start: najczęściej używane opcje**: konto lokalne (nazwa,
  opcjonalne hasło), język/region/klawiatura/strefa, nazwa komputera,
  pominięcie ekranów OOBE i kont online, obejścia wymagań Win11
  (jawnie), edycja z `install.wim`. Kosmetyka (pasek zadań, menu Start,
  usuwanie aplikacji, skrypty) tylko przez import pliku albo kreator w Go,
  później.
