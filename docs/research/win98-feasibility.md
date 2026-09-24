# Windows 98 SE jako „ultimate 9x PC” przez USOS — analiza wykonalności

Stan: 2026-09-24. Wyłącznie research (bez zmian w kodzie, bez zapisów na dyski).
Cele: **X470** (ASRock, AMI Aptio, CSM dostępny, Ryzen 7 5700X, 32 GB, brak PCI,
SATA tylko AHCI/RAID, USB 3 xHCI) oraz „retro PC”. W repo retro PC to
najpewniej **MS-7100** (MSI K8N Neo4/SLI Platinum: nForce4 CK804, Athlon 64 X2 4200+,
3× PCI, 2× PCIe x16, 2× IDE, AC'97 ALC850, Award BIOS) — zob.
[legacy-xp-investigation](../legacy-xp-investigation-2026-09-09.md),
[win98-native](../win98-native-2026-09-12.md), [win98-ram](../win98-ram-2026-09-12.md).
Jeśli „retro PC” to inna maszyna (np. Core 2 + ICH), wnioski dla „typowego retro PC”
pozostają aktualne.

Powiązane w repo: istniejąca ścieżka **Windows 98 SE — Automatic (DOS Setup)**
(Legacy Core → MEMDISK → oryginalny DOS z ISO użytkownika → `SETUP /IS`, z
Patcher9x 0.9.91 ograniczonym do `mem`) oraz ścieżka **XP UEFI → Linux → CSM**
([windows-xp-uefi-csm-pae](../windows-xp-uefi-csm-pae-2026-09-21.md)) i próba
CSMWrap ([csmwrap-trial](../csmwrap-trial-2026-09-20.md)).

---

## 0. Werdykt w skrócie

| Cel | Wykonalność | Komentarz |
|---|---|---|
| **MS-7100 / typowy retro PC** (K8/Core 2, PCI + IDE, BIOS) | **Wysoka** | To „naturalny” sprzęt dla 98 SE. USOS ma już działającą ścieżkę DOS Setup; brakuje głównie pakietu poprawek i wstrzykiwania sterowników. |
| **X470 + 5700X + GeForce 6/7 / Radeon X8xx PCIe** | **Średnio-niska, eksperymentalna** | Da się dojść do pulpitu z akceleracją 3D (są raporty na AM4), ale: brak natywnych sterowników dla dysku (AHCI tylko przez sterownik community), USB (xHCI), audio (brak PCI, HDA eksperymentalne), sieci (Intel I211 bez 9x) i ryzyko ACPI/IRQ. Nie nadaje się jeszcze do automatyzacji „na ślepo” — najpierw ręczny spike sprzętowy. |

Projekt z GitHuba, o którym najpewniej mówił użytkownik: **Windows 9x QuickInstall**
(`oerg866/win98-quickinstall`), który integruje **CSMWrap** (`CSMWrap/CSMWrap`,
dawniej `FlyGoat/csmwrap`, autorzy FlyGoat i Mintsuki) i reklamuje instalację 9x
„na maszynach UEFI bez CSM”. Sam „bootloader” to CSMWrap (SeaBIOS jako CSM
uruchamiany jako aplikacja EFI). Szczegóły w §1.

---

## 1. Bootloadery 9x na UEFI / maszynach bez CSM

### 1.1 CSMWrap — kandydat nr 1 („bootloader dla 9x na UEFI”)

- Repo: <https://github.com/CSMWrap/CSMWrap> (przekierowanie z FlyGoat/csmwrap;
  fork Mintsuki: <https://github.com/mintsuki/csmwrap>). ~955 gwiazdek, >100 otwartych issue.
- **Licencja: LGPL-2.1** (plik LICENSE; SeaBIOS: LGPLv3). Redystrybucja z kodem źródłowym dozwolona.
- **Status:** wydania 3.1.0–3.1.2 (maj 2026; 3.1.2 = 2026-05-09). USOS testował już 3.1.2
  fizycznie (zatrzymanie po SeaBIOS `Booting drive` na Intelu — [csmwrap-trial](../csmwrap-trial-2026-09-20.md)).
- **Jak działa:** aplikacja EFI (`/EFI/BOOT/BOOTX64.EFI` lub IA32) ładuje build SeaBIOS
  z `CONFIG_CSM=y`, odblokowuje region 0xC0000–0xFFFFF (m.in. przez AMD MTRR),
  kończy usługi EFI i robi legacy boot. Zalecany MBR, Secure Boot off.
- **Dysk / int13:** SeaBIOS w trybie CSM wywołuje `device_hardware_setup()` — własne
  sterowniki **AHCI, NVMe, ATA, USB (xHCI/EHCI/OHCI/UHCI, MSC, HID)**; wszystkie domyślnie
  włączone w Kconfig, a `seabios-config` CSMWrap nadpisuje tylko `CSM` i `VGA_COREBOOT`.
  Czyli int13 dla NVMe/AHCI/USB zapewnia SeaBIOS, niezależnie od firmware.
- **V86:** wywołania BIOS z trybu V86 (EMM386, Win 3.x 386 enh., tryb zgodności MS-DOS
  w 9x) są obsługiwane przez „BIOS proxy” — **jeden logiczny procesor jest rezerwowany**
  jako rdzeń pomocniczy w trybie chronionym (bo brak SMM). README wprost wskazuje,
  że natywne CSM-y mają błąd z wywołaniami BIOS z V86 i „dirty control registers” (cregfix),
  a CSMWrap ich nie ma. Nie działa na maszynach z 1 wątkiem (5700X ma 16 — bez problemu).
- **VGA/VBE:** kolejność: własny OpROM karty (legacy VBIOS) → plik `vgabios=` z ESP → SeaVGABIOS
  na framebufferze GOP. SeaVGABIOS obsługuje VBE (wystarcza dla NT/Linux), ale „pretty much
  all MS-DOS games” i tryby tekstowe/VGA bezpośrednie nie działają. Dla 9x z GeForce 7
  kartą z legacy VBIOS to OpROM karty będzie użyty — ale **karta bez GOP nie da obrazu
  w fazie UEFI przy wyłączonym CSM**, więc na X470 z GeForce 7 CSMWrap jest niepraktyczny.
- **A20:** README nie opisuje; SeaBIOS obsługuje A20 przez port 0x92/int15 AX=24xx (standard).
- **Mapa pamięci:** własne `e820.c` buduje E820 z mapy UEFI (region <1 MiB, rezerwacje).
- **ACPI / IRQ:** uACPI do obsługi tabel; generuje **MP table** (dla OS bez ACPI) oraz
  syntetyzuje **$PIR** (PCI IRQ Routing, PCI BIOS 2.1) z ACPI `_PRT/_PRS` i serwuje go przez
  int1A B406h. To istotne dla 98 SE instalowanego **bez ACPI** (patrz §9). Zalecane
  wyłączenie X2APIC, ewentualnie Above 4G Decoding i ReBAR; domyślnie wyłącza IOMMU.
- **USB klawiatura:** SeaBIOS obsługuje klawiaturę USB tylko przez int16 (DOS/BIOS).
  Nie emuluje portów 60h/64h (to robi SMM w natywnym CSM). **Po starcie GUI 98 klawiatura
  i mysz USB nie będą działać** bez PS/2 lub sterownika xHCI dla 9x (§5).
- Źródła: README <https://github.com/CSMWrap/CSMWrap/blob/main/README.md>,
  wiki <https://github.com/FlyGoat/CSMWrap/wiki/Usage-Guide>,
  src (`bios_proxy.c`, `pir.c`, `e820.c`, `video.c`) <https://github.com/CSMWrap/CSMWrap/tree/main/src>,
  SeaBIOS Kconfig <https://github.com/coreboot/seabios/blob/master/src/Kconfig>,
  SeaBIOS `csm.c` <https://github.com/coreboot/seabios/blob/master/src/fw/csm.c>,
  Hackaday (2025-05-29) <https://hackaday.com/2025/05/29/bring-back-the-bios-to-uefi-systems-that-is/>,
  YouTube „CSMWrap: Legacy OSes are back on UEFI! (Tested with Windows 98, XP x64 & Vista)”
  <https://www.youtube.com/watch?v=AcSfEvuz8IE> (wg opisu: 98 wstał z NVMe, problemem były
  sterowniki grafiki; obejście — sterownik VBE).

### 1.2 Windows 9x QuickInstall (oerg866) — kompletny „framework” 9x na współczesny sprzęt

- Repo: <https://github.com/oerg866/win98-quickinstall> (~1.7k gwiazdek, aktywny).
- **Wydania:** v1.0.0 (2026-02-15: przepisany instalator, NVMe, jądro EFI, GPT/LBA64),
  v1.0.1(a) (2026-03-09), **v1.1.0 (2026-09-19)**: jądro EFI x64, **CSMWrap 3.1.2**, ACPI/APIC
  w obrazach (na zamrożenia i IRQ sharing), opcje „no APIC/ACPI” i „no ATA DMA”, poprawione
  sterowniki AHCI, NDIS2 (m.in. Realtek 2.5G), eksperymentalne HDA A. Hoffmana w bibliotece EXTRA.
  <https://github.com/oerg866/win98-quickinstall/releases/tag/v1.1.0>
- **Mechanizm:** środowisko Linux (instalator `lunmercy`, format MercyPak) wgrywa gotowy,
  wcześniej przygotowany obraz systemu z własnej instalacji 98 SE/ME, zamiast `SETUP.EXE`.
  Obsługuje ISO/floppy/USB; USB startuje też na UEFI przez CSMWrap („*very* experimental”).
- **Zawiera / integruje:** CREGFIX (VxD wersja SweetLow), stos USB 2.0 + Mass Storage i **NVMe**
  od SweetLow/LordOfMice, poprawione sterowniki AHCI R. Loewa, LBA64HLP + GPT, NTFS (UFSD/Paragon),
  a obrazy referencyjne są „pre-patched” (TLB, CSM CR, pamięć, LBA48).
- **Licencja:** BUILDING.md: MercyPak i instalator — **CC-BY-NC 4.0** (niekomercyjna).
  Brak pliku LICENSE rozpoznanego przez GitHub. Użytkownik ma sam dostarczyć źródło Windows;
  „pre-built reference images” to jednak gotowe obrazy Windows — **USOS nie może ich
  redystrybuować ani się na nich opierać**.
- **Ograniczenia (FAQ):** partycja startowa musi leżeć w pierwszych 137 GB (start przez DOS/int13);
  brak startu z dysku 4Kn; plik wymiany przestaje działać na C: > ~210 GB; problemy IRQ sharing
  (np. #149: most ASM2812 dzielący IRQ 11 z xHCI/EHCI → zawieszenie; obejście: wyłączyć USB w BIOS);
  zamrożenia po starcie z USB przy „legacy emulation” USB mass storage (odłączyć pendrive).
  <https://github.com/oerg866/win98-quickinstall/blob/master/supplement/help.txt>,
  <https://github.com/oerg866/win98-quickinstall/issues/149>
- Forki: `strikersix23/win98-quickinstall`, `Mudb0y/talking-win9x-quickinstall` (instalacja dla niewidomych).

### 1.3 Inne

- **CREGFIX** (Mintsuki, **0BSD**) — sterownik DOS `.SYS` / `.COM` czyszczący CR0/CR2/CR3/CR4/EFER
  zostawione przez CSM; naprawia „While initializing device VCACHE: Windows protection error”.
  <https://github.com/mintsuki/cregfix>; opis przyczyny:
  <https://somethingnotserious.wordpress.com/2023/11/01/win98-vcache-protection-error-on-modern-hardware/>
- Nie znaleziono innego, osobnego „loadera 9x dla UEFI” (np. VxD-owego ładowania bez BIOS).
  Wszystkie praktyczne rozwiązania to CSM (natywny albo CSMWrap/SeaBIOS) + DOS/`IO.SYS`.

---

## 2. Win98 na nowoczesnych CPU (Zen, szybkie zegary)

| Problem | Dotyczy | Objaw | Poprawka |
|---|---|---|---|
| **TLB invalidation bug** (VMM zakłada, że zmiana PTE nie wymaga flush) | 98 FE, **98 SE**, ME; **Zen 2+ (w tym Zen 3 = 5700X)**, Intel 11. gen+ | losowe błędy DLL/rundll32, zawieszenia, protection errors | Patcher9x `tlb`: wstrzyknięcie `mov ecx,cr3 / mov cr3,ecx` w VMM.VXD |
| **CPU speed limit** (dzielenie przez zero w pętli kalibracji) | 95, **98 FE** (≈2 GHz+); 98 SE ma ochronę, ale krótką pętlę | „Windows protection error” / błąd NDIS | Patcher9x `speed` = `speeddrv` (NTKERN, IOS, ESDI_506, SCSIPORT…) + `speedndis` (NDIS.VXD/NDIS.386); 80 000 000 cykli + ochrona /0 |
| **Dirty CR/MSR z CSM** | każda wersja na nowych CSM-ach | „VCACHE: Windows protection error”, crash EMM386 | Patcher9x `creg` (w `WIN.COM`, tylko gdy start z real mode) lub CREGFIX w CONFIG.SYS przed menedżerem pamięci |
| **E820 > 4 GiB / nieposortowana mapa** | 98/ME na maszynach z dużą RAM | VMM przerywa parsowanie E820 → I/O traktowane jak RAM, konflikty zasobów | Patcher9x 0.9.91 „4G Resource patch” (na bazie vmm4gfix SweetLow) |
| **VME** (błąd AMD w pierwszych Zen) | Zen 1 | problemy z real-mode sterownikami (VM) | naprawione mikrokodem; dla Zen 3 bez znaczenia |

- Patcher9x: **MIT**, JHRobotics, v0.9.91 (2025-12-22). Hosty Linux i Windows (oraz DOS z dyskietki FreeDOS).
  Tryby: interaktywny, **`-auto` (bez pytań)**, batch (`--cabs-extract`, `--patch tlb VMM.VXD`),
  wybór: `-select tlb,speed,mem,creg[,16m]`, `-reverse`. **Patchowanie offline instalki:**
  `patcher9x /ścieżka/win98` → pliki oznaczone `N` (VMM32.VXD, VMM.VXD, NTKERN.VXD, IOS.VXD,
  ESDI_506.PDR, SCSIPORT.PDR, NDIS.VXD, NDIS.386, VCACHE.VXD, WIN.COM/WIN.CNF) kopiuje się
  do folderu instalacyjnego; Setup bierze luźne pliki przed CAB-ami. Uwaga: VMM32.VXD z instalki
  ≠ VMM32.VXD w `WINDOWS\SYSTEM`. Poprawki Q288430 (98 SE) i inne aktualizacje nadpisują pliki —
  trzeba patchować ponownie.
- **Wniosek: patchowanie da się w pełni zautomatyzować offline** (Linux preparer albo DOS w USOS).
  USOS już przypina Patcher9x 0.9.91 z SHA-256; wystarczy rozszerzyć `-select mem` do
  `tlb,creg,mem,speed` (+ ewentualnie `16m`) dla celów Zen/nowych CSM.
- Źródła: <https://github.com/JHRobotics/patcher9x>, README (sekcje TLB/speed/creg/4G/media)
  <https://github.com/JHRobotics/patcher9x/blob/main/README.md>, wydania
  <https://github.com/JHRobotics/patcher9x/releases/>, opis TLB
  <https://blog.stuffedcow.net/2015/08/win9x-tlb-invalidation-bug/>, speed bug
  <https://www.betaarchive.com/forum/viewtopic.php?t=29224>, 4G/E820 (SweetLow, 2025-04-05)
  <https://msfn.org/board/topic/186768-bug-fix-vmmvxd-on-handling-4gib-addresses-and-description-of-problems-with-resource-manager-on-newer-bioses/>,
  VME/Ryzen: <https://www.vogons.org/viewtopic.php?t=66367>, <https://www.vogons.org/viewtopic.php?t=68205>.

---

## 3. RAM: MaxPhysPage, MaxFileCache, PATCHMEM

- Przyczyna problemów > 512 MB: VCACHE rezerwuje przestrzeń adresową proporcjonalnie do RAM;
  typowe błędy „Insufficient memory to initialize Windows” / „not enough memory”.
  <https://dfarq.homeip.net/taming-windows-959898seme-memory-errors/>
- Bez patcha: `[386Enh] MaxPhysPage=20000` (512 MiB; `1FFFF` działa też w czasie Setup) i
  `[vcache] MaxFileCache=524288` lub mniej (często `262144`).
- **PATCHMEM (R. Loew)** v7.2 (2017): patchuje VMM.VXD + VCACHE.VXD (wyciąga z VMM32.VXD);
  opcja `/M` zwalnia pamięć poniżej 16 MB (tablice pamięci, gigabitowe NIC). >2.75 GB:
  `HIMEM.SYS /NUMHANDLES=64`; EMM386 blokuje się > ~2800 MB bez tej opcji. Aktualizacje
  (np. U98SESP3) nadpisują pliki → ponowne patchowanie.
- **Licencja/dostępność po śmierci autora (11.09.2019):** strona pamięci
  <https://rloewelectronics.com/> prowadzona przez rodzinę: „all of Rudy's projects will be made
  available (including source code)”, zakupy wyłączone. Udostępnione: PATCHMEM 7.2 (release + „PRO”
  z `PATCHMEM.C`), PATCH137 5.3 (LBA48), SATA 1.0–1.1a, TBPLUS, AHCICD, RFDISK, RFORMAT, RAMDISK…
  Jednak **pliki `LICENSE.TXT` zostały bez zmian** (single-computer, zakaz modyfikacji/RE,
  w wersji release nawet tekst „DEMO”), a stara strona „Free Software” zawiera „Distribution and/or
  Linking to these Files directly is Prohibited”. **Nie ma formalnej licencji otwartej** — status
  „udostępnione przez spadkobierców, bez jawnej licencji”. Mirrory: archive.org
  (<https://archive.org/details/PATCHMEM>, <https://archive.org/details/rloewelectronics.com>),
  PhilsComputerLab (<https://www.philscomputerlab.com/rudolph-r-loew-patches.html>),
  bundle <https://retrosystemsrevival.blogspot.com/2020/06/rloew-9598me-patches-bundle.html>.
  Patcher9x (MIT) integruje PATCHMEM — USOS już dystrybuuje Patcher9x; formalnie część `mem`
  dziedziczy niejasny status Loewa (ryzyko niskie w praktyce, ale warto odnotować w NOTICE).
- **Bezpieczne ustawienia dla 32 GB** (X470, najmniejszy moduł DDR4 to 4–8 GB, więc
  zmniejszenie RAM fizycznie nie wystarczy):
  1. Zawsze: Patcher9x `mem` (+`16m` przy problemach z pamięcią < 16 MB) **i** poprawka 4G Resource
     (E820 > 4 GiB; w 0.9.91 w zestawie domyślnym).
  2. Mimo patcha ograniczyć widziany RAM: start `MaxPhysPage=40000` (1 GiB); po testach
     `80000` (2 GiB). Powyżej ~3 GiB 98 i tak nic nie zyska, a karty 256–512 MB VRAM + aperture
     zjadają przestrzeń adresową.
  3. `[vcache] MinFileCache=65536`, `MaxFileCache=262144` (256 MiB; nie więcej niż 524288).
  4. `HIMEM.SYS /NUMHANDLES=64` w CONFIG.SYS, jeśli dopuszczamy > 2.75 GB; bez EMM386.
  5. Setup: patch przed Setupem (USOS już tak robi) albo `MaxPhysPage=1FFFF` na czas instalacji.
  Źródła: manual PATCHMEM <https://rloewelectronics.com/distribute/PATCHMEM/VER7.2/MANUAL.TXT>,
  Patcher9x `doc/patchmem-manual.txt`, VOGONS <https://www.vogons.org/viewtopic.php?f=61&t=85469>,
  <https://www.vogons.org/viewtopic.php?f=61&t=59229>.

---

## 4. Dyski na chipsetach tylko-AHCI

### 4.1 Tryb zgodności MS-DOS (int13)
- Bez sterownika protected-mode 98 używa int13 BIOS/CSM przez V86 („MS-DOS compatibility mode”).
  Działa, ale: wolniej (synchroniczne wywołania BIOS, brak współbieżności), ostrzeżenie w
  Właściwości systemu → Wydajność, problemy z pamięcią wirtualną i nagrywarkami.
- **Stabilność na natywnym CSM jest wątpliwa:** README CSMWrap opisuje, że współczesne CSM-y
  nie wykonują niezawodnie wywołań BIOS z V86 (crashe EMM386/Win3.x 386 enh.). Tryb zgodności
  9x to dokładnie ten scenariusz. Na X470 trzeba to sprawdzić empirycznie; pod CSMWrap
  (bios_proxy) jest to rozwiązane konstrukcyjnie.
- AMI CSM na AM4 zwykle **nie ma int13 dla NVMe** (brak legacy OpROM NVMe) → na X470 z natywnym
  CSM startować z SATA SSD; NVMe tylko przez CSMWrap/SeaBIOS.

### 4.2 Sterowniki AHCI/NVMe dla 9x
- **R. Loew AHCI.PDR 3.0** (dawniej płatny) + **łatki SweetLow** (SMART/IDE_PASS_THROUGH, wild
  pointer przy power-down → BSoD, polecenia bez transferu, MSN). Paczki na
  <https://sweetlow.orgfree.com/download/> (2024–2025), wątek
  <https://msfn.org/board/topic/186313-patches-for-esdi_506pdr-from-98se-terabyte-plus-pack-21-rloews-ahcipdr-and-more/>,
  oryginał: <https://archive.org/details/ahci_win9x>. Licencja: Loew — jak wyżej (niejasna);
  SweetLow — brak jawnej licencji. **Tylko „user-supplied”.** Nie znaleziono raportów
  specyficznych dla AMD FCH AHCI (1022:7901) ani Promontory SATA — do przetestowania.
- **NVMe9x** (SweetLow; port nvme2k z LBA64 i poprawkami kolejkowania), **LBA64HLP**, **GPTTSD**,
  **CREGFIX VxD**: <https://github.com/LordOfMice/Tools> (brak pliku licencji → nie redystrybuować).
  Wątek nvme2k: <https://www.vogons.org/viewtopic.php?p=1388506>.
- **Loew SATA patch 1.1a** (`PTCHSATA.EXE` + `SATA.INF`): ESDI_506.PDR dla kontrolerów SATA
  w trybie **native IDE** (dzielone IRQ, bez V86 I/O). Nie usuwa limitu 137 GB. Procedura:
  po pierwszym restarcie Setup → DOS → PTCHSATA → `SATA.INF` do `C:\WINDOWS\INF` → kontynuacja.
  <https://rloewelectronics.com/distribute/SATA/1.1a/README.TXT>
- **Karty PCIe w trybie IDE:** JMicron JMB36x (JMB363/368) — raportowany jako działający w 98 SE
  (VOGONS „PCIe devices on Windows 98 SE”); ASM1061 niektóre karty mają tryb IDE (do weryfikacji);
  SiI3112/3114 to PCI (na X470 tylko przez mostek PCIe→PCI). Uwaga na IRQ sharing mostków (§1.2, #149).
  <https://www.vogons.org/viewtopic.php?f=46&t=44407>

### 4.3 Duże dyski / FAT32
- **137 GB (LBA28)** w ESDI_506.PDR: PATCH137 5.3 (Loew, `48BITLBA.EXE`), TBPLUS, łatki SweetLow
  dla ESDI_506 (LBA48 tylko ≥128 GiB, fallback DMA→PIO, poprawki IRQ). Na AHCI.PDR limit nie dotyczy.
- **Partycja startowa w pierwszych 137 GB** (DOS/int13 przy starcie) — wg FAQ QuickInstall.
- **FAT32 ≤ ~127.53 GB** na wolumin (16-bitowy ScanDisk: FAT < 16 MB − 64 KB, ~4 177 918
  klastrów); FDISK 98 ma też błąd wyświetlania > 64 GB (KB263044). Plik wymiany na C: > ~210 GB nie działa.
  <https://www.helpwithwindows.com/windows98/fat32.html>, <https://www.vogons.org/viewtopic.php?t=44423>
- USOS już tworzy 8/4/2 GiB FAT32 typu 0C od LBA 2048 — zgodne z tymi limitami.

---

## 5. USB

- 98 SE ma tylko UHCI/OHCI (USB 1.1); EHCI przez **NUSB 3.3/3.6** lub **stos USB 2.0 SweetLow**
  (zbudowany z plików Windows 2000 SP4 → **pliki Microsoftu, nie redystrybuować**).
  <https://msfn.org/board/topic/91336-usb-20-stack-for-win98me/>
- **xHCI98** (Yeo Kheng Meng): miniport xHCI pod `usbport.sys` z tych stosów — **tylko prędkość
  High-Speed (USB 2.0)** na kontrolerach USB 3; licencja **GPL-2.0-only** (README; GitHub pokazuje
  NOASSERTION); ostatnie wydanie v1.1.1.0 (2026-09-23). Testy: Intel 100/300/400 PCH OK;
  **AMD B550 i X670 OK, X570 nie, xHCI w CPU Ryzen — mieszane**. **X470 (Promontory, 1022:43d5)
  i xHCI Matisse w 5700X — nietestowane.** Urządzenia audio full-speed na root porcie bez dźwięku
  (XP+) → przez hub USB 2.0.
  <https://github.com/yeokm1/xhci98>, <https://github.com/oerg866/win98-quickinstall/issues/164>
- **Emulacja legacy klawiatury/myszy:** natywny AMI CSM emuluje porty 60h/64h przez SMM —
  98 nie przejmuje xHCI, więc emulacja zostaje aktywna (typowo działa). **CSMWrap/SeaBIOS nie
  emuluje 8042** (tylko int16) → pod CSMWrap wymagane **PS/2** albo xHCI98 + HID.
  W raporcie AM4 (VOGONS t=88508) klawiatura USB działała przez emulację, mysz PS/2; problem z Fn
  na kompaktowej klawiaturze.
- Alternatywa sprzętowa: karta **PCIe USB 2.0 z VIA VT6212** (mostek + UHCI/EHCI) — w raporcie AM4
  dała „fully functional Windows 98SE on a PCI-E only motherboard”.

---

## 6. GPU (PCIe GeForce 6/7, Radeon X)

- **NVIDIA:** ostatni oficjalny 9x to **ForceWare 81.98** (luty 2006): GeForce 6 i 7800 (PCIe/AGP).
  **7900/7950/7600** wyszły później → **82.69** (nieoficjalny/„tweaked”, rozszerzony INF; wspiera
  GeForce 5/6/7 i część 8) albo 81.98 z przerobionym INF. Na PCIe NVIDIA często wymaga ręcznego
  wskazania INF (brak autodetekcji). TurboCache nie działa.
  <https://toogam.com/software/archive/drivers/videodrv/mswinvid/nvidia/unoffici/nv8269.php>,
  <https://www.vogons.org/viewtopic.php?t=47929>, <https://forums.guru3d.com/threads/drivers-nvidia-geforce-7900-windows-98se.239117/>
- **ATI:** ostatni 9x to **Catalyst 6.2**; obejmuje PCIe X300/X550/X600/X700/X800/X850.
  **X1000 (X1950 itd.) — brak sterowników 9x.** Radeon PCIe raportowane jako lepiej
  autodetekowane (X600/X800 XL/XT na P965).
  <https://www.techspot.com/drivers/driver/file/information/2907/>, <https://www.philscomputerlab.com/radeon-9x-drivers.html>
- **Pamięć:** karta 512 MB VRAM przy 512 MB RAM → „insufficient memory to run Windows”;
  działa z ≥1 GB RAM (z PATCHMEM). 256 MB karta jest bezpieczniejsza.
  <https://forums.tomshardware.com/threads/ultimate-windows-98-dos-gaming-pc.2849766/>
- **VBIOS/CSM:** GeForce 6/7 i Radeon X8xx mają **tylko legacy VBIOS (brak GOP)** → na X470
  CSM musi być włączony (inaczej brak obrazu w POST/UEFI). AMI z CSM zwykle daje GOP przez
  moduł CSM-video, więc menu UEFI USOS powinno się wyświetlić — **do sprawdzenia**. Wyłączyć
  Above 4G Decoding/ReBAR (BAR-y 9x muszą być < 4 GiB). Stare karty PCIe 1.x w slocie PCIe 3.0:
  w razie problemów wymusić Gen1/Gen2 w BIOS.
- **Chipsety PCIe:** wg VOGONS stabilność zależy od platformy (P965 gorzej niż ULi); „działa”
  ≠ „gry działają poprawnie”. Raport AM4 (B350, Ryzen 2700, 7600 GT, 82.69, DX9.0c): Quake II,
  Unreal, Half-Life, Thief działały.

---

## 7. Audio bez PCI

- **Mostek PCIe→PCI (ASM1083/IT8892) + SB Live!/Audigy:** w Windows bywa OK, ale „very finicky”,
  zależne od modelu; **DOS-owy dźwięk przez mostek zwykle nie działa**. Mostki wnoszą też ryzyko
  IRQ sharing. <https://www.vogons.org/viewtopic.php?t=68642>, <https://dosdays.co.uk/topics/pci_sound_cards_in_dos.php>
- **Karty PCIe z 9x:** praktycznie tylko **C-Media CMI8738 w wersji PCIe** (sterowniki 98 WDM działają;
  potwierdzone w raporcie AM4). Brak DOS. Audigy Rx (EMU10K2 za mostkiem) — 9x niesprawdzone.
  Creative PCIe (Z/AE) — brak 9x.
- **HDA na płycie:**
  - **WDMHDA** (Andrew Hoffman, **MIT**, aktywny): 98SE/ME/2000/XP; testowany m.in. na kontrolerach
    **AMD** i kodekach Realtek; **tylko odtwarzanie**, 16-bit stereo 22–48 kHz, jeden strumień,
    ~40 ms, bez retaskingu; autor ostrzega przed trzaskami/ciszą. W QuickInstall 1.1.0 w EXTRA.
    <https://github.com/andrew-hoffman/wdmhda>
  - **„Watler” HDA** (Watler's World; VxD dla Win 3.1, wersja 9.K/9.L; strona autora nie działa,
    kopie na win3x.org/archive.org): na 98 SE działa po modyfikacji instalacji, ale choppy dźwięk,
    zawieszenia przy DOS-ie, wolny start. **Brak licencji.**
    <http://www.vogons.org/viewtopic.php?p=1358760>, <https://retrosystemsrevival.blogspot.com/2019/06/windows-31959898se-hda-driver.html>
  - Czysty DOS: **VSBHDA** (GPL-2.0; emulacja SB na HDA/AC97 z HDPMI/Jemm) — tylko tryb DOS,
    nie w oknie 98. <https://github.com/Baron-von-Riedesel/VSBHDA>
- **USB Audio Class 1.0** (np. dongle CM108/CM119) — działa w 98 SE z EHCI/UHCI; na X470 wymaga
  xHCI98 (nietestowany na X470) lub karty VIA VT6212.

---

## 8. Sieć

- **Realtek RTL8111/8168:** oficjalne NDIS5 9x dla wczesnych rewizji (8111B; INF sugeruje 8111D),
  paczka „ndis5x-pcie (654)”. Nowsze (8111E/F/G/H, 8125) — tylko **NDIS2 (DOS) RTGND.DOS**
  pod 98 SE (real-mode; ~300 Mb/s wg rloew; po „Exit to MS-DOS” nie da się wrócić do Windows;
  ME nie ma NDIS2). QuickInstall 1.1.0 naprawił parametry NDIS2 dla Realtek 2.5G.
  <https://www.techspot.com/drivers/driver/file/information/7856/>,
  <https://msfn.org/board/topic/176892-using-real-mode-aka-dos-lan-drivers-in-w98se/>,
  <https://msfn.org/board/topic/175551-how-to-install-a-rtl-8111e-via-ndis2-driver/>
- **Intel I211 (typowy dla ASRock X470 Taichi/Master SLI/Gaming K4):** brak sterownika 9x;
  wsparcia I211 w Intelowym NDIS2 (E1000.DOS) nie potwierdzono. → dodatkowa karta PCIe
  (RTL8111B/C/D z NDIS5 9x albo dowolny Realtek przez NDIS2) lub USB-Ethernet (wymaga xHCI98).
  Marvell Yukon: sterowniki 9x istnieją, ale „extremely eccentric” (FAQ QuickInstall: używać NDIS2).

---

## 9. ACPI, IRQ, AGESA

- 98 SE instaluje ACPI automatycznie, gdy BIOS jest „ACPI-compliant” i ma datę ≥ 12/1999 (lista
  dobrych/złych BIOS-ów); `/p j` wymusza ACPI, **`/p i` instaluje bez ACPI** (legacy PnP/PCI BIOS).
  <https://www.helpwithwindows.com/windows98/tune-37.html>,
  <https://www.helpwithwindows.com/windows98/start-02.html>
- Współczesne tablice AGESA (ACPI 6.x, AML z nowymi opcode'ami, XSDT, IRQ > 15 przez IOAPIC)
  są poza możliwościami ACPI.SYS z 1999 r. → **zalecany start od `setup /p i`** (i/lub ACPI
  wyłączony tam, gdzie się da). Wtedy routing IRQ zależy od **$PIR** z BIOS-u i od programowania
  PIC (8259) — na AMI CSM X470 obecność sensownego $PIR jest niepewna (CSMWrap generuje $PIR z `_PRT`).
- Objawy z raportu AM4 (B350): BSOD w detekcji sprzętu, po restarcie dalej; **brak „PCI bus”** —
  trzeba ręcznie dodać przez „Dodaj nowy sprzęt”, co odpala 30–40 okien kreatora.
  <https://www.vogons.org/viewtopic.php?t=88508>
- Ryzyka: dzielone IRQ (xHCI/SATA/GPU/HDA) → zawieszenia przy detekcji (QuickInstall #149 oraz FAQ
  i865). Ograniczanie: wyłączyć w BIOS nieużywane kontrolery (drugi SATA/ASMedia, xHCI jeśli jest
  PS/2, HDA jeśli nieużywane, onboard LAN, SR-IOV/IOMMU), Above 4G off, ReBAR off, x2APIC off.
  Zmiany AGESA między wersjami BIOS X470 (np. 1.2.0.x dla Zen 3) mogą zmieniać zachowanie CSM —
  zanotować wersję BIOS w spike'u.
- Ryzen z 16 wątkami: 98 używa jednego; SMT/rdzenie nie przeszkadzają (pod CSMWrap jeden wątek zajęty przez proxy).

---

## 10. Raporty z prawdziwego sprzętu (AM4 i podobne)

| Źródło | Sprzęt | Wynik |
|---|---|---|
| VOGONS t=88508, OMORES, 06.2022 | Ryzen 7 2700, MSI B350M PRO-VDH (tylko PCIe), 7600 GT (82.69), SSD 480 GB **AHCI**, PCIe CMI8738, klawiatura USB, mysz PS/2 | Pulpit, 3D, DX9.0c, gry z lat 90. OK. BSOD w detekcji, ręczne dodanie PCI bus, dysk ograniczony do partycji < 128 GB; USB natywnie brak → karta PCIe VIA VT6212 dała w pełni działający system. |
| VOGONS p=1366349 | „modern system” | Warunki: GeForce 7xxx/Radeon X8xx lub starsze, karta dźwiękowa z 98, sterowniki SATA(AHCI), Loew mem przy > 512 MB, TBPLUS; „działa na Ryzenie”. |
| QuickInstall README/wydania 2026 | „Core Ultra i Ryzen” | Autor deklaruje instalacje na najnowszych Intel/AMD; UEFI bez CSM „very experimental”. |
| QuickInstall issues | 5600G + 8 GB (VCACHE error), H97 + ASM2812 (IRQ 11), EliteDesk 705 G1 (A20/HIMEM) | typowe klasy problemów: CR/VCACHE, IRQ sharing, A20/HIMEM na nowszych CSM. |
| xHCI98 | B550 OK, X570 nie, CPU Ryzen mieszane | USB 2.0 przez xHCI możliwe, ale nie na każdej platformie AMD. |
| VM na Zen 2+ (VOGONS t=68205) | Ryzen 3000 | bez patcha TLB system nieużywalny; po patchu VMM OK. |

Brak znalezionego raportu konkretnie z **X470 + Zen 3** na gołym sprzęcie. To główna luka → spike.

---

## 11. Plan dla USOS

### 11.1 Architektura „ścieżki Win9x”
Dwie gałęzie, bo cele są różne:

**A. Retro PC (MS-7100, BIOS) — rozbudowa istniejącej ścieżki DOS Setup (niskie ryzyko):**
1. (istnieje) Legacy Core → MEMDISK → DOS z ISO użytkownika → FAT32 typu 0C, `SYS`, kopia `WIN98` do `C:\WIN98`.
2. Patcher9x: rozszerzyć `-select mem` o profil sprzętowy: retro = `mem` (+`creg` przy Award? zwykle zbędne);
   „nowoczesny” = `tlb,creg,mem,speed` (+`16m`). Bez zmian: przypięty SHA-256, kopie `RAMBK*`, log.
3. `msbatch.inf` generowany z menu (nazwa, organizacja, klucz produktu **wpisywany przez
   użytkownika w UI**, strefa czasowa, `InstallDir`, komponenty, `EBD=0`, bez ScanDisk):
   `SETUP C:\WIN98\MSBATCH.INF /IS /IE [/P I] [/NM]`.
4. Sterowniki: `DRIVERS\WIN98\<klasa>\...` na DATA/NTFS pendrive'a (dostarczone przez użytkownika).
   USOS kopiuje je do `C:\USOS98\DRV` i INF-y do `C:\WINDOWS\INF` **po pierwszym restarcie Setup**
   (tak jak procedura Loew SATA; wymaga krótkiego etapu DOS/Linux między restartami) albo
   uzupełnia `C:\WIN98` o INF + pliki, by PnP je znalazł podczas detekcji. Mechanizm dokładnej
   ścieżki wyszukiwania INF w 98 (`SourcePath`/`DevicePath`) — **do zweryfikowania w VM**.
5. Po instalacji (RunOnce / etap naprawy USOS): `SYSTEM.INI` (`MaxPhysPage`, `[vcache]`),
   `CONFIG.SYS` (`HIMEM /NUMHANDLES=64`, opcjonalnie CREGFIX), ponowny Patcher9x po aktualizacjach.

**B. X470 (UEFI) — odpowiednik ścieżki XP „UEFI → micro-Linux → CSM”:**
1. Menu UEFI → EFI stub + osobny initramfs `USOS-98` (jak `initramfs-xp`), jawny wybór dysku i
   destrukcyjne potwierdzenie (istniejący workflow).
2. Linux: MBR, partycja 0C od LBA 2048, ≤ 127 GB, w pierwszych 137 GB; `mkfs.fat -F 32`.
3. Sektor rozruchowy DOS 7.1: najczyściej prawnie — kod rozruchowy i `IO.SYS/MSDOS.SYS/COMMAND.COM`
   z **dyskietki El Torito z ISO użytkownika** (USOS już ją czyta). Alternatywa `ms-sys -3`
   (GPL, ale zawiera bajty kodu MS) — niezalecana do pakietu. Najbezpieczniej: zostawić `SYS C:`
   krótkiemu etapowi DOS po restarcie przez CSM.
4. Kopia `WIN98` z ISO (czytnik ISO9660 już jest), Patcher9x w wersji Linux `-auto -select tlb,creg,mem,speed`
   na `C:\WIN98`, `msbatch.inf`, sterowniki z `drivers\win98` (GPU 81.98/82.69 lub Cat 6.2,
   AHCI.PDR+łatki, CMI8738/WDMHDA, NDIS2/NDIS5 NIC, xHCI98+stos USB2 — wszystko user-supplied),
   `CONFIG.SYS/AUTOEXEC.BAT` uruchamiające `SETUP ... /P I` przy pierwszym starcie z dysku.
5. Restart → **natywny CSM X470** (jak XP): Legacy boot dysku docelowego; DOS → Setup → restarty Setup.
   CSMWrap jako opcja tylko dla kart z GOP lub bez CSM — na X470 z GeForce 7 niepraktyczny.
6. Po pierwszym restarcie: podmiana INF/AHCI, `SYSTEM.INI`, ewentualnie Loew SATA/ESDI patch.
7. Wymagane ustawienia BIOS (checklista w UI, bez zmian NVRAM przez USOS): CSM on, Legacy OpROM dla
   VGA/Storage, SATA AHCI, Above 4G off, ReBAR off, x2APIC/IOMMU off, nieużywane kontrolery off, PS/2.

**C. (później, opcjonalnie) Tryb obrazowy à la QuickInstall:** użytkownik raz instaluje 98 w VM
(86Box/QEMU) z własnego CD, USOS wgrywa i „odsprzętawia” obraz. Szybkie, ale duży zakres pracy;
kod QuickInstall jest CC-BY-NC → nie kopiować, co najwyżej wzorować się na idei.

### 11.2 Ograniczenia prawne
- **Nie redystrybuować plików Microsoft**: CAB-y/ISO 98, pliki DOS, **NUSB i stos USB2 SweetLow**
  (zawierają binaria MS), aktualizacje MS (U98SESP3 zawiera pliki MS), DirectX. Wszystko z ISO/folderu użytkownika.
- **Nie redystrybuować sterowników niefree:** NVIDIA 81.98/82.69 (tym bardziej zmodyfikowanych/„leaked”),
  ATI Catalyst, Realtek (NDIS5/NDIS2), C-Media, Creative, Watler HDA (bez licencji),
  AHCI.PDR/PATCH137/SATA Loewa (brak otwartej licencji; rodzina publikuje, ale LICENSE.TXT
  pozostały restrykcyjne), narzędzia SweetLow/LordOfMice (brak licencji).
- **Redystrybuowalne (z licencją i źródłami):** Patcher9x (MIT; z zastrzeżeniem PATCHMEM),
  CSMWrap (LGPL-2.1 + SeaBIOS LGPLv3), CREGFIX (0BSD), WDMHDA (MIT; kod częściowo BSD),
  xHCI98 (GPL-2.0-only — sam .sys wymaga i tak stosu z plików MS), VSBHDA (GPL-2.0), MEMDISK (GPL).
- QuickInstall: CC-BY-NC 4.0 — nie włączać kodu do USOS; jego obrazy referencyjne zawierają Windows.
- Klucz produktu 98 wpisuje użytkownik (nie przechowywać w payloadzie).

### 11.3 Rekomendowana kolejność
1. **Spike ręczny na X470** (bez automatyzacji; osobny SATA SSD, nie dysk z danymi):
   a) BIOS: zanotować wersję/AGESA; CSM on, AHCI, Above4G/ReBAR/x2APIC/IOMMU off, klawiatura+mysz PS/2
      (lub test emulacji USB), GeForce 7800/7900 (256 MB preferowane) lub Radeon X800/X850.
   b) Instalacja istniejącą ścieżką USOS DOS Setup (Legacy boot pendrive'a przez CSM) z ręcznie
      rozszerzonym Patcher9x (`tlb,creg,mem,speed`), `SETUP /P I`, `MaxPhysPage=40000`.
   c) Macierz testów: tryb zgodności int13 vs AHCI.PDR+łatki SweetLow; ACPI vs `/p i`; GPU 81.98/82.69
      vs Catalyst 6.2; audio WDMHDA vs PCIe CMI8738; sieć NDIS2 Realtek (karta PCIe); xHCI98 na obu
      kontrolerach (Promontory i CPU); ewentualnie CSMWrap jako porównanie (z kartą z GOP).
   d) Punkt odniesienia: własnoręcznie zbudowany QuickInstall 1.1.x z własnego ISO — pokaże,
      czy problem leży w sprzęcie, czy w procesie USOS.
   e) Zapisać zdjęcia/logi (`BOOTLOG.TXT`, `DETLOG.TXT`, `SETUPLOG.TXT`) do `docs/evidence`.
2. **Retro PC (MS-7100):** dokończyć weryfikację istniejącej ścieżki do pulpitu (brak potwierdzenia
   w docs), dodać `msbatch.inf` i folder sterowników. Tu automatyzacja ma sens od razu.
3. **Automatyzacja X470** dopiero dla konfiguracji potwierdzonej w spike'u; w menu jako
   „eksperymentalne”, z checklistą BIOS i wymaganymi komponentami (PS/2, GPU z listy, karta audio/NIC).

---

## 12. Główne ryzyka (X470)

1. **ACPI/IRQ/PnP** na AGESA: BSOD w detekcji, brak PCI bus, zawieszenia przy dzielonych IRQ.
2. **Dysk:** brak trybu IDE; tryb zgodności na natywnym CSM może się wysypywać (V86), AHCI.PDR
   community nietestowany na AMD; NVMe tylko przez CSMWrap.
3. **Wejście/USB:** bez PS/2 zależność od SMM-emulacji AMI; xHCI98 nietestowany na X470.
4. **Audio/sieć:** brak PCI; tylko CMI8738 PCIe, eksperymentalne WDMHDA, NIC przez NDIS2/karta.
5. **Pamięć 32 GB / E820 > 4 GiB** — wymaga patchy mem + 4G Res i limitu MaxPhysPage.
6. **GPU bez GOP** wymusza natywny CSM (CSMWrap odpada); sterowniki 82.69 to nieoficjalny mod.
7. **Licencje:** większość kluczowych sterowników jest user-supplied; USOS może jedynie orkiestrację.

## 13. Źródła (zbiorczo)

- CSMWrap: <https://github.com/CSMWrap/CSMWrap>, <https://github.com/CSMWrap/CSMWrap/blob/main/README.md>,
  <https://github.com/FlyGoat/CSMWrap/wiki/Usage-Guide>, <https://github.com/FlyGoat/csmwrap/releases>,
  <https://github.com/mintsuki/csmwrap>, <https://hackaday.com/2025/05/29/bring-back-the-bios-to-uefi-systems-that-is/>,
  <https://www.youtube.com/watch?v=AcSfEvuz8IE>, <https://msfn.org/board/topic/186793-csmwrap-boot-csm-on-uefi-only-systems/>
- SeaBIOS: <https://github.com/coreboot/seabios/blob/master/src/Kconfig>, <https://github.com/coreboot/seabios/blob/master/src/fw/csm.c>
- QuickInstall: <https://github.com/oerg866/win98-quickinstall>, <https://github.com/oerg866/win98-quickinstall/blob/master/README.md>,
  <https://github.com/oerg866/win98-quickinstall/blob/master/BUILDING.md>, <https://github.com/oerg866/win98-quickinstall/releases>,
  <https://github.com/oerg866/win98-quickinstall/releases/tag/v1.1.0>, <https://github.com/oerg866/win98-quickinstall/blob/master/supplement/help.txt>,
  <https://github.com/oerg866/win98-quickinstall/issues/149>, <https://github.com/oerg866/win98-quickinstall/issues/164>,
  <https://github.com/oerg866/win98-quickinstall/issues/165>
- CREGFIX: <https://github.com/mintsuki/cregfix>, <https://somethingnotserious.wordpress.com/2023/11/01/win98-vcache-protection-error-on-modern-hardware/>,
  <https://www.vogons.org/viewtopic.php?t=85763>
- Patcher9x: <https://github.com/JHRobotics/patcher9x>, <https://github.com/JHRobotics/patcher9x/blob/main/README.md>,
  <https://github.com/JHRobotics/patcher9x/releases/>, <https://blog.stuffedcow.net/2015/08/win9x-tlb-invalidation-bug/>,
  <https://www.betaarchive.com/forum/viewtopic.php?t=29224>, <https://www.vogons.org/viewtopic.php?f=24&t=88284>
- R. Loew: <https://rloewelectronics.com/>, <https://rloewelectronics.com/free.htm>,
  <https://rloewelectronics.com/distribute/PATCHMEM/VER7.2/>, <https://rloewelectronics.com/distribute/SATA/1.1a/README.TXT>,
  <https://archive.org/details/PATCHMEM>, <https://archive.org/details/rloewelectronics.com>, <https://archive.org/details/ahci_win9x>,
  <https://www.philscomputerlab.com/rudolph-r-loew-patches.html>, <https://retrosystemsrevival.blogspot.com/2020/06/rloew-9598me-patches-bundle.html>
- SweetLow/LordOfMice: <https://github.com/LordOfMice/Tools>, <https://sweetlow.orgfree.com/download/>,
  <https://msfn.org/board/topic/186313-patches-for-esdi_506pdr-from-98se-terabyte-plus-pack-21-rloews-ahcipdr-and-more/>,
  <https://msfn.org/board/topic/186768-bug-fix-vmmvxd-on-handling-4gib-addresses-and-description-of-problems-with-resource-manager-on-newer-bioses/>,
  <https://msfn.org/board/topic/91336-usb-20-stack-for-win98me/>, <https://www.vogons.org/viewtopic.php?p=1388506>
- USB: <https://github.com/yeokm1/xhci98>
- RAM: <https://dfarq.homeip.net/taming-windows-959898seme-memory-errors/>, <https://www.vogons.org/viewtopic.php?f=61&t=85469>,
  <https://www.vogons.org/viewtopic.php?f=61&t=59229>
- FAT32/dyski: <https://www.helpwithwindows.com/windows98/fat32.html>, <https://www.vogons.org/viewtopic.php?t=44423>
- GPU: <https://toogam.com/software/archive/drivers/videodrv/mswinvid/nvidia/unoffici/nv8269.php>,
  <https://www.vogons.org/viewtopic.php?t=47929>, <https://forums.guru3d.com/threads/drivers-nvidia-geforce-7900-windows-98se.239117/>,
  <https://www.techspot.com/drivers/driver/file/information/2907/>, <https://www.philscomputerlab.com/radeon-9x-drivers.html>,
  <https://www.vogons.org/viewtopic.php?t=54986&start=20>, <https://forums.tomshardware.com/threads/ultimate-windows-98-dos-gaming-pc.2849766/>,
  <https://www.vogons.org/viewtopic.php?f=46&t=44407>
- Audio: <https://github.com/andrew-hoffman/wdmhda>, <http://www.vogons.org/viewtopic.php?p=1358760>,
  <https://retrosystemsrevival.blogspot.com/2019/06/windows-31959898se-hda-driver.html>, <https://github.com/Baron-von-Riedesel/VSBHDA>,
  <https://www.vogons.org/viewtopic.php?t=68642>, <https://dosdays.co.uk/topics/pci_sound_cards_in_dos.php>
- Sieć: <https://www.techspot.com/drivers/driver/file/information/7856/>, <https://msfn.org/board/topic/176892-using-real-mode-aka-dos-lan-drivers-in-w98se/>,
  <https://msfn.org/board/topic/175551-how-to-install-a-rtl-8111e-via-ndis2-driver/>
- ACPI/Setup: <https://www.helpwithwindows.com/windows98/tune-37.html>, <https://www.helpwithwindows.com/windows98/start-02.html>,
  <https://msfn.org/board/topic/26389-how-to-95-and-98-setup-answer-file/>, <https://www.vogons.org/viewtopic.php?t=53765>
- Raporty sprzętowe: <https://www.vogons.org/viewtopic.php?t=88508>, <https://www.vogons.org/viewtopic.php?p=1366349>,
  <https://www.vogons.org/viewtopic.php?t=66367>, <https://www.vogons.org/viewtopic.php?t=68205>, <https://www.vogons.org/viewtopic.php?t=82383>
- MS-7100: <https://theretroweb.com/motherboards/s/msi-k8n-neo4-sli-platinum-ms-7100-v3.x>

### Nie zweryfikowane (do spike'u / VM)
- $PIR i SMM-emulacja USB w AMI CSM konkretnego BIOS-u X470; GOP przez CSM-video dla GeForce 7.
- AHCI.PDR (+łatki) na AMD FCH/Promontory; xHCI98 na X470 i Matisse.
- Dokładny mechanizm wyszukiwania OEM INF przez Setup 98 (w VM przed automatyzacją).
- NDIS2 Intela dla I211; sterownik AC'97 dla nForce4 (ALC850) pod 98 SE na MS-7100; wariant LAN MS-7100.
