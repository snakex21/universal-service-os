# MS-DOS 6.22 i Windows 3.x — BIOS, 12 września 2026

USOS uruchamia MS-DOS 6.22 i programy z DATA oraz przygotowuje instalację
Windows 3.1 PL i Windows 3.11 OEM EN z dostarczonych obrazów. Pełne przebiegi
przeszły w QEMU. Na fizycznym Socket 939 zakończono instalację Windows 3.1
i potwierdzono zdjęciem start interfejsu w diagnostycznym trybie standardowym
bez SMARTDrive (opcja STD62). Zwykły start wcześniej zatrzymywał się przy logo.
Użytkownik potwierdził zapis TEST31.TXT i odczyt jego treści po restarcie.
Potwierdzenie fizyczne dotyczy trybu standardowego bez SMARTDrive;
produkcyjna odznaka pozostaje **TESTED IN VM** dla ogólnego zakresu metod.

## Obsługa

Windows → Windows 3.1 albo Windows 3.11 → ISO → Automatic. USOS wczytuje
źródła, pokazuje dysk docelowy i rozmiar nowej partycji FAT16. Domyślnie
wybiera 256 MiB; 128 i 512 MiB są dostępne, jeśli mieszczą się w geometrii
CHS udostępnianej przez BIOS. Potwierdzenie usuwa dotychczasowy układ partycji
wybranego dysku. Pendrive źródłowy jest wykluczony.

Po komunikacie `DOS and Windows Setup files are ready on the target disk`
należy wyjąć pendrive, zrestartować komputer i uruchomić dysk docelowy.
Oryginalny instalator Windows rozpocznie się sam. Dalsza instalacja korzysta
z `C:\WINSETUP`, więc nie wymaga USB ani przekładania dyskietek. Po zakończeniu
instalacji USOS przygotowuje menu startowe i prosi o jeszcze jeden restart,
aby ustawienia dopisane przez Setup nie pozostawały aktywne w pamięci.
Domyślny wybór po 8 sekundach uruchamia Windows w trybie standardowym
bez SMARTDrive. Pozostałe opcje to alternatywny tryb 386, wiersz DOS
i ustawienia myszy PS/2. Kopie konfiguracji sprzed menu są w `C:\USOSW3`.
Późniejsze zmiany ustawień przez użytkownika nie są cyklicznie nadpisywane.

DOS → MS-DOS → ISO → Automatic daje dwie możliwości:

- uruchomienie DOS-u i programów z USB w RAM;
- instalację MS-DOS na potwierdzonym dysku FAT16, z późniejszym startem
  bez pendrive'a.

Programy należy umieszczać w `Systems/DOS/MS-DOS/Programs`, najlepiej
każdy we własnym podfolderze. Nazwy muszą spełniać DOS 8.3, bez spacji
i znaków spoza ASCII. Obsługiwane są trzy poziomy podfolderów, pliki do
32 MiB i łączny rozmiar mieszczący się w dysku RAM oraz partycji docelowej.
Dołączony `DEMO/HELLO.COM` czyta sąsiedni `INPUT.TXT`.

W sesji z USB programy są dostępne w `C:\PROGRAMS`. `CD DEMO`, następnie
`HELLO`, uruchamia przykład. **C: jest wtedy dyskiem RAM: zapis działa,
ale zmiany znikają po wyłączeniu.** Tryb instalacji kopiuje programy na dysk
docelowy, gdzie zapis pozostaje trwały.

## Źródła i ich identyfikacja

MS-DOS pobrano za zgodą użytkownika ze wskazanej
[strony Winiso](https://winiso.pl/windows-desktop/ms-dos). MD5 archiwum
`fcb383b748838008530b33d234055143` zgadza się z wartością podaną na tej stronie.
Nie jest to porównanie z sumą opublikowaną przez Microsoft.

| Plik | SHA-256 |
| --- | --- |
| `MS-DOS_6.22.zip` | `13761fa745b6e27c232118a83c0bb50fe0d1d465d49467c04e8be195fb95a6b9` |
| wyodrębniony `MS-DOS 6.22.iso` | `ca112da07824a1e44ffeded4f49c55804b9dcbcbbfae604d987ffc22a1031d06` |
| `Windows_3.1_PL.iso` | `3b55aae78de23fab4ed530268083050f557b673c6c69af8ea90632eba549ccd6` |
| `Microsoft_Windows_3.11_(OEM)_(3.5)_EN.zip` | `89cff2545dd71e5833c6a5aca8031059d34bd5ad0f03f2c51ac36841dcd0fbec` |
| utworzony `Windows_3.11_EN_USOS.iso` | `2aece91081b8c46136c059765954ec1066631a1823c0b3adcf57c2d6d68d5f44` |

Konwerter `tools/prepare_windows3_media.py` sprawdził FAT12 sześciu dyskietek,
zachował wszystkie 460 plików bez zmian i utworzył płaski ISO9660. Odrzuca
sprzeczne duplikaty i niebezpieczne nazwy; pomija metadane macOS z ZIP-a.
Manifest zawiera sumę każdego pliku. Niezależny test ISO przez 7-Zip przeszedł.
Oryginalne ZIP-y i polski ISO pozostają zachowane.

DOS jest odczytywany z `Systems/DOS/MS-DOS/Images/MS-DOS 6.22.iso`.
Obrazy Windows znajdują się w odpowiednich katalogach `Windows 3.1/Images`
i `Windows 3.11/Images` pod `Systems/Windows`.

## Wyniki VM

QEMU TCG, CPU `athlon`, 2 GiB RAM, standardowe VGA, bez sieci. Źródłem był
osobny obraz USOS z produkcyjnym kodem BIOS i helperami. Każda instalacja
używała własnego dysku 2 GiB; partycja systemowa miała 256 MiB. Dysków
z zainstalowanymi systemami nie montowano w systemie gospodarza.

| Próba | Wynik |
| --- | --- |
| MS-DOS z USB | DOS 6.22, uruchomienie HELLO, odczyt INPUT.TXT, zapis i odczyt RESULT.TXT w RAM: PASS; podłączony dysk pozostał identyczny bajt w bajt z pustym obrazem |
| MS-DOS na dysku | przygotowanie FAT16, narzędzia DOS, start bez USB i HELLO: PASS; 203 pliki, zgodne oryginalne pliki rozruchowe i program testowy |
| Windows 3.1 PL | pełny oryginalny Setup, tryb rozszerzony 386, Notatnik, zapis USOSTEST.TXT i jego odczyt po zimnym starcie bez USB: PASS; 1069 plików |
| Windows 3.11 OEM EN | pełny oryginalny Setup, start poleceniem WIN, tryb rozszerzony 386, zapis i odczyt USOSTEST.TXT po zimnym starcie bez USB: PASS; 867 plików |
| regresja Windows 98 | start dotychczasowego DOS-u i skryptu naprawy; odmowa przy braku rozpoznanej instalacji: PASS; zero zapisów na źródle i celu |

Odczyt FAT16 potwierdził obie identyczne tablice FAT, poprawne granice
partycji i rozłączne łańcuchy klastrów. Porównano oryginalne IO.SYS,
MSDOS.SYS, COMMAND.COM oraz pliki programu DOS. Zawartość plików zapisanych
w Notatniku sprawdzono dokładnie, także poza gościem przez własny czytnik FAT.

`WINVER` pokazuje w obu zestawach 3.10. W angielskim zestawie wersje plików
potwierdzają wydanie 3.11: KRNL386.EXE, GDI.EXE i COMMDLG.DLL mają
`3.11.0.300`, a USER.EXE i SHELL.DLL `3.11.0.2`. W polskim obrazie GDI.EXE
ma `3.10.0.104`, USER.EXE, SHELL.DLL i COMMDLG.DLL — `3.10.0.103`.
Nie należy utożsamiać tego testu z walidacją Windows for Workgroups.

Dowody znajdują się w `zig-out/win3-work`: manifesty mediów,
`*-filesystem-verification.json`, `*-file-versions.json`,
`dos-live-final-demo.png`, `win31-cold-file-pass.png`,
`win311-cold-file-pass.png`, `win98-memdisk-regression.json` oraz logi
buildów i pełnego zestawu testów.

## Implementacja i granice

Wydanie `B260912-194048-3486503C` przeszło pełny `build.bat` i
`tools/tests/run.ps1 -Suite all`, włącznie z testami startowymi UEFI x86_64
i ARM64. Payload produkcyjnego BIOS Core ma 238 536 bajtów przy limicie
245 760; kontrola slota, CRC, zestawu instrukcji i zgodności plików wydania
przechodzi. Pełne instalacje sprawdzono przed końcową zmianą odznaki
i poprawką pakowania tych samych plików pomocniczych DOS.

Końcowa kontrola wykryła, że pakiet EXE pomijał dziesięć nowych plików DOS,
chociaż były obecne w poprzednim obrazie testowym. Listę pakowania poprawiono;
test zawartości osadzonego ZIP-a oraz kontrola zgodności wydania wymagają teraz
wszystkich dziesięciu plików. Końcowy obraz VM otrzymał wyczyszczoną ESP
i wyłącznie 57 plików z rzeczywistego pakietu instalatora. Sumy każdego pliku
zweryfikowano po zapisie. Ten obraz ponownie przeszedł test DOS-u, programu
HELLO i zapisu w RAM; podłączony dysk pozostał identyczny z pustym obrazem.
Ponowne przygotowanie dysku Windows 3.1 dało poprawne 798 plików FAT16
i start polskiego instalatora po odłączeniu USB. Dowody tej kontroli to
`fixture-payload-verification.json`, `packaged-dos-verification.json`,
`packaged-dos-demo-pass.png`, `packaged-win31-ready.png`,
`packaged-win31-setup-start.png` i `packaged-win31-filesystem-check.log`.

Przygotowanie DOS-u korzysta z oryginalnego SYS.COM i EXPAND.EXE z obrazu
MS-DOS. HimemX 3.40 ogranicza pamięć XMS sesji przygotowania do 32 MiB;
licencja i przypięte źródła są dołączone. Windows po restarcie używa
oryginalnego `C:\DOS\HIMEM.SYS /TESTMEM:OFF`. Nie wymaga poprawiania
plików systemowych Windows ani mikro-Linuksa.

Kod BIOS tworzy MBR/FAT16 w granicach rzeczywistego CHS i weryfikuje zapis
plików rozruchowych. Przed formatowaniem sprawdza źródła i tożsamość celu.
W sesji RAM fizyczne dyski twarde są odcięte przez filtr BIOS; podczas
instalacji dostępny jest wyłącznie wskazany cel. Testy wykonują rzeczywisty
kod filtra i MBR w emulatorze procesora.

Ikony BIOS otrzymały bezstratne kodowanie RLE: wszystkie piksele pozostały
identyczne. Dzięki temu nowy kod mieści się w dotychczasowym slocie Core,
bez podnoszenia limitu ani zmiany formatu rozruchowego.

Walidacja obejmuje wskazane media, BIOS i konfigurację VM. Nie potwierdza
sterowników konkretnej płyty, grafiki i dźwięku ani wszystkich aplikacji DOS.
FreeDOS, inne wydania MS-DOS, Windows for Workgroups oraz UEFI pozostają
osobnymi zakresami testów.

## Kingston i wynik wydania

Kingston DataTraveler 3.0, GPT `31c644bf-74dd-4807-9cb2-46745adeadd4`,
otrzymał wydanie `B260912-194048-3486503C`. Standardowy silnik aktualizacji
zakończył wszystkie pięć etapów wynikiem PASS i zweryfikował kod BIOS,
pliki ESP/DATA, kopię instalatora oraz niezmienioną tożsamość GPT.

Cztery obrazy ISO oraz `Programs/DEMO/HELLO.COM`, `INPUT.TXT` i
`Programs/README.TXT` skopiowano po sprawdzeniu źródeł i identyfikatorów
nośnika. Każdy nowy plik
otrzymał najpierw nazwę tymczasową, odczyt zwrotny SHA-256 i dopiero potem
nazwę docelową. Istniejący różniący się plik zatrzymałby kopiowanie.
Sumy sprawdzono ponownie po aktualizacji wydania.

Osobna kontrola fizycznej ESP potwierdziła obecność i SHA-256 wszystkich
dziesięciu plików DOS z końcowego pakietu oraz dokładną zgodność
`build-info.ini`. Powtórny odczyt trzech ISO, obrazu MemTest86+, programu
DEMO i instrukcji z DATA również dał PASS.

## Windows 3.1 na fizycznym Intelu — diagnostyka

Użytkownik zakończył oryginalny instalator na Socket 939, zrestartował
komputer i po poleceniu `WIN` zobaczył nieruchome logo Windows 3.1 PL.
Przy kolejnej próbie zgłosił `Bad command or file name`, a następnie,
po podaniu pełnej ścieżki do WIN.COM z `/S`, komunikat o HIMEM.SYS.
To nie jest pełny PASS działania Windows na tej płycie.

Po podłączeniu testowego dysku `INTEL SS DSC2BW120A4` (120 034 123 776
bajtów, sygnatura MBR `A1-AF-FF-C6`) odczytano jego konfigurację i wykonano
kopię MBR oraz całej partycji FAT16. Partycja zaczyna się na LBA 2048,
ma 524 288 sektorów; zapisany BPB podaje 240 głowic i 63 sektory na ścieżkę.
Kopia `intel-original.raw` ma SHA-256
`948b869acd7a3b224af5f36adb4b3e823f71eb2f09a54d2d389f25cf1ea9cc75`.
Podczas pierwszego odczytu fizycznego dysku nie modyfikowano narzędziami
diagnostycznymi; późniejszą zmianę konfiguracji opisano poniżej.

HIMEM.SYS istnieje w DOS i Windows. CONFIG.SYS zawiera prawidłowy wpis
`DEVICE=C:\DOS\HIMEM.SYS /TESTMEM:OFF`, a AUTOEXEC.BAT dodaje katalog
Windows do PATH. Oba pliki HIMEM, WIN.COM, oba jądra Windows, GDI,
sterownik VGA i PROGMAN są identyczne z plikami wcześniej przetestowanej VM.
Obie kopie FAT są zgodne, łańcuchy klastrów poprawne i rozłączne; odczytano
1070 plików. 1059 wspólnych plików jest identycznych z referencyjną VM.

Kopia tej konkretnej instalacji uruchomiła interfejs Windows zarówno przez
`WIN /S`, jak i `WIN`, w QEMU Athlon z 2 GiB RAM i geometrią 240/63.
Pojawił się Menedżer programów i oczekujące okno konfiguracji strony
kodowej 852. Test korzystał z osobnego QCOW2; oryginalna kopia RAW pozostała
bazą tylko do odczytu. Dowody: `intel-clone-standard.png`,
`intel-clone-normal.png`, `intel-config-readback.log`,
`intel-filesystem-check.log`, `intel-physical-evidence` w katalogu testu.

Użytkownik wykluczył użycie F5/F8/Shift. Zdjęcia kolejnego normalnego startu
na 939 potwierdziły załadowanie HIMEM, SMARTDrive oraz około 62 MiB wolnej
pamięci XMS. Brak HIMEM nie wyjaśnia aktualnego zawieszenia. Próba
`WIN.COM /B /D:FSVX` również nie dała pulpitu. Po ponownym podłączeniu
Intela kopia całej partycji wraz z prefiksem MBR (`intel-before-diag.raw`)
okazała się bit w bit identyczna z pierwszą kopią — ma ten sam SHA-256.
BOOTLOG.TXT nadal opisywał SETUP.EXE; nowy dziennik nie przetrwał na dysku.
Buforowanie zapisu SMARTDrive mogło zatrzymać wpisy w RAM, lecz nie jest
to dowód przyczyny zawieszenia Windows.

Na tym konkretnym Intelu zapisano diagnostyczne CONFIG.SYS i AUTOEXEC.BAT.
Kopie oryginałów oraz skrypt przywracania są w `C:\USOSDIAG`; przywrócenie
poleceniem `C:\USOSDIAG\RESTORE.BAT` wymaga późniejszego restartu.
Menu DOS czeka na wybór i udostępnia:

1. `STD62`: oryginalny HIMEM z DOS 6.22, bez SMARTDrive, `WIN /S /B`.
2. `ENH62`: ten sam HIMEM, tylko SMARTDrive DOUBLE_BUFFER bez cache,
   `WIN /3 /B`; opcja eksperymentalna.
3. `STD31`: oryginalny HIMEM z Windows 3.1, bez SMARTDrive, `WIN /S /B`.
4. `ORIGINAL`: wcześniejsze sterowniki i cache, start do wiersza DOS.

Przed próbą skrypt zapisuje wybór oraz wynik MEM /C do `C:\USOSDIAG`.
Przy następnym uruchomieniu diagnostycznym archiwizuje istniejący BOOTLOG
pod nazwą poprzedniego profilu i usuwa plik roboczy, aby starego dziennika
nie pomylić z nowym. Oryginalny dziennik jest zachowany jako BOOTOLD.LOG.
Odczyt zwrotny plików konfiguracji po fizycznym zapisie dał zgodność SHA-256.
Nie zmieniano układu partycji, plików wykonywalnych Windows ani wydania USOS.

Na osobnych kopiach QEMU opcje STD62 i STD31 osiągnęły Menedżera programów
i okno konfiguracji strony kodowej 852. Odczyt FAT po wyłączeniu VM
potwierdził zapis nowych dzienników 3688 B, raportów MEM i identyfikatora
próby. Wymuszony tryb 386 bez cache zatrzymał się na szarym ekranie zarówno
z `/D:FSVX`, jak i bez tych przełączników; nie ma dla niego PASS interfejsu.
Opcja ORIGINAL poprawnie uruchomiła DOS i SMARTDrive. Dowody znajdują się
w `intel-diag-mode*-evidence`, `intel-diag-mode1.png`, `intel-diag-mode3.png`,
`intel-diag-v2-mode2.png`, `intel-diag-v2-mode4.png` i `intel-diag-stage`.
Użytkownik następnie uruchomił na fizycznym Socket 939 opcję 1 (STD62)
i potwierdził brak błędu. Zdjęcie `codex-clipboard-f7dad05f-041c-4140-844f-d007e6712752.png`
pokazuje Menedżera programów i okno uzupełnienia DOS o stronę kodową 852.
To potwierdza fizyczny start interfejsu z HIMEM DOS 6.22, bez SMARTDrive,
przez WIN /S /B. Nie rozdziela wpływu wyłączenia SMARTDrive od wymuszenia
trybu standardowego; przyczyna wcześniejszego zawieszenia nie jest ustalona.
Użytkownik następnie zapisał TEST31.TXT i pokazał go otwartego w Notatniku
z treścią `test czy dziala`. W odpowiedzi na osobne pytanie potwierdził,
że zdjęcie wykonał po restarcie komputera, ponownym wyborze opcji 1
i otwarciu pliku. Zapis i odczyt po restarcie: PASS w tym profilu.
Zdjęcie: `codex-clipboard-bf603a1f-72f2-44d5-a2f9-b3136dc4f467.png`.
Mysz fizyczna nie działała; konfiguracja instalacji wskazywała NOMOUSE.DRV.
Nie jest to dowód niezgodności konkretnej myszy PS/2.

Dalszy test dotyczył A4Tech OP-620 z fabryczną wtyczką PS/2, bez
przejściówki. Po rozpakowaniu MOUSE.CO_ oryginalny sterownik DOS 8.20
zgłosił `Mouse driver installed`, a użytkownik potwierdził działanie myszy
w EDIT. Zdjęcie: `codex-clipboard-47fe5595-b7ed-422d-b546-177dda3ca22f.png`.
Uruchomienie Windows w tej samej sesji nadal nie dawało obsługi myszy.
Po ponownym otwarciu Setup użytkownik ustalił, że pozostawił zaznaczone
„bez myszy”, zamiast wybrać sterownik PS/2, i zgłosił wynik PASS.
To zgłoszenie użytkownika; nie wykonano nowego odczytu fizycznego dysku
ani niezależnej kontroli końcowego SYSTEM.INI.

## Menu nowych instalacji — wydanie B260912-215314-549458CB

Po potwierdzeniu fizycznego zapisu i odczytu dodano menu do produkcyjnej
ścieżki instalacji Windows 3.x. Cztery pliki `W3START.BAT`, `WINMENU.BAT`,
`W3CONFIG.SYS` i `W3AUTO.BAT` są pakowane w instalatorze oraz kopiowane
na dysk do `C:\USOSW3`. Po oryginalnym Setup pomocnik jednorazowo zachowuje
CONFIG.SYS i AUTOEXEC.BAT, instaluje menu, porównuje zapisane pliki
i opróżnia ewentualny bufor SMARTDrive poleceniem `/C`. Następnie wymaga
restartu. Znacznik MENU.TAG zapobiega powtarzaniu tej operacji.

Menu oferuje tryb standardowy bez SMARTDrive (domyślny po 8 sekundach),
alternatywny tryb 386, DOS oraz ustawienia myszy PS/2. Opcja ustawień
przygotowuje brakujący oryginalny MOUSE.DRV ze źródła w C:\WINSETUP,
po czym otwiera DOS-owy Setup. Należy wybrać Microsoft lub IBM PS/2
i zachować istniejący sterownik klawiszem Enter. Sam Setup bez tego
przygotowania zgłaszał w testowanej instalacji błąd 83 przy kopiowaniu
sterownika z płaskiego źródła.

Pełna nowa instalacja Windows 3.1 PL z końcowego pakietu przeszła w QEMU:
przygotowanie 802 plików, oryginalny Setup, automatyczna instalacja menu
z kopiami konfiguracji, zimny start bez USB i domyślny start interfejsu.
Oddzielnie sprawdzono wejście do DOS oraz zmianę ustawienia z braku myszy
na PS/2: po zimnym starcie działały kursor i kliknięcie. Odczyt końcowy
1075 plików potwierdził MOUSE.DRV, wpis sterownika w SYSTEM.INI i dokładną
zgodność konfiguracji menu z pakietem również po zmianie ustawień myszy.
Obie tablice FAT16 były identyczne, a łańcuchy klastrów rozłączne.
Dowody: `win31-menu-prepared-evidence`, `windows-menu-installed-check.json`,
`win31-menu-auto-installed.png`, `win31-menu-cold-default-gui.png`
oraz `win31-menu-ps2-click-pass.png`, `windows-menu-final-check.json`
i `win31-menu-evidence` w `zig-out/win3-work`.

Końcowy `build.bat` przeszedł testy Zig, Go i kontrolę zgodności wydania;
pełny zestaw testów, włącznie ze startem UEFI x86_64 i ARM64, przeszedł
przed końcowym uzupełnieniem pomocnika PS/2. BIOS Core ma 238 556 bajtów
przy limicie 245 760. Kingston o wskazanym wyżej GUID otrzymał to wydanie
13 września: wszystkie pięć etapów aktualizacji zakończyło się PASS.
Odczyt zwrotny potwierdził sumy SHA-256 plików, w tym czterech nowych
pomocników, oraz niezmienioną tożsamość GPT. Log operacji:
`zig-out/win3-work/kingston-menu-operation.log`.

Aktualizacja Kingstona dotyczy nowych instalacji. Fizyczny Intel używany
na Socket 939 nadal ma wcześniejsze menu diagnostyczne. Dalszy wynik
diagnostyki fizycznej myszy opisano powyżej: działała w DOS, a w Setup
nadal pozostawał wybór „bez myszy”; użytkownik zgłosił PASS po rozpoznaniu
pominiętego ustawienia.

## Wygodny restart — wydanie B260913-081719-DAAA3EA0

Po kolejnej instalacji na sprzęcie użytkownik potwierdził dostęp do Windows
przez nowe menu, ale zgłosił nieczytelne zakończenie przygotowania i potrzebę
ręcznych restartów. Na jego życzenie oryginalny Setup pozostaje obecną
ścieżką oraz przyszłym trybem awaryjnym. Ta zmiana nie zastępuje instalatora
ani nie zmienia ustawień językowych Windows.

Zakończenie przygotowania czyści ekran, opisuje następny etap i pozostawia
jeden wiersz `D:\>REBOOT`. Polecenie jest wpisane, lecz niezatwierdzone:
użytkownik wyjmuje USB i naciska Enter. Esc kasuje polecenie zgodnie ze
standardowym zachowaniem COMMAND.COM. Analogiczne `C:\>REBOOT` pojawia się
po przygotowaniu końcowego menu Windows/DOS. Ostatni restart pozostaje
wymagany, aby wyłączyć aktywną konfigurację oryginalnego Setup i załadować
docelowe sterowniki z CONFIG.SYS. Komunikat jasno uprzedza o tym kroku.

Własny REBOOT.COM ma 177 bajtów. Tryb `/P` usuwa wcześniejsze znaki
z bufora klawiatury i wstawia samo słowo REBOOT, bez Enter. Wykonane
polecenie opróżnia bufory DOS i przechodzi do startu BIOS POST, zamiast
ponawiać rozruch przez INT 19h z pozostawionymi przechwyceniami MEMDISK.
Skrypt menu wcześniej opróżnia także ewentualny bufor SMARTDrive.
Plik jest częścią pakietu i trafia na dysk do `C:\DOS`.

Pełny build i Suite all przeszły, włącznie ze startem UEFI x86_64 i ARM64.
Cztery testy wykonują rzeczywisty kod COM: przygotowanie polecenia bez
Enter i odrzucenie starych klawiszy, opróżnienie buforów przed restartem,
odrzucenie nieznanych argumentów oraz usunięcie częściowo wpisanego
polecenia przy błędzie klawiatury. Osobna VM potwierdziła ekran menu
z oczekującym REBOOT, skasowanie przez Esc i restart do interfejsu Windows.
Dowody: `restart-menu-prefilled.png`, `restart-menu-escape.png`,
`restart-probe-gui-pass.png`, `windows-restart-build.log`
i `windows-restart-tests.log` w `zig-out/win3-work`.

Świeży test z rzeczywistego pakietu instalatora (62 pliki ESP) uruchomiono
z wirtualnego USB. Przygotowanie zakończyło się jednym `D:\>REBOOT`.
Urządzenie USB odłączono przez QMP przed naciśnięciem Enter; REBOOT
uruchomił oryginalny Setup z samego dysku. Odczyt FAT16 potwierdził
803 pliki, poprawne obie tablice FAT oraz zgodność pięciu pomocników
z końcowym pakietem. Dowody: `restart-e2e-stage1-ready.png`,
`restart-usb-unplugged.json`, `restart-e2e-setup.png`
i `restart-prepared-check.json`. Pełnego oryginalnego Setup nie powtarzano
w tej próbie; pozostaje potwierdzony wcześniejszymi pełnymi instalacjami.

Kingston otrzymał wydanie `B260913-081719-DAAA3EA0`; wszystkie pięć etapów
aktualizacji zakończyło się PASS. Odczyt zwrotny potwierdził pliki wydania,
w tym REBOOT.COM, i niezmienione identyfikatory oraz układ GPT. Log:
`kingston-restart-operation.log`. Ta poprawka dotyczy kolejnych instalacji;
już zainstalowany Windows na fizycznym Intelu nie był modyfikowany.

## MemTest86+

Na pendrive dodano oficjalny, otwartoźródłowy MemTest86+ 8.10 i586:
`Utilities\MemTest86\Images\memtest86plus-8.10-i586.iso`. Obraz jest
przeznaczony również do uruchamiania przez klasyczny BIOS, więc pasuje do
testu Socket 939. Archiwum pobrane z [memtest.org](https://www.memtest.org/)
ma SHA-256 `a55c3a12b6c4d4f444df3e5213aa85045f2629eb0d56e98a06cc31ef1cda51b9`,
a wyodrębnione ISO `fa0d8a5c01d6c235393c05150dd572e3069b2f4456a26afaeae48ee3fba2e4bd`.
ISO uruchomiono w QEMU na CPU Athlon: ekran MemTest86+ v8.10 wystartował,
wykrył 255 MiB i rozpoczął test z `Errors: 0`; dowód to
`memtest-qemu.png`. Odczyt końcowy pliku z fizycznego DATA potwierdził tę
samą sumę SHA-256. Ten test uruchamiał ISO bezpośrednio jako nośnik VM.
Nie potwierdza uruchamiania z menu Utilities USOS: obsługa wykonania
narzędzi z tego menu pozostaje do zaimplementowania.

Logi: `copy-usb-media.log`, `usb-final-media-readback.log`,
`usb-final-payload-readback.log`, `kingston-update-final.log` (`RESULT=PASS`)
i `kingston-operation-final.log` w katalogu testu.
Wszystkie VM zostały wyłączone; zainstalowane dyski i dowody testów
pozostały w folderze projektu. Fizyczny test Windows 3.1 potwierdził start
interfejsu w STD62, trwały zapis pliku i jego odczyt po restarcie.
Tryb 386 na Socket 939 pozostaje niepotwierdzony. Wynik dotyczący myszy
opiera się na teście DOS i późniejszym zgłoszeniu użytkownika opisanym wyżej.
