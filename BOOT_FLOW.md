# Przepływ uruchamiania obrazu

Secure Boot (24 września 2026): `\EFI\BOOT\BOOTX64.EFI` to podpisany przez
Microsoft shim 16.1 (Fedora), a USOS startuje jako `grubx64.efi` podpisany
kluczem USOS (MOK). Przy pierwszym starcie z włączonym Secure Boot shim otwiera
MokManager: Enroll key from disk -> `EFI\USOS\ENROLL_THIS_KEY_IN_MOKMANAGER.cer`,
raz na komputer. Jądro mikro-Linuksa, systemd-boot i sterownik NTFS mają podpis
USOS, wimboot podpis Microsoft. Przy włączonym Secure Boot Windows XP, 7 i Vista
są oznaczone „Wymaga wyłączenia Secure Boot”.
[Projekt, klucz i ograniczenia](docs/secure-boot-usos.md).

Hardware & SMART, poprawa panelu (13 września 2026): start pokazuje procent
odczytu plików oraz kolejne etapy wykrywania sprzętu. Dyski mają nazwy
z modelem i pojemnością. Atrybuty SMART są wyświetlane w tabeli, a surowy
raport jest osobnym widokiem. Nazwy `/dev/...` pozostają wewnętrznymi
identyfikatorami i logami, bez wyświetlania w panelu.
[Opis tabel](docs/hardware-smart-tables-2026-09-13.md).

FreeDOS, BIOS (13 września 2026): `Utilities -> FreeDOS` buduje dysk FAT16
64 MiB w RAM, ładuje przypięte pliki FreeDOS 1.4 i Doszip oraz kopiuje
`Utilities/FreeDOS/Programs` z DATA do `C:\PROGRAMS`. Start jest natywny,
bez mikro-Linuksa, instalacji na dysku ani obrazu ISO. Menu plików pozwala
uruchamiać programy DOS i dopisywać parametry. F10 otwiera wiersz DOS,
`REBOOT` wraca do USOS przez restart. Sesja i wyniki istnieją tylko w RAM.
[Zakres i testy](docs/freedos-tools-bios-2026-09-13.md).

Hardware & SMART, BIOS (13 września 2026): wbudowana pozycja
`Utilities -> Hardware & SMART` uruchamia panel informacji o CPU, RAM,
płycie, BIOS-ie, urządzeniach PCI i dyskach. Wymaga procesora x86-64.
Odczyt SMART nie uruchamia autotestów ani nie zmienia ustawień dysku;
raporty istnieją tylko w RAM. Powrót do USOS restartuje komputer.
[Zakres i testy](docs/hardware-smart-bios-2026-09-13.md).

Memtest86+ i586, BIOS (13 września 2026): `Utilities -> MemTest86 -> ISO -> Enter`
odczytuje `BOOT/FLOPPY.IMG` z wybranego ISO na DATA. USOS sprawdza tożsamość
programu, nagłówek rozruchu i dostępność pamięci, po czym przekazuje sterowanie
bezpośrednio do Memtest86+ z mapą E820 i informacją o ekranie. Ta ścieżka nie
wybiera ani nie przygotowuje dysku docelowego. Pozostałe obrazy narzędzi i formaty
nie mają jeszcze obsługi startu BIOS. [Zakres i testy](docs/memtest-bios-2026-09-13.md).

MS-DOS 6.22 i Windows 3.1 / 3.11, BIOS (12 września 2026): `Automatic`,
`ISO` i `Memdisk` korzystają z natywnego odczytu źródeł z DATA. DOS można
uruchomić z programami w RAM albo zainstalować na dysku FAT16. Windows 3.x
przygotowuje DOS i pliki Setup na wybranym dysku; po komunikacie zakończenia
trzeba wyjąć USB i zrestartować komputer. Oryginalny Setup uruchomi się sam.
Ekran zakończenia przygotowuje `REBOOT` w jednym wierszu DOS, bez Enter;
użytkownik zatwierdza je po wyjęciu USB. Takie samo polecenie jest gotowe
po przygotowaniu końcowego menu Windows/DOS.
Po jego zakończeniu USOS zachowuje kopie konfiguracji i przygotowuje menu
Windows/DOS. Kolejny restart ładuje czystą konfigurację; po 8 sekundach
domyślnie rusza `WIN /S /B`, bez SMARTDrive. Menu udostępnia też tryb 386,
wiersz DOS i ustawienia myszy PS/2. Pełne instalacje przeszły w VM.
Użytkownik potwierdził na Socket 939 start trybu standardowego bez SMARTDrive
oraz zapis i odczyt pliku po restarcie.
[Obsługa, media i ograniczenia](docs/dos-windows3-bios-2026-09-12.md).

Windows 10 22H2 x86, BIOS (12 września 2026): `Automatic` i `ISO` odczytują
wybrane ISO bezpośrednio z NTFS i uruchamiają Windows PE przez wimboot.
Oryginalny instalator korzysta z tego samego ISO mapowanego tylko do odczytu.
Pełna instalacja Windows 10 Pro 19045.6396, pulpit i ponowny start z samego
dysku po wyłączeniu przeszły w VM z 2 GiB RAM i wyłączonym zgłaszaniem CX16.
Użytkownik potwierdził następnie działanie na fizycznym MS-7100 / Socket 939.
Po pierwszym restarcie instalatora trzeba uruchomić dysk docelowy.
[Szczegóły i ograniczenia](docs/windows10-x86-bios-2026-09-12.md).

Windows 2000 Professional SP4, BIOS (12 września 2026): metoda `Automatic`
korzysta ze wspólnego przygotowania NT5, sprawdza źródło Windows 2000 i tworzy
lokalne pliki instalacyjne na partycji NTFS. Po zakończeniu przygotowania
użytkownik wyjmuje USB, potwierdza wyłączenie i uruchamia komputer z dysku.
Natywne menu, przygotowanie, oryginalny Text Mode oraz pierwszy restart do
graficznego kreatora potwierdzono w VM. Pełna instalacja w VirtualBox zakończyła
się działającym pulpitem Windows 2000 SP4 z 2 GB RAM. Kingston z końcowym buildem
i ISO został zweryfikowany. [Szczegóły i ograniczenia](docs/windows2000-bios-2026-09-12.md).

Interfejs prowadzi użytkownika kolejno:

1. wybór kategorii: Windows / Linux / Beta builds / DOS / Utilities,
2. wybór systemu, dystrybucji albo grupy narzędzi,
3. wybór obrazu z katalogu `Images`,
4. wybór metody uruchomienia zgodnej z profilem i typem obrazu,
5. opcjonalny wybór pliku z `Unattended`,
6. potwierdzenie i start.

## Format obrazu a metoda startu

Format pliku i metoda uruchomienia są rozdzielone.

- ISO: Automatic, ISO, WIMBoot, Chainload lub Memdisk zależnie od profilu.
- WIM: Automatic lub WIMBoot.
- IMG: Automatic, Disk image, Floppy image, Chainload lub Memdisk.
- VHD/VHDX: Automatic lub VHDBoot.
- EFI: Automatic, EFI lub Chainload.

Dzięki temu jeden format nie jest przypisany na stałe do jednej techniki startu.

## Vista w BIOS: bezpośredni start z ISO

Vista korzysta z drogi: menu → pliki startowe z ISO na DATA → wimboot →
oryginalny Windows PE → to samo ISO tylko do odczytu → Setup. Nie wymaga
przygotowania WORK, mikro-Linuksa ani restartu przed instalatorem. Restart
wykonywany później przez sam instalator pozostaje częścią instalacji Windows.
Opis i wyniki pełnego testu: [Vista native ISO](docs/vista-native-iso-2026-09-11.md).

## Przygotowanie instalatora Windows w pozostałych ścieżkach

Windows 98 SE w Legacy BIOS ma własną ścieżkę opisaną poniżej; nie korzysta ze stanu przygotowania WORK.

Trwały stan przygotowania używa wartości `phase=pending`, `phase=prepare-requested`, `phase=prepared` i `phase=handoff`.

Docelowa kolejność dla instalatora Windows jest następująca:

1. USOS zapisuje `phase=prepare-requested` wraz z wybranym obrazem i opcjonalnym plikiem unattended.
2. Przed przekazaniem sterowania do mikro-Linuxa USOS odczytuje aktualny `BootOrder`, zapisuje jego dokładną kopię jako `USOSBootOrderBackup` i dopiero po udanym backupie ustawia `BootNext` na aktualny wpis `BootCurrent` USOS. `BootOrder` nie jest modyfikowany.
3. Mikro-Linux akceptuje wykonanie tylko przy `phase=prepare-requested`.
4. `device_guard.sh pre-format` musi przejść przed pierwszą operacją zapisującą na WORK.
5. Dopiero wtedy wykonywany jest `mkfs.ntfs`; następnie `device_guard.sh restore-marker` zapisuje `.usos-work` jako pierwszy zwykły plik i weryfikuje nonce oraz etykietę `USOS_WORK`.
6. `extract.sh` kopiuje instalator z raportowaniem postępu, porównuje liczbę plików i sumę bajtów ze źródłem, przenosi łańcuch startowy nośnika z `\EFI\BOOT` do `\EFI\USOS-WORK` (tylko ESP może mieć `\EFI\BOOT\BOOTX64.EFI`), kopiuje wskazany `unattend.xml`, wykonuje `sync` i dopiero potem publikuje `phase=prepared`.
7. Restart mikro-Linuxa zużywa `BootNext` i wraca jednorazowo do USOS.
8. USOS widząc `prepared` przechodzi do handoffu Windows Boot Managera z WORK NTFS.
9. Po udanym `StartImage` stan one-shot wraca do `pending`; po błędzie `StartImage` wraca do `prepared`, aby umożliwić retry bez ponownego rozpakowania.

`tools/prepare_work.sh` jest jedynym przewidzianym entrypointem destrukcyjnej części mikro-Linuxa i wymusza kolejność guard → format → marker → mount → extract/verify/sync → prepared.

Kontrakt możliwości backendu jest wspólnym źródłem prawdy dla UI i `requestPreparation()`. Aktywne kombinacje i ich backendy wylicza `src/flow/preparation_capability.zig` (`resolveBackend`/`resolveForFirmware`). W UEFI przez WORK: Windows 11 z obrazu ISO metodą `direct_iso` (`ISO`), Windows 8/8.1/10 metodą `chainload` (kopia nośnika na WORK, start `EFI\USOS-WORK\BOOTX64.EFI`), obrazy WIM/VHD metodami `wimboot`/`vhdboot`; Windows 7/Vista idą własną ścieżką natywną (`windows_native_iso.zig`), XP przez staging. W BIOS: Windows 10 i Vista natywnie z ISO (`src/platform/bios/windows_native_iso.zig`), Windows 7 przez mikro-Linux (`legacy_windows_request.sh`). Handoff z WORK akceptuje `sources/install.wim`, `install.esd` i `install.swm`. Kombinacje spoza kontraktu UI pokazuje z powodem i nie pozwala ich uruchomić. Niezależnie od kontroli UI `requestPreparation()` ponownie waliduje system, typ obrazu oraz metodę i jawnie odrzuca nieobsługiwane wartości.

## Windows 98 SE w BIOS: partycja z menu USOS

Wybierz Windows → Windows 98 SE → obraz ISO → Automatic (DOS Setup).
Najpierw wybierz naprawę RAM istniejącego systemu albo nową instalację.
Naprawa zachowuje partycje i pliki systemu, wymaga instalacji w `C:\WINDOWS`
na pojedynczej aktywnej partycji FAT32 i tworzy kopię zmienianych plików
w pierwszym wolnym katalogu `C:\USOS98\RAMBK0`–`RAMBK9`.

Przy nowej instalacji USOS odczytuje oryginalny DOS i pliki instalatora do RAM. Następnie w swoim
graficznym menu pokazuje dyski, wybór partycji 8, 4 lub 2 GiB oraz podsumowanie.
Domyślne ANULUJ i ESC wracają bez zapisu. Potwierdzenie usuwa dotychczasowy
układ wybranego dysku i tworzy jedną aktywną partycję FAT32; reszta pozostaje
nieprzydzielona. To szybkie formatowanie, nie bezpieczne wymazywanie danych.

Pendrive USOS jest wykluczony z wyboru. Oryginalny DOS widzi wyłącznie wybrany
dysk jako C: oraz źródło w RAM. Przeniesienie systemu i skopiowanie instalatora
do `C:\WIN98` odbywa się automatycznie. Nie trzeba wpisywać poleceń FDISK, FORMAT
ani SETUP. Patcher9x 0.9.91 stosuje poprawkę RAM Rudolpha Loewa do plików
instalacyjnych przed startem Setup. Parametr `/IS` pomija ScanDisk wraz
z jego dodatkowym ekranem ENTER. Nie ma restartu przygotowawczego ani mikro-Linuksa. Dalsze pytania
i restarty należą już do oryginalnego instalatora Windows 98.

Ta ścieżka obsługuje startowe ISO 98 SE z dyskietką DOS 1,44 MiB i katalogiem
WIN98, sektory dysku 512 B oraz BIOS z EDD/LBA. Rezerwuje 256 MiB źródła od
adresu 128 MiB, więc wymaga przynajmniej tego ciągłego obszaru RAM (typowo
512 MiB pamięci w komputerze). UEFI i inne wydania Windows 9x nie są objęte
tym wdrożeniem. Wyniki: [Windows 98 SE](docs/win98-native-2026-09-12.md).

## Legacy BIOS -> mikro-Linux

W UEFI mikro-Linux jest uruchamiany przez `systemd-bootx64.efi`. W Legacy BIOS tę rolę przejmuje własny loader Linux/x86 w Core: czyta ten sam `EFI/USOS/micro-linux/vmlinuz-virt` (nazwa ścieżki pozostawiona dla zgodności; zawartość to Alpine `6.18.35-0-lts`) i `initramfs-usos`, pobiera mapę RAM przez `INT 15h E820`, buduje `boot_params`, przekazuje tę samą linię poleceń z `usos.esp_partuuid=...` i skacze do 32-bitowego entry pointu bzImage. Initramfs, `/usos-init`, `device_guard` i skrypty przygotowania pozostają wspólne dla UEFI i BIOS. Stos storage jest modularny: builder dołącza dependency closure pełnej rodziny `drivers/ata`, a `/usos-init` ładuje sterownik kontrolera przez jego PCI modalias; dzięki temu np. CK804 dobiera `sata_nv` bez ładowania wszystkich starych sterowników przy każdym starcie.

Jeżeli menu działa w VESA/LFB, po zakończeniu wszystkich odczytów kernela i initramfs Core wykonuje `INT 10h AX=4F03` i wymaga, aby bieżący tryb nadal był identyczny z wybranym. Następnie `screen_info` w zero page opisuje ten sam framebuffer jako `VIDEO_TYPE_VLFB`; Linux `sysfb`/simpledrm przejmuje go bez zmiany trybu. Referencyjny SeaBIOS potwierdza `0x017A -> 0x017A` oraz ten sam fizyczny resource `0xFD000000` po stronie Linuksa.

Bieżący przypięty kernel mikro-Linuksa jest x86_64, więc ta ścieżka wymaga CPU z long mode. Athlon 64 oraz Pentium 4 z EM64T i nowsze są w zakresie; Pentium III i 32-bitowy Athlon XP nie uruchomią obecnego mikro-Linuksa. Wspierane minimum dla pełnego startu tego kernela/initramfs to 256 MiB RAM; 128 MiB wystarcza loaderowi, ale nie pełnemu rozpakowaniu initramfs. Późniejszy osobny kamień przewiduje 32-bitowy mikro-kernel dla tych maszyn bez zmiany initramfs.

## Architektura katalogu

Profile są danymi. GUI nie posiada osobnych `if` dla Windows 11, Ubuntu, Longhorna czy MemTesta. Profil określa kategorię, rodzinę, katalog obrazów, opcjonalny katalog unattended i listę metod bootowania. Loader jest osobną warstwą i implementuje konkretne techniki startu.

## Windows XP: instalacja od zera (2026-09-09)

Po wyborze dysku dostępne są dwa tryby. Domyślny `1` zachowuje partycje i wykorzystuje wolne miejsce, zgodnie z opisem poniżej. Opcja `2 — Formatuj caly dysk i przygotuj nowa instalacje XP` usuwa dotychczasowy układ MBR/GPT i tworzy nowy pod XP. Wystarcza wybór `POTWIERDZ` i ENTER; domyślnie zaznaczone jest `ANULUJ`. Nie ma wpisywania frazy ani drugiego potwierdzenia po skasowaniu układu. Przed wyborem i formatowaniem podgląd pokazuje partycje, odczytane zajęte/wolne miejsce, użycie urządzenia oraz system rozpoznany po plikach. Nieczytelne lub nieobsługiwane systemy plików mają stan nieznany. Wybrany obraz XP jest montowany i sprawdzany przed usuwaniem partycji. Jest to szybkie formatowanie pod instalację, nie bezpieczne wymazywanie całej zawartości dysku. Ta opcja wymaga dysku co najmniej 11 GiB, mniejszego niż 2 TiB, z sektorami 512 B i bez własnego pliku Unattended. Pendrive USOS, zamontowane partycje, aktywny swap i urządzenia używane przez inne urządzenia blokowe są wykluczone.

W Legacy BIOS wybierz obraz XP i brak własnego pliku Unattended. Mikro-Linux pokazuje angielskie menu dysków (model, serial, pojemność), obsługiwane strzałkami, ENTER i myszą. Te same kontrolki wybierają tryb przygotowania oraz Confirm / Cancel; wpisywanie numerów lub fraz nie jest wymagane. ESC i Cancel wracają bez zapisu. Domyślna instalacja tworzy jedną wspólną partycję dla plików rozruchowych, źródła i Windows. Potrzebne jest co najmniej 8 GiB ciągłego miejsca od rezerwacji wskazanej przez guard; zachowany jest limit położenia 128 GiB dla starszych wydań XP. Formatowanie całego dysku daje jedną partycję, a tryb zachowania pozostawia istniejące partycje nietknięte. Zweryfikowana wcześniejsza XPSETUP może zostać ponownie sformatowana i rozszerzona wyłącznie w przyległe wolne miejsce, co wymaga potwierdzenia.

Źródło `$WIN_NT$.~LS` i pliki startowe trafiają na tę samą partycję NTFS z klastrami 4 KiB. Wewnętrzny WINNT.SIF nie ustawia AutoPartition, zawiera `Repartition=No` i `FileSystem=LeaveAlone`. MIGRATE.INF przypisuje C: według podpisu MBR i przesunięcia partycji. Bootstrap NT52 używa EDD/LBA, aby zmiana geometrii BIOS po wyjęciu USB nie powodowała błędu odczytu. Po komunikacie gotowości wyjmij USOS, naciśnij ENTER i włącz komputer z dysku docelowego. Text Mode kopiuje pliki i automatycznie przechodzi do GUI Setup. Przy zakończeniu instalacji usuwa foldery tymczasowe źródła; pozostaje Windows na C: bez osobnej XPSETUP. Automatyczna ścieżka zapisuje `xp-install-record.ini`, bez nieaktualnego wezwania do kontynuacji z USB. Dane użytkownika i klucz wpisuje się w instalatorze. Własny plik SIF nadal korzysta z osobnej ścieżki i nie jest nadpisywany. Szczegóły oraz dowody testów: `docs/xp-ntldr-native-ntfs-2026-09-09.md`.

Własny plik Unattended zachowuje dotychczasowy tryb i jest kopiowany dokładnie. Nie jest nadpisywany wewnętrznym profilem automatycznego wyboru partycji. `AutoPartition=1` i `Repartition=Yes` nadal są odrzucane.

## Windows XP: awaryjne wznowienie po Text Mode

Jeżeli po Text Mode komputer nie uruchamia GUI (np. po ręcznym tworzeniu partycji w starszym przepływie), uruchom pendrive USOS i wybierz ENTER na ekranie CONTINUE XP. Wznowienie weryfikuje zapisany target i przywraca tylko jego kod MBR, który Setup może nadpisać. Po komunikacie gotowości wyjmij USOS, naciśnij ENTER i włącz komputer: GUI Setup startuje z samego dysku. ESC na ekranie wznowienia otwiera normalne menu, także gdy chcesz rozpocząć nową instalację zamiast wznawiać poprzednią. Szczegóły i ograniczenia: docs/legacy-xp-investigation-2026-09-09.md, sekcje 18–19.
# Linux Live w BIOS

Pierwszy backend Linux Live: **Linux → Other Linux → ISO SliTaz Cooking → Automatic**.
Core odczytuje jądro i cztery warstwy RAM bezpośrednio z ISO na NTFS DATA,
a następnie przekazuje sterowanie do jądra 32-bitowego. Szczegóły i granice
walidacji: [SliTaz Live BIOS](docs/linux-live-slitaz-bios-2026-09-13.md).
