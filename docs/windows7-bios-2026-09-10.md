# Windows 7 / Legacy BIOS — test 2026-09-10

## Wynik

**Najnowsze potwierdzenie użytkownika: Windows 7 zainstalował się na fizycznym
Athlonie/MS-7100 po aktualizacji Kingstona `B260910-193835-A2AE2C61`.** Dotyczy to
przygotowanego oryginalnego Windows 7 SP1 i natywnego startu BIOS. Szczegóły:
[naprawa blokady partycji](windows7-system-partition-2026-09-10.md).
Nie oznacza to jeszcze testu instalacji Windows 10 ani potwierdzenia fizycznej
ścieżki Linux/kexec. Poniższe wpisy opisują wcześniejsze próby i ograniczenia
poszczególnych wydań.

**Aktualizacja po próbie fizycznej:** użytkownik zgłosił czarny ekran i restart po 5/5 na MS-7100 / Athlon 64 X2 4200+ (historyczny log: family 0xf, model 0x23, stepping 2). Wersja na Kingstonie była poprawna (`45ce2100...`). Odtworzono niezależną awarię tego ISO przy wyłączonym CMPXCHG16B: uruchomienie bezpośrednio z DVD, całkowicie bez USOS/kexec, kończy się `VINF_EM_TRIPLE_FAULT`. Ten sam profil CPU z jedynie przywróconym bitem CX16 dochodzi do okna instalatora. Poprzedni test przy 2 GiB nie odwzorowywał ograniczeń instrukcji starego procesora. Zgodność fizycznego przekazania sterowania po dostarczeniu zgodnego WinPE nadal wymaga sprawdzenia; wynik VM nie stanowi potwierdzenia sprzętowego.

Aktualizacja 2026-09-10: usunięto dodatkowy restart firmware między przygotowaniem WORK a uruchomieniem Windows Setup. Nowa ścieżka przeszła pełną instalację od menu USOS do pulpitu oraz ponowny start bez nośnika USOS na **2048 MiB RAM**. Wydanie końcowe: `B260910-120203-BC8B0BBD`. Szczegóły znajdują się w sekcji „Bezpośredni start” poniżej; wcześniejszy wynik dotyczy poprzedniej wersji z restartem.

Pełna instalacja Windows 7 Professional STD x64 z obrazu użytkownika przeszła w VirtualBox: pusty dysk 64 GiB, kopiowanie, automatyczne restarty, konfiguracja użytkownika i pulpit. Po prawidłowym zamknięciu systemu odłączono wirtualny nośnik USOS; ponowny start z samego dysku Windows również zakończył się pulpitem.

Status backendu: **TESTED IN VM**. Instalacja Windows 7 na fizycznym komputerze pozostaje do sprawdzenia. Fizyczny Intel nie był formatowany ani używany jako dysk docelowy tego testu.

## Obraz i środowisko

- ISO: `WIN7X64.6in1.pl-PL.JULY2019.ISO`, 3356327936 bajtów.
- SHA-256: `54fd3e5429fa85426e00855f764a09b36e7819f44c611f27ec5d2afc9ef4c3e0`.
- Źródło jest UDF, zawiera `sources/install.esd`; jego zmodyfikowane środowisko instalacyjne to WinPE 10.0.17763.107 instalujące Windows 7.
- Wybrano pierwszą edycję Professional STD. Nie dodawano klucza ani mechanizmów aktywacji.
- VM: `USOS-Win7-BIOS`, BIOS/PIIX3, 2 CPU, 2048 MiB RAM, IDE, bez sieci.
- Dysk Windows: `zig-out/win7-bios/windows7.vdi`, IDE primary master.
- Nośnik USOS: `zig-out/win7-bios/usos-wim.vdi`, IDE primary slave, odłączony w teście końcowym.
- To potwierdzenie konkretnego ISO. Czysty instalator WinPE 3.x, x86, inne edycje i własny XML nie przeszły jeszcze osobnego pełnego testu.

## Obsługa

W menu BIOS: Windows → Windows 7 → obraz ISO → Automatic → opcjonalny XML → rozpoczęcie. ISO należy umieścić w `Systems/Windows/Windows 7/Images`, a własny XML w `Systems/Windows/Windows 7/Unattended` na DATA.

USOS przygotowuje pliki na własnej partycji WORK. Dysk docelowy i jego partycje użytkownik wybiera w normalnym instalatorze Windows. Po pierwszej fazie instalacji należy uruchamiać dysk docelowy; instalator sam kontynuuje pracę. Nie ma osobnego „Part 2” w USOS. Gdy firmware nadal wybiera USB jako pierwszy nośnik, trzeba wybrać dysk Windows w menu startowym komputera.

## Mechanizm

1. Oddzielny backend `windows_bios_iso` obsługuje Windows 7 ISO w BIOS; ścieżki XP i UEFI zachowują swój routing.
2. Mikro-Linux sprawdza tożsamość WORK i kompletność źródła, przygotowuje WORK i kopiuje pełną zawartość ISO, również `install.esd`.
3. Na ESP powstaje archiwum CPIO z bootmgr, BCD, boot.sdi, boot.wim oraz małym programem startowym CMD. Źródłowy wimboot 2.9.0 z przypiętym SHA-256 i jego licencja są w `tools/vendor/wimboot/2.9.0`. Osobny wariant do kexec jest generowany przez `tools/wimboot_kexec.py`; zmienia wyłącznie wejście real-mode i padding setup, pozostawiając kod protected-mode bez zmian.
4. Mikro-Linux ładuje archiwum przez kexec, zamyka systemy plików i bez restartu firmware przechodzi do wimboot. Mały shim odtwarza IVT, wektory PIC oraz PIT potrzebne usługom BIOS. Nowa ścieżka nie tworzy jednorazowego żądania ponownego uruchomienia; dawny kod Core zachowano wyłącznie dla zgodności ze starszym przygotowanym nośnikiem. Błąd bezpośredniego startu zatrzymuje operację z komunikatem, bez automatycznego restartu.
5. WinPE automatycznie znajduje WORK. Jeśli partycja nie ma litery, przypisuje wolną literę jedynemu woluminowi USOS_WORK, sprawdza nonce i pliki źródłowe, a dopiero potem uruchamia Setup. Nie formatuje dysków docelowych.

## Istotne poprawki i ograniczenia

- Natywny BOOTMGR uruchamiany z GPT WORK kończył się 0xc000000e. Zastąpiono to startem WinPE przez wimboot, bez przerabiania VBR WORK na NT60.
- Ładowanie kodu setup wimboot bezpośrednio pod 0x90000 naruszało aktywny stos Core. Kod jest teraz przygotowywany pod 0x200000 i kopiowany pod 0x90000 dopiero w końcowym przejściu assemblerowym. Wymagany jest prawdziwy 16-bitowy punkt wejścia wimboot.
- Ten WinPE nie zawiera findstr. Program startowy używa wbudowanego parsera CMD.
- Układ VM z nośnikiem USOS jako pierwszym dyskiem stałym powodował 0x80300024. Pełny test przeszedł z docelowym dyskiem jako pierwszym, a USOS drugim. Zachowanie fizycznego USB wymaga testu sprzętowego; nie wprowadzono obejścia modyfikującego cudze dyski.
- Boot WIM musi zmieścić się obok pozostałych plików na ESP; preflight sprawdza wolne miejsce. Test RAM wykonano przy 2 GiB, nie ustalono jeszcze minimum dla tej ścieżki.

## Dowody lokalne

- `zig-out/win7-bios/prepare-launcher.log`: kompletność źródła, device guard, PREPARED PASS.
- `zig-out/win7-bios/wimboot-menu.log`: ładowanie i zużycie znacznika.
- `zig-out/win7-bios/install-state.png`: rzeczywisty postęp kopiowania.
- `zig-out/win7-bios/first-reboot.png`: kontynuacja instalacji z dysku.
- `zig-out/win7-bios/desktop-installed.png`: pierwszy pulpit.
- `zig-out/win7-bios/cold-boot-config.txt`: konfiguracja bez nośnika USOS.
- `zig-out/win7-bios/cold-boot-desktop.png`: pulpit po samodzielnym starcie.
- `zig-out/win7-bios/kingston-iso-copy-result.txt`: kopia ISO na Kingstonie ze zgodnym SHA-256.

Testy obejmują kontrakt jednorazowego znacznika, rozdzielenie pamięci loadera i stosu, routing BIOS/UEFI oraz kodowanie żądania ISO/XML. Pełny build weryfikuje również testy Go, kod ISA Legacy i spójność payloadów. Zestaw automatyczny sprawdza start UEFI x86_64 i ARM64 oraz regresje XP.

## Wydanie i Kingston

Poniższy wpis opisuje wcześniejsze wydanie z restartem:

Wgrano `B260910-001449-6FEB5D75` na Kingston DataTraveler 3.0, PhysicalDrive8, 61991813632 bajtów. Aktualizator ponownie sprawdził GUID dysku i wszystkich partycji, odczytał zapisany Core oraz pliki ESP i zakończył `RESULT=PASS`. Log: `zig-out/win7-bios/kingston-update.log`.

- Core SHA-256: `c0298e3e6318963a59c4f6ef337f0681a7999b26e322401ab27ba7a8bcc97ed3`.
- BOOTX64.EFI SHA-256: `4dbb2b1a49b4a7fbae93ceda18e211bfe4326fb3a62001ef3891883493188294`.
- Initramfs SHA-256: `98187f394522c6e18d2c6ef77665c51910d1739af5dc3b938b011cd34a0cda2a`.

ISO jest już w katalogu Windows 7 na DATA. Pełny build i końcowy zestaw testów przeszły. Po testach VM została prawidłowo zamknięta, a gotowy dysk Windows zachowano. Usunięto wyłącznie pośrednie kopie VHD/RAW/QCOW2 i stare hostowe CPIO z tej próby, odzyskując około 19,48 GiB; raport `zig-out/win7-bios/intermediate-cleanup.json`.

## Bezpośredni start — 2026-09-10

- VM `USOS-Win7-Direct-Test`, BIOS/PIIX3, 2 CPU, **2048 MiB**, IDE, bez sieci i fizycznych dysków.
- Z normalnego menu wybrano Windows 7 → ISO → Automatic → bez własnego XML. Pełne przygotowanie WORK i CPIO zakończyło się `DIRECT HANDOFF PASS`, po czym pojawiło się okno wyboru języka Windows 7 bez restartu firmware.
- Dowody: `zig-out/win7-bios/kexec-test/full-serial.log`, `native-setup.png`, `install-progress.png`.
- Instalacja na nowym wirtualnym dysku 64 GiB przeszła kopiowanie, restarty wykonywane przez Windows, konfigurację konta `USOS-Test` i pulpit. Po prawidłowym zamknięciu odłączono wirtualny USOS; sam dysk Windows ponownie uruchomił pulpit. VM została następnie prawidłowo zamknięta. Dowody: `first-windows-reboot.png`, `desktop-installed.png`, `cold-boot-config.txt`, `cold-boot-desktop.png` w tym samym katalogu testu.
- Usunięto błędny ekran „Enter to power off” przed Setup. Pozostaje ekran postępu z informacją, by nie odłączać USB.
- kexec jest włączane parametrem jądra wyłącznie dla żądania Windows 7 BIOS. XP i UEFI nie otrzymują tego parametru. Dostępność kexec jest sprawdzana przed przygotowaniem WORK.
- Samo `kexec --real-mode` dochodziło do wimboot, lecz BOOTMGR nie startował bez przywrócenia przerwań BIOS. Wariant ze shimem uruchomił WinPE i natywny Setup w VirtualBox.
- Próba QEMU TCG miała dodatkowy problem przy odczytach z segmentu CS w przejściu kexec 64→32; diagnostyka GDB wykazała odczyt z błędnej bazy. Nie wprowadzano obejścia emulatora do produkcyjnego kexec. Test bezpośredniego przejścia wykonano w VirtualBox.
- Pełny build, testy Go, audit ISA Core, testy UEFI x86_64/ARM64 i dotychczasowe regresje XP przeszły. Trzy dodatkowe testy `test_wimboot_kexec.py` sprawdzają odrzucenie zmienionego vendora, zachowanie payloadu i kontrakt wejścia shimu.
- Core SHA-256: `d6450640b750c304ae0dc98837b6cf20316358f23443a9542e7d78dec87e4d02`.
- BOOTX64.EFI wydania końcowego SHA-256: `c793870936defb3a3e2a3f42c3dc3835bfc8f9eee8d4bb6d335a7aee70e31c1f`.
- Initramfs wydania końcowego SHA-256: `45ce210099974d1e87e49dca4d36d464d69e3406218161dfb7acc5d47cd5cb50`.
- Pełny test VM używał `B260910-113548-EB275D61`. W paczce końcowej zmieniono jedynie wspólny tytuł postępu na `STARTING INSTALLER`, dodano test do standardowego runnera oraz dokumentację. Porównanie wszystkich plików initramfs wykazało wyłącznie tę zmianę tekstu w `usos-init`; Core i kod przekazania sterowania pozostały identyczne. Raport: `final-payload-verification.json`.
- Kingston DataTraveler 3.0 został zaktualizowany do `B260910-120203-BC8B0BBD` i odczytany kontrolnie: `RESULT=PASS`. Podczas tej aktualizacji miał numer **PhysicalDrive9**; wyboru dokonano po modelu, rozmiarze, USB i GUID dysku oraz zweryfikowano GUID-y partycji. Log: `zig-out/win7-bios/kexec-test/kingston-update.log`. Stary znacznik `windows-bios-ready.ini` usunięto po sprawdzeniu treści, z kopią w `kingston-old-ready.ini`. Nie formatowano Intela ani żadnego fizycznego dysku docelowego.

## Niezgodny WinPE / CMPXCHG16B — 2026-09-10

- `J:\_ISO\WINDOWS\WIN7\WIN7X64.6in1.pl-PL.JULY2019.ISO`: boot.wim image 2, arch 9 (x64), WinPE 10.0.17763.107. Windows instalowany z ESD to Windows 7; wymagania startowego WinPE są odrębne.
- `J:\_ISO\WINDOWS\WIN7\Windows7.iso`: boot.wim image 2, arch 9, WinPE 10.0.14393. install.wim zawiera 6 obrazów Windows 7 Professional/Ultimate 6.1.7601. Ten drugi obraz również nie dostarcza starego środowiska startowego.
- Próba izolowana `USOS-Win7-Athlon-Probe`, UUID `adbf0f72-93f8-45a8-ac9b-7ed41f9af2ea`: 2048 MiB, 2 CPU, BIOS, wyłącznie ISO jako DVD, bez dysków. Profil AMD Athlon 64 X2, CPUID leaf 1 `EAX=00020f32 EBX=00020800 ECX=80000001 EDX=178bfbff`: krytyczny błąd procesora przy starcie WinPE. Kontrola z **jedyną** zmianą `ECX=80002001` (CX16): okno wyboru języka. Nie twierdzimy, że profil VM odtwarza cały chipset MS-7100.
- Dowody: `zig-out/win7-bios/physical-reset/without-cx16.log`, `with-cx16.log`, `with-cx16.png`, `athlon-s939-dvd.png`. Starszy log fizycznego CPU skopiowano tylko do odczytu z Kingstona: `physical-reset/lts-storage-probe.txt`.
- `windows_bios_cpu_check.sh` odczytuje XML wybranego boot image z nagłówka WIM. Dla x64 WinPE 6.3+ sprawdza `cx16` w `/proc/cpuinfo`. Komunikat po angielsku pojawia się **przed** przygotowaniem WORK, nie dopiero po 5/5. Brak czytelnych metadanych jest logowany jako UNKNOWN, a nie jako potwierdzona zgodność. To test tej konkretnej cechy, nie pełna walidacja wszystkich wymagań każdego Windows.
- Dane CPU i wynik preflight są zapisywane na własnej ESP w `EFI/USOS/windows-bios-preflight.log`; pozytywna ścieżka dopisuje punkt po załadowaniu WinPE do RAM. Nie dodano firmware reboot ani automatycznego fallbacku.
- Sześć testów hostowych obejmuje nowy/stary WinPE, x86, boot index, niepełne metadane i dokładne dopasowanie flagi. Próba na docelowym BusyBox w VM bez CX16 odrzuciła rzeczywiste metadane boot.wim; kontrola z flagą CX16 przeszła (`guard-serial.log`). Pełny build i unit suite przeszły. Wydanie: `B260910-125642-7DBC83DC`.
- W tym etapie nie uzyskano zgodnego źródła startowego WinPE. Zachowanie aktualizacji Windows 7 jest możliwym celem przy przygotowaniu zgodnego nośnika, ale nowa hybryda instalatora nie została zbudowana ani przetestowana. Nie należy utożsamiać odrzucenia niezgodnego ISO z naprawioną instalacją fizyczną.
- Wydanie `B260910-125642-7DBC83DC` wgrano na zweryfikowany Kingston USB (w tej sesji PhysicalDrive9). Aktualizator przebudowano z nowym payloadem. Odczyt kontrolny: `RESULT=PASS`, initramfs SHA-256 `b55a6607b79885b10cc57387341494734d366ca63cbff7d586026db3b1a20cf7`, Core pozostał identyczny. Log aktualizacji: `zig-out/win7-bios/kexec-test/kingston-update.log`. Test CPU zakończył pracę VM przez poweroff; fizycznych dysków docelowych nie użyto.

Źródła techniczne: [wymagania Windows 10 x64](https://download.microsoft.com/download/c/1/5/c150e1ca-4a55-4a7e-94c5-bfc8c2e785c5/Windows%2010%20Minimum%20Hardware%20Requirements.pdf), [układ nagłówka WIM](https://github.com/ebiggers/wimlib/blob/master/include/wimlib/header.h).

### Doprecyzowanie testów Windows 10

Użytkownik wyjaśnił, że **nie instalował jeszcze Windows 10 na tym Athlonie**; oczekiwał zgodności ze względu na obsługę x64 i dwa rdzenie. Nie ma zatem potwierdzonej udanej instalacji Windows 10 x64 na tym fizycznym sprzęcie, którą można przyjąć jako kontrolę. Odczytano bez modyfikowania źródeł oba ISO z `J:\_ISO\WINDOWS\WIN10`: `Win10_Pro_x64.iso` i `tiny10 23h1 x64.iso` mają startowy WinPE x64 10.0.19041. Nazwa Tiny10 ani liczba rdzeni nie znosi wymagania instrukcji CPU. Metadane: `zig-out/win7-bios/physical-reset/win10-metadata.txt`.

Oba obrazy uruchomiono bezpośrednio jako DVD, bez USOS i dysków docelowych, w tej samej VM z CX16=0. Oba zakończyły się `VINF_EM_TRIPLE_FAULT` przed wejściem do instalatora; logi `win10-original.log` i `win10-tiny.log` w katalogu `physical-reset`. Testy dotyczyły startu środowiska, nie pełnej instalacji. VM po testach została wyłączona. Kod produkcyjny i Kingston nie były ponownie modyfikowane w tej próbie.

## Oryginalny Windows 7 SP1: BCD i restart WinPE — 2026-09-10

Użytkownik dostarczył zdjęcie `\\Boot\\BCD`, status `0xc000000e`, już ze zwykłego Windows 7. Odczyt z Kingstona potwierdził WinPE 6.1 x64 i pozytywny preflight CPU. Nie należy przypisywać tego błędu brakowi CX16. Oryginalne ISO `pl_windows_7_professional_with_sp1_x64_dvd_u_676944.iso` ma MD5 `e3c6ade7cf048d79873af40008074ad4`. Przechwycony fizyczny `boot.cpio` ma SHA-256 `f87ea9aba5cdc869e035ce3b9da655cf485c4e842a4e2a9406aa70ea8b33c09b`; BCD daje się odczytać i ma prawidłowe standardowe ścieżki ramdisk.

1. W testowym shimie wymuszono błąd fizycznego INT13, przy dwóch dyskach zgłoszonych w BDA. Wtedy wimboot udostępnia RAM jako 0x82, a bootmgr odtwarza dokładnie błąd BCD ze zdjęcia. Wyzerowanie BDA 0x475 pozwalało wejść do WinPE, ale powodowało ostrzeżenie Setup o braku możliwości rozruchu dysku. **To obejście odrzucono i nie wgrano na Kingston.** Kolejna kontrola wykazała, że wystarczy poprawna odpowiedź AH=08 z liczbą dysków: bez zmiany numeracji znika błąd BCD. Końcowy shim sam odpowiada na AH=08 dla istniejących dysków twardych liczbą dysków z BDA i zgodnościową geometrią CHS. Zapytania AH=08 o dyskietki lub numery poza zakresem zgłaszają niedostępność podczas tego startu z RAM. Pozostałe funkcje BIOS, w tym rzeczywiste I/O i parametry EDD AH=48, są przekazywane do oryginalnego handlera. BDA oraz odczyty/zapisy fizycznych sektorów pozostają niezmienione. Cały 512-bajtowy blok handlera, danych i wyrównania kopiuje się do zarezerwowanego prefiksu wimboot 0x204a0 (wektor BIOS 0x204f0), poniżej bss16 0x20a00. Kopiowanie samych instrukcji nie przeszło zwykłego testu BIOS; rozszerzenie inicjalizacji do pełnego bloku przeszło kontrolę bez wstrzykiwania awarii. Nie przypisano tego różnicowego wyniku pojedynczemu, niezmierzonemu wywołaniu firmware. Zwracany jest wyłącznie CF; zewnętrzna flaga IF zostaje zachowana. Błędy BIOS wstrzykiwano wyłącznie do obrazu testowego. Odtworzono mechanizm w VM; nie mierzono wywołań INT13 na fizycznej płycie użytkownika.
2. Po przejściu BCD oryginalny WinPE 3.1 uruchamiał tło, a następnie resetował VM. Kontrola z `cmd.exe, /k echo ...` otwierała samą konsolę bez wykonania reszty polecenia. Ujęcie całych argumentów w cudzysłowy uruchomiło skrypt. `prepare_windows_bios_boot.sh` generuje teraz `cmd.exe, "/c ...\\usos-start.cmd"` z pełnymi ścieżkami. Próba z brakującym źródłem zatrzymuje się na diagnostyce, bez resetu; próba ze źródłem i poprawnym nonce otwiera natywny Setup.

Dowody znajdują się w `zig-out/win7-bios/stock-bcd`: `broken-bios-kexec.png` (odtworzony BCD), `trace-6.png` (tło WinPE przed starym resetem), `console.png` (kontrola parsera), `count-after.png` (odczyt BCD mimo awarii fizycznego INT13), `geometry-fixed-after.png` (Setup przy awarii zapytań AH=08), `geometry-disks.png` (prawidłowy cel, bez ostrzeżenia), `geometry-copy.png` (kopiowanie zakończone, rozpakowywanie 16%). Usunięcie obsługi błędu AH=08 w kontroli powodowało również utknięcie firmware podczas startu; nie każdy wariant awarii miał identyczny ekran końcowy. Test używał 2048 MiB RAM, BIOS/IDE, wyłącznie plików VHD/VDI. Wyłączono parawirtualizację Hyper-V, gdyż sam oryginalny DVD na hoście z tym ustawieniem powodował osobny błąd 0x50. Profil CPU w tej próbie był hostowy; nie jest to pełna emulacja Athlona/chipsetu MS-7100. Oryginalny DVD przy parawirtualizacji `none` uruchomił Setup (`dvd-later.png`).

Wydanie `B260910-141128-7DBC83DC` zawierało odrzucony wariant pierwszego dysku i nie zostało wdrożone. Wariant pośredni `B260910-145306-7DBC83DC` również nie został wdrożony. Końcowy build to `B260910-151642-7DBC83DC`. Unit suite przeszło, w tym pięć testów shimu obejmujących zachowanie payloadu, region runtime i flagę IF. Niezależne złożenie referencyjnego kodu asemblerem Zig/LLVM dało identyczne bajty handlera i jego instalatora (`zig-out/win7-int13-verify.py`). Nadal wymagany jest ponowny start na fizycznym komputerze użytkownika.


### Końcowa kontrola i stan wdrożenia

### Aktualny stan: Enter nie zwalnia pauzy diagnostycznej

Użytkownik potwierdził, że przy czytelnym `Press any key to continue booting...` Enter niczego nie zmienia. Nie ma potwierdzenia wykonania bootmgr w tej próbie. Możliwa jest niedostępność obsługi klawiatury firmware po kexec; nie ustalono jej dokładnej przyczyny. Usunięto `pause` z diagnostyki w `windows_bios_handoff.sh`: znacznik debug wybiera teraz tylko `linear`, normalny tryb pozostaje `quiet linear`. Widoczne komunikaty nie wymagają już klawisza.

Wydanie `B260910-162845-7DBC83DC`: pełny build i Go tests przeszły, spakowany skrypt odpowiada źródłu; shim VGA/INT13 pozostał identyczny. Initramfs SHA-256 `c168ffe143f37b375a5c79f24fe7bb2a26d186d33166f0425fb68439f52578b9`. VM z 2 GB i framebufferem doszła do wyboru języka oryginalnego Windows 7 bez wysyłania klawiszy po handoff (`stock-bcd/automatic-after.png`). VM wyłączono, źródło VHD odłączono. Kingston zaktualizowany i odczytany kontrolnie: `cursor-report/automatic-update-result.txt`, `RESULT=PASS`. Znacznik diagnostyczny pozostaje aktywny, ale pauza została usunięta. Wynik kolejnej próby na MS-7100 pozostaje nieznany.

### Następna próba: nieczytelna diagnostyka na grafice USOS

Zdjęcie użytkownika po wydaniu diagnostycznym pokazuje pasy tekstu na starym tle USOS. Log fizyczny potwierdza `B260910-154426-7DBC83DC` i `linear pause`; treści tekstu ze zdjęcia nie można wiarygodnie odczytać. W shimie brakowało przywrócenia tekstowego trybu VGA po framebufferze USOS. Dodano INT 10h/AX=0003 po przywróceniu PIC/PIT, z zachowaniem rejestrów ogólnych oraz DS/ES/FS/GS i wyczyszczeniem IF/DF przed powrotem do oryginalnego prefixu. Nie jest to jeszcze potwierdzenie naprawy całej instalacji na fizycznej płycie.

Test VM z 2048 MiB i `vga=791`: log `stock-bcd/handoff-serial.log` potwierdza rzeczywisty `simpledrmdrmfb` 1024x768, `vesa-confirmed-before.png` pokazuje czytelny postój przed bootmgr, `vesa-confirmed-after.png` okno wyboru języka Windows 7 po Enter. Test wykonano na plikach VDI/VHD, bez fizycznych dysków. VM wyłączono i odłączono źródłowy VHD. Sześć testów shimu oraz test wykonania kodu resetu VGA w Unicorn przeszły; ten ostatni sprawdził odtworzenie rejestrów i stosu nawet po ich zniszczeniu przez symulowany firmware. Pełny build i Go tests przeszły.

Wgrano `B260910-160630-7DBC83DC` na ten sam zweryfikowany Kingston, z `RESULT=PASS` w `cursor-report/video-update-result.txt`. Initramfs SHA-256: `cde1490610afb71ab054e897bbe8b2d378c9a6c3a533dc2f0fb3a64f1160ea0c`; shim SHA-256: `f0c38d5b145b70d2156a37f62e3d97abdb5d75a3ab8703a718d43f777df0692a`. Znacznik diagnostyczny pozostaje aktywny do próby fizycznej. Następny użytkownik powinien zobaczyć czytelny tekst, nacisnąć Enter i podać dalszy wynik; nie należy przedstawiać samego sukcesu VM jako ukończonej naprawy MS-7100.

### Historia poprzedniego wydania

**Wynik późniejszej próby fizycznej: niepowodzenie.** Użytkownik zgłosił czarny ekran z migającym kursorem po 5/5. Odczyt Kingstona potwierdził build B260910-151642-7DBC83DC, oryginalne ISO Professional SP1, WinPE 6.1 i załadowanie archiwum do RAM. Nie ma dowodu, do którego miejsca doszedł kod po kexec. Poprzedni test VM nie potwierdza działania na MS-7100. Zachowano log w `zig-out/win7-bios/cursor-report/windows-bios-preflight.log`.

Dodano opcjonalny plik ESP `EFI/USOS/windows-bios-debug.ini`: jego obecność wybiera argumenty wimboot `linear pause`, wyświetla diagnostykę i zatrzymuje program przed wejściem do bootmgr. Bez pliku zachowane są `quiet linear`. To narzędzie do ustalenia miejsca awarii, nie kolejna potwierdzona naprawa. Po zakończeniu diagnostyki należy usunąć znacznik. Kod shimu i sposób przygotowania instalatora pozostają bez zmian.

Wydanie diagnostyczne `B260910-154426-7DBC83DC` zbudowano i wgrano na Kingston: `cursor-report/update-result.txt` potwierdza `RESULT=PASS`. Pełny build i testy Go przeszły. Porównanie zawartości initramfs potwierdziło dokładną zgodność handoff z plikiem źródłowym oraz niezmieniony shim. Nowy initramfs SHA-256: `e622183dcff8d9139394d642f09c8af7b59f03d25c3c0c813d38b5f7e85e9179`. Nie wykonano kolejnej próby fizycznej; oczekiwany jest ekran diagnostyczny od użytkownika.

- Zwykły start, bez wstrzykiwania błędów: `wide-normal-after.png` pokazuje okno oryginalnego Setup, `wide-disks.png` prawidłowy cel 32 GiB bez ostrzeżenia, a `wide-copy.png` zakończone kopiowanie i rozpakowywanie 16%. Test obejmuje przejście do instalacji, **nie potwierdza ukończonego pulpitu ani wyniku na fizycznym MS-7100**. Przy późniejszym restarcie VM startowała ponownie z testowego DVD zgodnie z konfiguracją. VM wyłączono, źródłowy VHD odłączono; target zachowano jako `stock-final.vdi`.
- Porównanie bajtowe `release-verification.json`: testowany shim i winpeshl.ini są identyczne z końcową paczką. Nie ma w niej testowego BIOS ani kodu wstrzykiwania awarii. Test w Unicorn wykonał osiem ścieżek real mode oraz instalację handlera, sprawdzając BX/DS/ES, IF/CF, zakres numerów dysków, przekazanie I/O do BIOS i inicjalizację wcześniej zabrudzonego bloku pamięci. Kod referencyjny złożono niezależnie przez Zig/LLVM; wynik jest identyczny. Pełny build, Go tests, kontrola ISA i unit suite przeszły.
- Initramfs SHA-256: `6dd5db3664252b588fdb0188c66e530c8bb9fbaf1e44578cce576dba4268818e`; shim: `28b99fc7e9ccdf46e669877d30051e69492a6c4ae3a40b47021877e2e84d0d43`.
- BOOTX64.EFI SHA-256: `786380e2760e4af42e542b25c93ab98d221e0f663cc75bd3ded225cee4cca54b`; Core pozostaje `d6450640b750c304ae0dc98837b6cf20316358f23443a9542e7d78dec87e4d02`.
- Installer SHA-256: `82c76a40be74e197a78ffd5be71f2c866c6e6c202033a3d6147cd7fc31da4b4b`. Aktualizator fizyczny przebudowano z tym payloadem.
- **Kingston zaktualizowany po wyraźnym potwierdzeniu użytkownika.** Pierwsza próba została odrzucona przez automatyczną kontrolę uprawnień; po wiadomości „potwierdzam zrób te rzeczy” aktualizacja przeszła. Wgrano `B260910-151642-7DBC83DC` na Kingston DataTraveler 3.0 USB 61991813632 B, GUID `31c644bf-74dd-4807-9cb2-46745adeadd4`, z kontrolą GUID-ów ESP/DATA/WORK. Log `zig-out/win7-bios/kexec-test/kingston-update.log` kończy się 2026-09-10 17:23:21 wynikiem `PASS 5/5 - Weryfikacja aktualizacji`; odczytane sumy plików odpowiadają nowemu payloadowi. Obrazy systemów i dane użytkownika zachowano. Na fizycznym Intelu niczego nie zapisywano. Nadal potrzebna jest próba startu na MS-7100.
