# USOS: roadmapa (2026-09-24)

Cel projektu: jeden pendrive do instalowania i uruchamiania systemów od
MS-DOS do Windows 11 i Linuksa, w BIOS i UEFI (także z Secure Boot),
lepszy od Ventoy, Easy2Boot i WinToUSB: jedno menu, jawny i chroniony
wybór dysku, instalacje bez powrotu na USB, sterowniki i poprawki dla
nowego sprzętu. Porównanie z E2B: [research/e2b-comparison.md](research/e2b-comparison.md).

Ten plik zastępuje kolejność z `ROADMAP.md` w katalogu głównym
(13 września 2026). Tamten plik zostaje jako historia; jego otwarte
punkty są tu uwzględnione (sekcja 4).

**Statusy:** **Done** = zrobione i sprawdzone (zakres dowodu podany
w dokumentach), **Next** = następne w kolejności, **Later** = zaplanowane
później. **Nakład** to szacunek pracy w dniach roboczych (agent +
testy użytkownika na sprzęcie), bez czasu oczekiwania na sprzęt. To rząd
wielkości, nie termin.

## 1. Kolejność w skrócie

```
N1 kopia GitHub + LFS
 └─> N2 refaktor: wspólny pipeline (M0..M3)
      ├─> N3 sterowniki użytkownika XP/Vista ──┐
      ├─> N4 pliki-towarzysze + generator (10/11) ├─> L1 rodzina NT5 na UEFI ─> L2 XP bez CSM (CSMWrap)
      │                                          │        └─> L7 Longhorn pre-reset, L8 NT4
      └─> N5 szybkie pomysły z E2B               └─> L6 Win98 na X470 (po ręcznym spike'u)
N6 Secure Boot: kernel lockdown + UKI  (niezależne, po N1)
L3 32-bit CPU / mniej RAM (najpierw pomiary) ─> L4 chainload dla PC bez USB boot
```

| # | Pozycja | Status | Zależy od | Nakład |
|---|---|---|---|---|
| N1 | Kopia na GitHubie, Git LFS, porządek w repo | **Next** (pierwsze) | – | 1–2 dni |
| N2 | Refaktor: wspólny pipeline OS | **Next** | N1 | 12–20 dni w krokach M0–M7 |
| N3 | Sterowniki użytkownika XP i Vista | **Next** | N2 (M3/M4) | 4–6 dni |
| N4 | Pliki-towarzysze + generator plików odpowiedzi | **Next** | N2 (M1) | 3 dni (towarzysze) + 8–12 dni (generator, etapami) |
| N5 | Pomysły z E2B (szybkie) | **Next** / **Later** per punkt | N2 (M1) dla części | 1–10 dni per punkt |
| N6 | Secure Boot: zablokowany kernel, podpisany UKI | **Next** (niski priorytet w grupie) | N1 | 4–6 dni |
| L1 | Rodzina NT5 na UEFI (2000, 2003, XP x64) | **Later** | N2 (M4), N3 | 10–15 dni + sprzęt |
| L2 | XP na UEFI bez CSM (CSMWrap) | **Later** | L1 (profil firmware) | 8–15 dni, wynik niepewny |
| L3 | 32-bit CPU i mniejsze minimum RAM | **Later** | pomiary | 2 dni pomiarów, potem 5–15 dni |
| L4 | Chainload w stylu Plop dla PC bez USB boot | **Later** | L3 (częściowo) | 5–10 dni |
| L5 | Motywy, układy klawiatury, persistence, post-install, test QEMU | **Later** | N2 (M1) | 1–5 dni per punkt |
| L6 | Windows 98 na X470 (eksperymentalne) | **Later** | ręczny spike, N4 (msbatch) | spike 2–3 dni, automatyzacja 8–12 dni |
| L7 | Buildy Longhorn | **Later** | L1 (pre-reset), ścieżka Vista (post-reset) | 3–5 dni per build |
| L8 | NT4 dla retro sprzętu | **Later** | profil NT5 (M4) | 5–8 dni |
| L9 | shim-review (własny shim podpisany przez Microsoft) | **Later** (długoterminowo) | N6, publiczne repo | miesiące, proces zewnętrzny |

## 2. Pozycje

### N1. Kopia na GitHubie z Git LFS: **Next**, pierwsze

Dlaczego pierwsze: repo **nie ma żadnego remote**, więc 107 commitów
istnieje tylko na dysku dev PC. Każda inna praca jest zagrożona
jedną awarią dysku.

Stan repo (odczyt 2026-09-24): brak `.gitattributes`, brak gałęzi `main`
(jest tylko `master`), pack 445 MiB + ok. 6 GiB luźnych obiektów + 885 MiB
śmieci `tmp_obj_*`. Śledzone duże pliki: `tools/qemu/` 1,2 GB (58
emulatorów wszystkich architektur), `tools/zig/` 388 MB (w tym `zig.exe`
169 MB i ok. 830 plików cache, które `.gitignore` już pomija, ale
zostały zacommitowane wcześniej), `installer/internal/payload/assets/payload.zip`
142 MB (24 wersje w historii, ok. 3 GB), `installer/build/USOS Installer.exe`
79 MB. ISO w katalogu głównym są poprawnie ignorowane.

Kroki:

1. Repo **prywatne** (klucz podpisu i tak jest poza repo; sprawdzić
   przed pierwszym pushem: `git grep` na `BEGIN .*PRIVATE KEY`, `*.key`,
   `*.pfx`; `.gitignore` już je pokrywa).
2. Przestać śledzić artefakty buildu zamiast wrzucać je do LFS:
   `installer/build/*.exe`, `tools/zig/data/global-cache/**`,
   `.claude/` (dodać do `.gitignore`). `payload.zip` jest wymagany przez
   `go:embed`: albo LFS, albo mały plik zastępczy + build tag
   (decyzja: **LFS**, żeby EXE budował się z czystego klonu).
3. LFS dla: `payload.zip`, `tools/zig/zig.exe`, `*.efi`/`*.bin`
   w `tools/vendor/**` i `assets/**`, obrazów `*.fd`. `tools/qemu/`
   zmniejszyć do x86_64 + i386 + aarch64 i potrzebnych `edk2-*.fd`,
   resztę usunąć z drzewa (albo skrypt pobierający z przypiętym hashem).
4. Historia: bez remote można bezpiecznie przepisać ją **przed**
   pierwszym pushem (`git lfs migrate import --include=...`
   albo `git filter-repo`), po pełnej kopii `.git` na zewnętrzny dysk.
   Potem `git gc --prune=now`.
5. Utworzyć `main` z `master` (harness zakłada `main` jako bazę PR).
6. Uwaga na limity GitHub LFS (darmowy plan ma mały limit transferu
   i miejsca; 142 MB × kolejne buildy szybko go przekroczy). Dlatego
   `payload.zip` warto uczynić deterministycznym (dziś nagłówki ZIP
   mają czasy plików, `usos-payload-pack/main.go`), a na GitHub wysyłać
   tylko wydania, nie każdy build.

### N2. Refaktor: wspólny pipeline OS: **Next**

Projekt: [design/refactor-os-pipeline.md](design/refactor-os-pipeline.md).
Profile OS jako dane, etapy (detect → validate media → prepare target →
drivers → fixups → answer file → komunikaty → verify → hand-off),
opakowanie sprawdzonych elementów bez zmiany bajtów. Kroki M0–M7,
każdy z zielonymi testami i niezmienionymi ścieżkami potwierdzonymi na
sprzęcie. Nakład łącznie 12–20 dni, rozłożony na małe commity.
Najważniejsze skutki: koniec podmian tekstu w `build_xp_uefi_csm_trial.py`,
pakiet XP budowany z repo (nie ze sticka) i dostarczany przez instalator,
jedna tabela decyzji zamiast porównań `system.id` w
`preparation_capability.zig` i `manual_summary.zig`.

### N3. Sterowniki użytkownika XP i Vista: **Next**

Foldery `Drivers\Windows XP` i `Drivers\Windows Vista` są tworzone, ale
nieużywane. Projekt XP (text mode przez `TXTSETUP.SIF`/`DOSNET.INF`/
`HIVESYS.INF`, PnP przez `OemPnPDriversPath`) jest w
[drivers.md](drivers.md). Vista: to samo archiwum co Windows 7 i wpis
`DriverPaths` w generowanej odpowiedzi serwisowej
(`tools/windows_vista_install.c`).
Warunek: przy pustym folderze pakiet XP i odpowiedź Visty są **bajt
w bajt** takie jak dziś (`compare_xp_packages.py`: 0 zmian). Zależy od
etapu `drivers` z N2 (M3), bo inaczej byłaby to kolejna podmiana tekstu.

### N4. Pliki-towarzysze i generator plików odpowiedzi: **Next**

Projekt: [design/answer-file-generator.md](design/answer-file-generator.md).

1. **Towarzysze** (3 dni, najpierw): `<obraz>.xml` (unattend),
   `.key` (klucz produktu), `.txt` (opis w menu), `.sif` (XP/2000),
   `.inf` (msbatch 9x). Rozpoznawane przy skanie `Images`, pokazywane
   jako wybór pliku odpowiedzi lub opis wpisu.
2. **Generator** etapami: 10/11 przez WORK → scalanie XML → 7 → NT5
   (scalony SIF odblokowuje własny SIF w XP UEFI-CSM) → tryb „dysk
   wybrany w USOS” (pomocnik WinPE) → 98 `msbatch.inf` → Vista.
   Zaliczenie: wygenerowany plik przechodzi prawdziwą instalację
   w QEMU bez poprawek.

### N5. Pomysły z E2B

| Pomysł | Status | Nakład | Uwagi |
|---|---|---|---|
| „Uruchom z pierwszego dysku” (bez wyjmowania pendrive'a) | **Next** | 1–2 dni | UEFI: `BootNext` na wpis dysku albo `LoadImage` `\EFI\Microsoft\Boot\bootmgfw.efi`/`\EFI\BOOT\BOOTX64.EFI` z ESP wybranego dysku; BIOS: odczyt MBR 0x80 do 0x7C00 z INT13 mapującym dysk USB poza kolejkę (wzorzec XP chainload) |
| Ogólny wpis dla nieznanych ISO/IMG/EFI (Linux live, WinPE, narzędzia), oznaczony „niezweryfikowane” | **Next** | 8–10 dni | UEFI: obraz El Torito EFI + ISO w RAM przez `EFI_RAM_DISK_PROTOCOL` (jeśli firmware go ma) albo ISO z DATA dla Linuksów z `iso-scan`/`findiso`; BIOS: memdisk dla małych obrazów. Osobny wiersz w `Utilities`, bez przygotowania dysku, bez obietnicy działania |
| Persistence dla Linux live | **Later** | 3–5 dni | plik `<obraz>.persist.img` obok ISO, parametr jądra per dystrybucja (casper `persistent`, Debian `persistence`); zależy od ogólnego wpisu Linux |
| `theme.ini` (tło, akcent, logo) | **Later** | 2–3 dni | na DATA, kopiowany na ESP przez Aktualizuj USOS (wzorem `icon.png`); walidacja kontrastu, fallback na wbudowany motyw |
| Układy klawiatury dla pól tekstowych | **Later** (razem z generatorem) | 2–4 dni | tabele QWERTY-PL, QWERTZ, AZERTY; potrzebne dla generatora i parametrów DOS |
| Folder `PostInstall` | **Later** | 3–5 dni | `DATA\PostInstall\<OS>\` kopiowany na cel, wywoływany z `FirstLogonCommands`/`GuiRunOnce`; wymaga generatora (scalanie tych kluczy) |
| Test menu w QEMU jednym kliknięciem z instalatora | **Later** | 2–3 dni | QEMU z `-snapshot` na fizycznym pendrivie tylko do odczytu (wymaga admina), OVMF i SeaBIOS; zależy od odchudzonego `tools/qemu` (N1) |

### N6. Secure Boot: utwardzenie: **Next** (po N1, niski priorytet)

Dziś (docs/secure-boot-usos.md): łańcuch kończy się na jądrze; Alpine LTS
ma `LOCK_DOWN_KERNEL_FORCE_NONE`, initramfs i linia poleceń nie są
weryfikowane. Osoba z fizycznym dostępem może użyć jądra podpisanego
kluczem USOS do uruchomienia dowolnego kodu na każdej maszynie, która
zarejestrowała klucz.

1. Własny build jądra (ta sama wersja LTS) z `lockdown=integrity`
   wymuszonym (`CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY`) i
   `MODULE_SIG_FORCE`.
2. Podpisany **UKI** (jądro + initramfs + cmdline) zamiast osobnych
   plików; systemd-boot bez edycji cmdline; parametry zmienne
   (`usos.legacy_image_hex`, `usos.esp_partuuid`) przekazywane plikiem
   stanu na ESP, nie linią poleceń. Pakiet XP (osobny initramfs) staje
   się drugim UKI.
3. Sprawdzić, że nic w ścieżkach UEFI nie wymaga zablokowanych funkcji
   (analiza w secure-boot-usos.md: `/dev/mem` tylko jako fallback
   `dmidecode`, `kexec` tylko w BIOS).
4. Konsekwencja: każda zmiana initramfs = nowy podpis; to wymusza
   deterministyczny build (już jest dla `initramfs-usos` i pakietu XP).

### L1. Rodzina NT5 na UEFI: **Later**

Projekt: [design/nt5-uefi-family.md](design/nt5-uefi-family.md).
Windows 2000 (SP4), Server 2003 x86/x64, XP x64 przez tę samą ścieżkę
„przygotowanie z UEFI → rozruch przez CSM” co XP x86. Wymaga profili NT5
(N2/M4), sterowników per jądro/architektura, katalogu `AMD64`+`I386`
dla x64, PAE natywnego (`/PAE`) dla 2000 AS i 2003 Enterprise.
Kolejność testów: 2003 x86 Enterprise → XP x64 → 2003 x64 → 2000.

### L2. XP na UEFI bez CSM przez CSMWrap: **Later**, eksperymentalne

W tym samym dokumencie, sekcja 7. SeaBIOS jako CSM daje int13
(AHCI/NVMe/USB) i VBE na GOP; główne problemy: prawdziwe VGA (text mode,
`bootvid`), VBEMP, sterownik NVMe dla XP, ACPI z trybu UEFI (x2APIC),
brak emulacji 8042. Dysk docelowy potrzebuje małego ESP z CSMWrap do
każdego startu. Secure Boot off; CSMWrap **nie** jest podpisywany
kluczem USOS. Poprzednia próba (2026-09-20, Win7/Intel) zatrzymała się po
`Booting drive`, więc najpierw QEMU.

### L3. Starsze CPU i mniej RAM: **Later**, najpierw pomiary

Dziś: mikro-Linux jest x86_64 (wymaga long mode), minimum 256 MiB RAM;
UI BIOS używa okna 32–48 MiB (`src/platform/bios/boot_ui.zig`:
zasoby od `0x02000000`, bufory ramek do `0x03000000`), a przy braku RAM
w tym oknie spada do czcionki 5x7 i angielskiego; Win98 rezerwuje
256 MiB od 128 MiB.

1. **Pomiary** (2 dni): minimalna RAM per ścieżka w QEMU (menu BIOS,
   menu UEFI, mikro-Linux + przygotowanie XP, Win7 WinPE, 98 DOS Setup,
   FreeDOS, Memtest), pik zajęcia pamięci w mikro-Linuksie
   (`/proc/meminfo` w logu przygotowania). Cele ustalać dopiero z danych;
   robocze propozycje: menu BIOS 32 MiB, mikro-Linux 128 MiB, 98 SE
   64 MiB.
2. **Przeniesienie okna 32–48 MiB BIOS** poniżej 16 MiB albo dynamicznie
   z E820 (najwyższy wolny ciągły zakres pod 4 GiB, z odstępem od
   miejsc używanych przez loader Linuksa `0x01000000–0x03604000`).
3. **Initramfs dzielony / squashfs czytany z USB**: mały initramfs
   (init, sterowniki pamięci masowej, ntfs3/vfat) + `usos.sqfs` na ESP
   montowany z nośnika; zmniejsza wymagania RAM z ~39 MB spakowanego
   (rozpakowanego wielokrotnie więcej) do kilku MB. Wpływ na N6: squashfs
   musi być weryfikowany (dm-verity z hashem w podpisanym UKI).
4. **i686 mikro-Linux** (Pentium III, Athlon XP) z tym samym initramfs
   userlandem 32-bit (Alpine x86), wybierany przez Core po CPUID (brak
   LM). `usos-fb-ui` budowany także dla `x86-linux-musl`.
5. **`BOOTIA32.EFI`**: UEFI IA32 (tablety Bay Trail, stare Maki): menu
   Zig dla `x86-uefi` + podpisany shim ia32 (Fedora dostarcza
   `shimia32.efi`). Pamiętać: tylko ESP może mieć `\EFI\BOOT\BOOT*.EFI`
   (MEDIA_LAYOUT).

### L4. Chainload dla PC bez startu z USB: **Later**

Stare płyty (bez USB boot lub z USB-FDD/ZIP) startują z CD albo
dyskietki. Plan: mały obraz CD/dyskietki „USOS USB loader” z własnym
sterownikiem UHCI/OHCI/EHCI dla int13, który podaje pendrive jako 0x80
i startuje Core. Plop Boot Manager jest zamknięty i nie może być
redystrybuowany bez zgody, więc: albo własny moduł w Core (Core ma już
wzorzec filtra int13 `dos_disk_filter.S`), albo SeaBIOS-owe sterowniki
USB (LGPL) w roli payloadu. Wymaga CPU i RAM z L3 dla samego Core.

### L5. Pozostałe usprawnienia z E2B: **Later**

Patrz tabela w N5 (persistence, `theme.ini`, klawiatury, `PostInstall`,
test QEMU). Dodatkowo z porównania E2B: lista PCI ID kontrolerów z
informacją, czy USOS ma dla nich sterownik XP/7, ostrzeżenie o baterii
CMOS (zły rok), opcjonalna blokada menu hasłem.

### L6. Windows 98 na X470: **Later**, eksperymentalne

Działa dziś w Legacy BIOS (DOS Setup, Patcher9x `mem`) i na retro PC
MS-7100 ([win98-native](win98-native-2026-09-12.md)). Dla X470 analiza
[research/win98-feasibility.md](research/win98-feasibility.md) zaleca:
najpierw **ręczny spike** na osobnym dysku (CSM on, AHCI, GeForce 7 /
Radeon X8xx, PS/2), potem ścieżkę „UEFI → mikro-Linux (MBR/FAT32,
Patcher9x `tlb,creg,mem,speed`, `msbatch.inf`, sterowniki użytkownika)
→ natywny CSM”, jako profil 9x w pipeline. Wszystkie sterowniki 9x
i pliki Microsoft są user-supplied (licencje).

### L7. Buildy Longhorn: **Later**

- Pre-reset (4xxx): nośnik z `I386\TXTSETUP.SIF` → profil NT5 (jądro
  5.2-podobne, jak 2003 x86) przez ścieżkę L1.
- Post-reset (5xxx): nośnik z `sources\install.wim` → ścieżka Vista
  (WinPE, wimboot/WORK).
- Rozpoznawanie po **strukturze nośnika**, nie numerze buildu (zasada
  z ARCHITECTURE.md).
- **Timebomb:** tabela danych `build → data wygaśnięcia`. USOS nie
  zmienia zegara sam (zasada ze starej roadmapy). Podsumowanie pokazuje
  wymaganą datę i zaleca VM albo ręczną zmianę daty w BIOS; opcjonalne
  narzędzie „ustaw datę RTC” tylko po jawnym potwierdzeniu i z
  przypomnieniem o powrocie. Wymagania RAM/dysku/firmware zapisywane per
  build, jak w starej roadmapie (pkt 7).

### L8. NT4 dla retro sprzętu: **Later**

`winnt /b` tworzy te same `$WIN_NT$.~BT`/`~LS` co NT5, więc staging NT5
jest w większości do użycia, ale: text mode NT4 bez SP nie czyta NTFS 3.x
tworzonego przez `mkntfs` → partycja startowa FAT16 (do 2/4 GiB, limit
startu 7,8 GB / 1024 cylindry bez nowszego `atapi.sys`), `unattend.txt`
zamiast `winnt.sif`, brak ACPI, USB i AHCI. Tylko BIOS i retro sprzęt
(MS-7100 w trybie IDE). Najniższy priorytet.

### L9. shim-review: **Later**, długoterminowo

Własny shim z wbudowanym certyfikatem USOS, podpisany przez Microsoft,
usunąłby ręczne wpisywanie MOK na każdym komputerze. Wymaga: publicznego
repozytorium, powtarzalnego buildu shim, klucza w HSM, SBAT, polityki
reagowania na podatności, zablokowanego jądra (N6) i przeglądu na
`rhboot/shim-review`. Do tego czasu model „shim dystrybucji + MOK”
pozostaje.

## 3. Znane ograniczenia (zaakceptowane)

- **AMI pokazuje każdą montowalną partycję** pendrive'a jako osobny
  wpis „UEFI: <dysk>, Partition N” (FAT32 ESP oraz NTFS DATA/WORK przez
  sterownik NTFS ASRocka), niezależnie od zawartości. Atrybut GPT
  `NO_BLOCK_IO` psuje ścieżkę NTFS UEFI (TESTING.md). Nie do usunięcia
  po stronie USOS.
- **Dotyk na ROG Ally tylko przez dostarczony sterownik** TouchI2cDxe
  v1.3.1-usos1 (EDK2, budowany poza repo przez
  `tools/build_touchi2cdxe.ps1`, podpisany MOK), ładowany tylko przy
  pasującym SMBIOS. Własna implementacja I2C-HID w Zig (ok. 1,5–3 tyg.)
  nie jest planowana. Ryzyka: AOAC, przyszły konflikt ze sterownikiem
  firmware, polling zamiast GPIO.
- Windows XP, Vista i 7 wymagają wyłączonego Secure Boot.
- Mikro-Linux wymaga x86-64 i 256 MiB RAM (do czasu L3).
- Win98 i DOS: tylko Legacy BIOS (do czasu L6).
- XP: brak NVMe (także przy CSM); XP w BIOS nie ma pakietu sterowników
  ani PAE (tylko wariant UEFI-CSM).
- WHPX nie nadaje się do pełnych przebiegów Windows w QEMU; pełne testy
  idą na TCG (wolno).

## 4. Otwarte punkty ze starej roadmapy (13 września)

- Zegar na ekranach postępu przestaje się aktualizować (pkt 6): brak
  wpisu o naprawie; zweryfikować przy etapie komunikatów w N2 (M6).
- Migracja na SanDisk 128 GB zamiast E2B: nadal nie wykonana (wymaga
  kopii nośnika E2B; operacja na dyskach tylko na wyraźne polecenie).
- Windows 7 na fizycznym X470: nadal niepotwierdzony
  (`windows7-x470-starting-windows.md`: „nie oznaczać jako działającego”;
  int10 i AMD shadow wdrożone bez potwierdzenia). Vista na X470: sukces
  sprzętowy v11 (`windows-vista-usb-install-2026-09-21.md`).
- Linux Live poza SliTaz i narzędzia w UEFI: przez ogólny wpis (N5).

## 5. Zrobione: najważniejsze funkcje (skrócony changelog)

Szczegóły i dowody: `TESTING.md` i dokumenty w `docs/`.

| Data | Funkcja |
|---|---|
| 2026-09-03 | Walidacja backendów; przygotowanie WORK (mikro-Linux → NTFS WORK → EfiFs → Windows Boot Manager) dla Windows 11 w UEFI; `device_guard` (PARTUUID + `.usos-work` nonce) |
| 2026-09-09 | XP w BIOS: lokalne źródło na jednej partycji NTFS, NT52 z EDD/LBA, graficzny wybór dysku, formatowanie całego dysku z potwierdzeniem |
| 2026-09-10/11 | Windows 7 i Vista w BIOS; Vista bezpośrednio z ISO przez wimboot (bez WORK) |
| 2026-09-12 | Windows 2000 SP4 (BIOS, NT5), Windows 10 x86 (BIOS, wimboot), Windows 98 SE (DOS Setup, Patcher9x), MS-DOS 6.22 i Windows 3.1/3.11; potwierdzone na MS-7100 |
| 2026-09-13 | Windows 7 UEFI + USB 3 + integracja NVMe (QEMU, pełna instalacja); FreeDOS, Memtest86+, Hardware & SMART, SliTaz Live (BIOS); użytkownik potwierdził Windows 10/11 UEFI z unattended |
| 2026-09-20/21 | Vista SP2 x64 z USB na X470 (PE10, KMDF/USB, pierwszy start: sukces sprzętowy v11); Windows 7 na X470: prace (int10, AMD shadow, KMDF), bez potwierdzenia; próba CSMWrap (wycofana); XP UEFI-CSM + PAE: pakiet i sterowniki (ACPI, GenAHCI, USB3, KMDF) |
| 2026-09-22 | XP UEFI-CSM: czysta instalacja z pendrive'a na X470; `pae.exe` bez promptów, `CrashDumpEnabled=0`, kontrola zerowych plików |
| 2026-09-23 | XP: PAE na końcu Setup (`UserExecute`), 31,9 GB na X470 potwierdzone; i18n: jeden katalog 27 locale (instalator, menu, mikro-Linux, XP, WinPE) i wybór języka; ekran ładowania i etapy postępu per ścieżka; łańcuch startowy WORK w `\EFI\USOS-WORK` |
| 2026-09-24 | Powtarzalny build pakietu XP (`compare_xp_packages.py`); zapas 43 KiB w Legacy Core; pady USB w menu UEFI; **Secure Boot** (shim 16.1 + MOK, podpisane jądro, sterowniki, zapis klucza bez MokManagera); dotyk ROG Ally (TouchI2cDxe) potwierdzony; foldery `DATA\Drivers` (UEFI + INF dla 7/8/10/11); analizy E2B i Win98 |
