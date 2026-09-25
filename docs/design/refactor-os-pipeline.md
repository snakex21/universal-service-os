# Refaktor: wspólny pipeline systemów operacyjnych (projekt, 2026-09-24)

Stan: **M0–M3 zrobione, M4 zrobione w QEMU (czeka na test na X470)** na gałęzi `refactor/os-pipeline` (2026-09-25),
bez zmiany zachowania. Pozycja N2 w [ROADMAP.md](../ROADMAP.md).

Postęp:
- M0: `src/flow/testdata/routing_golden.tsv` (tabela prawdy, `USOS_UPDATE_GOLDEN=1
  zig build test`), dokładna linia poleceń BIOS, `tools/tests/golden/staged_payloads.py`
  (odciski initramfs, pakietu XP UEFI-CSM z `zig-out`, archiwów WinPE, `WINNT.SIF`),
  `check_xp_pae.py` bez sticka.
- M1: `src/catalog/os_profiles.zig` (cechy systemów + uporządkowane reguły);
  rozstrzyganie, polityki, podsumowanie i `e2e_flow` pytają profil.
- M2: `src/flow/plan.zig`: plan (klucze `plan_*` w `install-state.ini`, na razie
  nieczytane przez mikro-Linuksa), etapy postępu z profilu na ekranach UEFI,
  `WimbootPlan` (lista plików RAM-dysku wimboot, wykonywana przez
  `windows_native_iso.zig`, log `[WIMBOOT_PLAN]`). Odłożone: plan w linii poleceń
  BIOS (`usos.plan_hex`), bo nikt go nie czyta przed M3, a linia poleceń XP BIOS
  jest potwierdzona na sprzęcie.
- M3: `tools/pipeline/run.sh` + kroki `steps/100_nt5_staging.sh`,
  `150_nt5_resume.sh`, `500_windows_pe_bios_request.sh` (dawne gałęzie `case`
  z `micro_linux_init.sh`, przeniesione bez zmian); krok 200 = ciało WORK
  w `/usos-init`. Profil: token `usos.plan_profile=` (Core BIOS i launcher XP
  UEFI), inaczej tabela akcji; ścieżka WORK sprawdza klucze `plan_*`
  z `install-state.ini` (brak planu = starsze menu, akceptowane). Zamiast
  `usos.plan_hex` jest sam identyfikator profilu, bo kroki wynikają z tabeli
  w `run.sh`. Niezmiennik „guard przed zapisem” pilnują na razie same skrypty
  (kroki są grube); sprawdzanie kolejności w `run.sh` dopiero przy rozbiciu
  kroków. Uwaga: zmiana `usos-init` zmienia bazę pakietu XP UEFI-CSM, więc
  po scaleniu trzeba go przebudować (M4 usuwa tę zależność).
- M4 (QEMU): skrypty NT5 same obsługują profil `xp-x86-sp3-uefi-csm`
  (`USOS_PLAN_PROFILE`): ścieżki `EFI/USOS-XP`, geometria 255/63, preflight
  i integracja sterowników, PAE, weryfikacja read-only,
  `xp_selected_partition_uefi_csm.sif`; `build_xp_uefi_csm_trial.py` tylko
  **dodaje** pae.exe, licencję i pakiety sterowników do bazy
  (`--micro-linux`, domyślnie `zig-out/micro-linux`), bez sticka; launchery
  per ISO usunięte. Kryterium: `tools/tests/target_digest.py` — dysk
  przygotowany przez pakiet M4 identyczny z baseline (UEFI-CSM 7009 plików),
  profil BIOS NT5 identyczny przed/po (6976 plików), pakiet PL powtarzalny
  i 0 niewyjaśnionych różnic względem wdrożonego; pakiet EN (x14-80428)
  zbudowany tą samą metodą, tryb tekstowy do kopiowania
  ([../research/xp-package-language-2026-09-25.md](../research/xp-package-language-2026-09-25.md)).
  Odłożone: pakiet w `payload.zip` (pakiety sterowników zależą od ISO
  użytkownika; zgodnie z decyzją 2026-09-25 PL jest gotowy, inne ISO
  zbuduje instalator po porcie do Go); drugi wpis „XP (poprzedni pakiet)”.
  Wymagany test na X470 (czysta instalacja, PAE) przed scaleniem.
Powiązane: [answer-file-generator.md](answer-file-generator.md),
[nt5-uefi-family.md](nt5-uefi-family.md), [drivers.md](../drivers.md),
[BOOT_FLOW.md](../../BOOT_FLOW.md), [ARCHITECTURE.md](../../ARCHITECTURE.md).

Zasady nadrzędne (z `PROJECT_RULES.md` i praktyki projektu):

1. **Ścieżki potwierdzone na sprzęcie nie zmieniają zachowania** w żadnym
   kroku refaktoru, dopóki nie zostaną ponownie potwierdzone. Dotyczy to
   szczególnie XP UEFI-CSM + PAE (X470, 31,9 GB), Windows 10/11 UEFI
   z unattended, Vista na X470, XP/2000/7/98/DOS/10 x86 na MS-7100,
   dotyku i Secure Boot na Ally.
2. **Opakować, nie przepisywać.** Sprawdzone skrypty i binaria (pakiet XP,
   `pae.exe`, finalizator WinPE, pomocniki Visty, bootstrap NT52,
   MBR Strategy B) stają się krokami pipeline'u bez zmiany bajtów.
3. **Profile są danymi.** Menu, mikro-Linux i WinPE nie porównują
   `system.id`; pytają profil.
4. **Każdy krok migracji: pełny build, wszystkie testy zielone, cyfrowe
   „odciski” wyjścia niezmienione** (sekcje 3–5).

## 1. Stan obecny

### 1.1 Mapa ścieżek

Rozstrzyganie: `src/flow/preparation_capability.zig`
(`resolveForFirmware` → `Backend`), potem gałęzie w
`src/platform/uefi/manual_summary.zig` (`show`/`start`) albo
`src/platform/bios/legacy_boot_actions.zig`.

| Ścieżka | Firmware | Backend | Kto wykonuje | Kluczowe moduły | Dowód |
|---|---|---|---|---|---|
| **XP SP3 x86 UEFI-CSM + PAE** | UEFI (+CSM do instalacji) | `xp_uefi_staging` | menu → `EFI/USOS-XP/vmlinuz.efi` + `initramfs-xp` → skrypty NT5 → rozruch dysku przez CSM | `uefi/xp_preparation.zig`, `tools/build_xp_uefi_csm_trial.py` (podmiany tekstu w skryptach BIOS), `xp_driver_overlay.py`, `xp_cab.py`, `xp_hive.py`, `xp_driver_stage.sh`, `windows_xp_pae.c`, `xp_verify_target.sh`, `deploy_xp_uefi_csm_trial.ps1` | X470, czysta instalacja, PAE 31,9 GB |
| **XP / 2000 BIOS** | BIOS | `xp_staging` | Core → loader Linuksa → `micro_linux_init.sh` → `legacy_xp_staging.sh` | `bios/linux_boot_params.zig` (inwentarz INT13 w cmdline), `nt5_profile.sh`, `probe_nt5_source.sh`, `prepare_xp_target.sh`, `prepare_xp_ntfs_target.sh`, `prepare_xp_local_source.sh`, `prepare_xp_windows_partition.sh`, `xp_menu_ui.sh`, `xp_disk_*`, `target_disk_guard.sh`, `bios/xp/*.S` | MS-7100 (XP, 2000), VirtualBox |
| **XP BIOS + własny SIF** | BIOS | `xp_staging` | jw. + partycja XPSETUP FAT32 + `CONTINUE XP` (`legacy_xp_resume.sh`) | `prepare_xp_target.sh:282-413` | VM |
| **Vista/7 direct ISO (UEFI)** | UEFI | `windows_iso` | menu czyta ISO z DATA, wimboot + WinPE (stock PE7 albo PE10 donor), pliki USOS wstrzyknięte do RAM | `uefi/windows_native_iso.zig`, `wimboot_files.zig`, `windows_driver_files.zig`, `windows_user_drivers.zig`, `image_probe/wim_setup.zig` + `windows7_pe_rules.tsv`; WinPE: `windows_iso_startup.cmd`, `windows7_*_startup.cmd`, `windows_vista_modern_startup.cmd`, `windows_setup_launcher.c`, `windows_unattend_drivers.c`, **finalizator** `windows7_uefi_finalize.c`, UefiSeven | Win7: QEMU pełna instalacja, X470 niepotwierdzone; Vista: X470 (v11) |
| **Vista USB install (X470)** | UEFI | `windows_iso` (Vista, PE10) | jw. + `windows_vista_install.c` (własna odpowiedź serwisowa, weryfikacja hashy), `windows_vista_firstboot.c`, `windows_vista_oobe_*` | `tools/windows_vista_*.c`, `build_windows_vista_support.py` | X470 (sukces sprzętowy v11) |
| **Vista / 10 x86 BIOS ISO** | BIOS | `windows_bios_iso` | Core sam: pliki startowe z ISO na DATA → wimboot → WinPE → to samo ISO przez ImDisk (bez mikro-Linuksa) | `bios/windows_native_iso.zig`, `windows_wimboot.zig`, `windows_iso_config.zig`, `windows_source_mount.c` | Vista i 10 x86 MS-7100 |
| **7 BIOS ISO** (ten sam backend) | BIOS | `windows_bios_iso` | Core → mikro-Linux → `legacy_windows_request.sh` (akcja `windows7-iso`) → `prepare_work.sh` → kexec wimboot (`windows_bios_handoff.sh`) | `bios/linux_load_probe.zig` (`runWindowsIso`), `legacy_boot_actions.zig` (gałąź po `system_id`) | MS-7100 (użytkownik, 2026-09-10) |
| **8/10/11 przez WORK (UEFI)** | UEFI | `windows_iso` (11) / `chainload` (10, 8) | menu zapisuje `phase=prepare-requested` (`persistent_state_file.zig`), `BootNext` → systemd-boot → mikro-Linux → `prepare_work.sh` → `extract.sh` → restart → handoff `bootmgfw.efi` z WORK przez EfiFs | `uefi/e2e_flow.zig`, `boot_next.zig`, `work_chainload.zig`, `ntfs_driver.zig`; `device_guard.sh`, `work_boot_relocate.sh`, `driver_stage.zig` (`$WinPEDriver$`) | Win10/11 UEFI + unattended (użytkownik) |
| **Linux ISO / inne ISO (UEFI)** | UEFI | `chainload` | ta sama ścieżka WORK: rozpakowanie ISO i start `\EFI\USOS-WORK\BOOTX64.EFI` | `extract.sh`, `work_boot_relocate.sh` | QEMU |
| **SliTaz Live (BIOS)** | BIOS | `linux_live_iso` | Core ładuje jądro + warstwy RAM z ISO | `bios/linux_live_iso.zig` | sprzęt |
| **EFI z `Images`** | UEFI | `direct_efi` | `esp_image_start.zig` | – | QEMU |
| **WIMBoot / VHDBoot** | UEFI (BIOS WIM 10) | `wimboot` / `vhdboot` | mikro-Linux → `prepare_wimboot.sh` / `prepare_vhdboot.sh` (szablony z instalatora `winhost`) | – | QEMU |
| **98 SE DOS Setup** | BIOS | `win9x_dos` | tylko Core: FAT16 w RAM z dyskietki El Torito, FAT32 na celu, MEMDISK, filtr INT13, Patcher9x `mem`, `SETUP /IS` | `bios/dos_*.zig`, `dos_disk_filter.S`, `dos_target_ui.zig` | MS-7100, QEMU |
| **MS-DOS / Win 3.x, FreeDOS, Memtest, Hardware** | BIOS | `dos_bios_iso` + wpisy Utilities | Core / mikro-Linux (`hardware_ui.sh`) | `bios/dos_*.zig`, `freedos_tools.zig`, `memtest_*.zig` | MS-7100, QEMU |

Instalator Go (host Windows) jest osobnym światem: tworzy ESP/DATA/WORK,
payload, katalog `DATA`, szablony WIM/VHD, integrację Win7
(`install/win7inject.go`), klasyfikację nośnika (`winmedia`), i18n
(`usos-i18n-gen` generuje tabele dla Zig, C i ini).

### 1.2 Co robi każda ścieżka, w języku etapów

`✓` = etap istnieje, `–` = brak, `½` = częściowo.

| Etap | XP UEFI-CSM | XP/2000 BIOS | Vista/7 UEFI ISO | 8/10/11 WORK | 98 BIOS |
|---|---|---|---|---|---|
| detect (profil z nośnika) | ½ (nazwa pliku + `WIN51IP.SP3`) | ✓ `probe_nt5_source.sh` | ✓ `wim_setup.zig` + TSV | ½ (tylko z katalogu) | ✓ (El Torito + `WIN98`) |
| validate media | ✓ (hash źródła bundla) | ✓ | ✓ | ✓ (liczba plików, bajty) | ✓ |
| prepare target | ✓ (guard, plan, MBR/NTFS) | ✓ | – (Setup) | ✓ (WORK: guard, mkfs, marker) | ✓ (FAT32, MBR) |
| drivers (bundled + user) | bundled | – | bundled + user | user (`$WinPEDriver$`) | – |
| fixups | ✓ (ACPI, CrashDump, PAE) | – | ✓ (UefiSeven, int10, KMDF, finalizator) | ✓ (relokacja `\EFI\BOOT`) | ✓ (Patcher9x) |
| answer file | stały SIF + dopiski | SIF / własny SIF | kopia / scalanie `DriverPaths` | kopia 1:1 | – |
| localized messages | ✓ (`boot.lx.*`, `lang-xp.ini`) | ✓ | ✓ (`lang-winpe.ini`) | ✓ | ✓ (Core, `bios-ui.bin`) |
| verify | ✓ (readback, zero-file) | ½ (readback) | ½ | ✓ (`cmp`, liczniki) | ½ |
| hand-off | wyłączenie + CSM | wyłączenie | Setup w WinPE | `BootNext` + bootmgr | `SETUP /IS` |

### 1.3 Duplikacja i punkty bólu

1. **XP UEFI-CSM to fork przez podmiany tekstu.** `build_xp_uefi_csm_trial.py`
   (`replace_once`, globalna zamiana `EFI/USOS/` → `EFI/USOS-XP/`,
   wycięcie bloku geometrii między dwoma komentarzami w
   `legacy_xp_staging.sh`) tworzy wariant skryptów BIOS. Zmiana
   w pobliżu kotwicy po cichu zmienia ścieżkę potwierdzoną na sprzęcie
   albo psuje build.
2. **Pakiet XP budowany z bazy na pendrivie** (`J:/EFI/USOS/micro-linux`)
   i **nie dostarczany przez instalator** (brak `USOS-XP` w Go). Każda
   zmiana mikro-Linuksa = ręczny pełny rebuild XP i wdrożenie
   `-DriversOnly` (pięć razy 24.09). `check_xp_pae.py` porównuje z `J:`,
   więc przechodzi dopiero po aktualizacji sticka.
3. **Decyzje rozproszone jako porównania napisów:** `system.id` w
   `preparation_capability.zig` (`nativeLegacyNt`, `is_xp`, kilkanaście
   `std.mem.eql`), `manual_summary.zig` (Vista/7),
   `bios/legacy_boot_actions.zig` (Vista/10 natywnie w Core, 7 przez
   mikro-Linux w tym samym backendzie), `unattended_policy.zig`
   (`.sif` dla xp/2000), `secure_boot_policy.zig`; w WinPE pliki-flagi
   (`usos-modern-vista.flag`, `usos-modern-win7.flag`,
   `usos-stock-win7.flag`); w mikro-Linuksie `usos.legacy_action=` i
   `NT5_SYSTEM`. Dodanie systemu wymaga zmian w 5–8 miejscach w 3 językach.
4. **Dwa różne rozstrzygnięcia:** `manual_summary` używa
   `resolveForFirmware`, a `e2e_flow.requestPreparation` waliduje
   i rozstrzyga ponownie przez `resolve`/`validate` bez firmware.
5. **Polityki bezpieczeństwa tylko na jednej ścieżce:**
   `xp_verify_target.sh` (zero-file), `CrashDumpEnabled=0`, sterowniki
   text mode istnieją tylko w XP UEFI-CSM; XP BIOS ich nie ma.
6. **Linia poleceń i handoff XP zbudowane dwa razy** (`xp_preparation.zig`
   i przestarzałe launchery per ISO w `build_xp_uefi_csm_trial.py`, z innymi
   opcjami, nadal budowane i hashowane). Kodowanie hex nazw w Zig
   dwukrotnie, dekodowanie w shellu.
7. **`winnt.sif` z trzech źródeł** (heredoc w `prepare_xp_local_source.sh`,
   który i tak zostaje nadpisany, plik `xp_selected_partition.sif`,
   dopiski w Pythonie); `UserExecute="C:\USOS\XP\pae.exe"` jako literał.
8. **Wykrywanie SP3 na trzy sposoby** (nazwa pliku w buildzie, znacznik
   w overlay, znacznik w runtime).
9. **Listy plików ręcznie w kilku miejscach:** payload w
   `usos-payload-pack/main.go` i w `verify_release_consistency.ps1`,
   odcisk źródeł w `generate_build_info.ps1`, skrypty initramfs w
   `build_micro_linux.py`. `payload.zip` niedeterministyczny (czasy
   plików w nagłówkach ZIP), świeżość sprawdzana po `mtime`.
10. **`tools/` płaskie:** 281 pozycji, ok. 145 jednorazowych
    `*vista*`/`*xp*` (inspect/deploy/wait/snapshot); 36 z 52 skryptów
    `deploy_*`/`prepare_vista_*`/`inspect_vista_*`/`wait_vista_*`/
    `snapshot_*`/`repair_*` nie jest nigdzie używanych. Skrypty
    produkcyjne initramfs leżą obok nich.
11. **Martwy lub nieaktualny kod:** auto-chainload `xp_target_chainload.zig`
    (marker jest zawsze usuwany), komentarz o CSMWrap w
    `secure_boot_policy.zig` (XP używa CSM firmware), `XpStagingRequest`
    używany przez Win7/Vista BIOS, nazwa `vmlinuz-virt` dla jądra LTS.
12. **Postęp:** etapy są już deklarowane per ścieżka
    (`usos_ui_declare_stages`, `preparation_screen.State.labels`), ale
    listy są wpisane ręcznie w skryptach i Zig, nie wynikają z tego, co
    ścieżka faktycznie wykona.

## 2. Cel: etapy, kroki, profile

### 2.1 Etapy

Stała, uporządkowana lista (etap może być pusty w profilu):

```
detect → validate_media → prepare_target → drivers → fixups →
answer_file → messages → verify → handoff
```

`messages` to etap kontraktu, a nie osobny proces: każdy krok ma klucz
i18n dla etykiety postępu i komunikatów końcowych; etap `messages`
dostarcza pliki językowe do środowisk docelowych (`lang.cpio`,
`lang-xp.ini` → `pae-strings.ini`, `lang-winpe.ini`) i ekran
„co teraz zrobić” (np. „nie naciskaj klawiszy do kreatora”).

### 2.2 Kroki i wykonawcy

Etap składa się z **kroków**. Krok ma jednego wykonawcę, bo kod nie może
przekraczać granic środowisk:

| Wykonawca | Język | Przykłady kroków |
|---|---|---|
| `menu_uefi` | Zig (freestanding) | detect WIM, archiwum sterowników, wimboot, `BootNext` |
| `menu_bios` | Zig i386 (Core) | 98 DOS Setup, FreeDOS, SliTaz |
| `micro_linux` | shell + `usos-fb-ui` (Zig) | guard, mkfs, extract, staging NT5, driver stage, zero-file |
| `winpe` | C (bez CRT) + cmd | uruchomienie Setup, scalanie `DriverPaths`, finalizator |
| `target_firstboot` | C (x86 PE) | `pae.exe`, pomocniki Visty |
| `host` | Go | szablony WIM/VHD, integracja Win7, zapis towarzyszy |

### 2.3 Typy w Zig (`src/flow/pipeline/`)

```zig
pub const Stage = enum(u4) {
    detect, validate_media, prepare_target, drivers, fixups,
    answer_file, messages, verify, handoff,
};

pub const Runner = enum(u3) { menu_uefi, menu_bios, micro_linux, winpe, target_firstboot, host };

/// Stable identifiers: persisted in the plan file and in logs, never renumbered.
pub const StepId = enum(u16) {
    nt5_probe_source = 100, nt5_driver_preflight, nt5_disk_menu, nt5_guard_snapshot,
    nt5_partition_plan, nt5_format_ntfs, nt5_local_source, nt5_driver_overlay,
    nt5_windows_partition, nt5_pae_payload, nt5_verify_target, nt5_poweroff,
    work_guard = 200, work_format, work_marker, work_extract, work_relocate_boot,
    work_stage_user_drivers, work_copy_answer, work_sync, work_handoff,
    wim_inspect = 300, wim_driver_archive, wim_inject, wim_start,
    dos98_source = 400, dos98_target, dos98_patcher, dos98_setup,
    // ...
};

pub const Step = struct {
    id: StepId,
    stage: Stage,
    runner: Runner,
    label: i18n.Key,          // progress row text
    weight: u8 = 1,           // share of the progress bar
    interactive: bool = false, // disk menus: progress pauses
    proven: ?Proven = null,   // byte-identity contract, section 3
};

pub const Proven = struct {
    artifact: []const u8,     // "pae.exe", "xp-driver-bundle/<source sha>", "xp_selected_partition.sif"
    sha256: [32]u8,
    evidence: []const u8,     // "X470 2026-09-23 clean install, PAE 31.9 GB"
};

pub const FirmwareMask = packed struct { bios: bool, uefi: bool, uefi_csm_target: bool = false, uefi_csmwrap_target: bool = false };

pub const Verification = enum { hardware, vm, experimental, unverified };

pub const Profile = struct {
    id: []const u8,                   // "xp-x86-sp3-uefi-csm", "win11-work", "win7-uefi-pe10", "win98se-dos"
    system_id: []const u8,            // catalog entry
    image: ImageKinds,                // accepted ImageKind set
    methods: []const BootMethod,      // methods that select this profile
    firmware: FirmwareMask,
    media: MediaMatch,                // rules evaluated by detect (files, WIM version, markers)
    steps: []const Step,
    answer: AnswerFormat,             // .none, .winnt_sif, .unattend_txt, .autounattend_xml, .msbatch_inf
    user_answer: UserAnswerPolicy,    // .copy_verbatim, .merge, .refused
    drivers: DriverPolicy,            // bundled bundle id, user folder, classes used in Setup
    secure_boot: enum { allowed, requires_off },
    verified: Verification,
    notes: []const i18n.Key = &.{},   // summary notes (CPU count, BIOS checklist, ...)
};
```

Tabela profili (`src/catalog/os_profiles.zig`) jest danymi comptime.
Rozstrzyganie:

```zig
pub fn select(system: *const SystemEntry, image: ImageKind, method: BootMethod,
              firmware: Firmware, media: ?*const MediaFacts) ?*const Profile
```

`MediaFacts` to wynik `detect` (wersja/arch WIM, znaczniki NT5,
dyskietka El Torito…), dostępny w UEFI przed podsumowaniem; bez niego
(BIOS, gdzie detekcja NT5 dzieje się w mikro-Linuksie) wybór jest
wstępny, a mikro-Linux może **zawęzić** profil w obrębie tej samej
rodziny (np. XP x86 → XP x64), nigdy przejść do innej.

`preparation_capability.resolveForFirmware` zostaje jako cienka funkcja
nad `select` (zwraca `profile.backend()`), dopóki wszyscy wywołujący
nie przejdą na profil.

**Postęp z profilu:** ekran postępu (UEFI, Core, `usos-fb-ui`) rysuje
wyłącznie etapy, które mają co najmniej jeden krok w profilu, z wagami
kroków. Zastępuje to ręczne listy z
`usos-boot-ui-quiet-and-stages-2026-09-22.md` (5 etapów mikro-Linuksa,
3 dla Vista/7 ISO, 1 dla wznowienia XP).

### 2.4 Plan: jak profil przechodzi między środowiskami

Menu nie przekazuje już `usos.legacy_action=xp-staging`, flag
i `NT5_SYSTEM` osobno. Zapisuje **plan** (rozszerzenie istniejącego
pliku stanu `persistent_state_file.zig`, który już niesie fazę, obraz,
plik odpowiedzi, metodę i `system.id`):

```ini
[plan]
version=1
profile=xp-x86-sp3-uefi-csm
system=windows-xp
image=\Systems\Windows\Windows XP\Images\<iso>
answer=generated:EFI\USOS\answers\last-windows-xp.ini   ; albo user:<ścieżka>, albo none
firmware=uefi
steps=100,101,102,103,104,105,106,107,108,109,110,111
stage_labels=boot.stage.check|boot.stage.disk|boot.stage.copy|boot.stage.verify|boot.stage.finish
```

W BIOS plan jest przekazywany tak jak dziś inwentarz dysków: w linii
poleceń jądra (`usos.plan_hex=...`, limit długości sprawdzany testem)
albo w małym pliku na ESP. Linia poleceń ma pierwszeństwo tylko do czasu
N6 (UKI bez edycji cmdline, patrz roadmapa), potem wyłącznie plik.

### 2.5 Mikro-Linux: kontrakt kroku

```sh
# tools/pipeline/run.sh (in initramfs: /usr/lib/usos/pipeline/run.sh)
usos_pipeline_run PLAN_FILE
#  - reads [plan], checks every step id is known to this initramfs,
#  - declares the stage labels (usos_ui_declare_stages),
#  - runs /usr/lib/usos/steps/<id>.sh in order.

# tools/pipeline/steps/106_nt5_local_source.sh
usos_step_106_run() {        # contract: 0 = done, 1 = failed (message already shown), 2 = cancelled by user
    usos_ui_stage "$USOS_STAGE_COPY" ...
    prepare_xp_local_source "$@"   # the existing, unchanged function
}
```

Kroki są cienkimi adapterami nad **istniejącymi** funkcjami
(`prepare_xp_local_source.sh`, `prepare_work.sh`, `extract.sh`,
`xp_driver_stage.sh`, `xp_verify_target.sh`, `device_guard.sh`…).
Kolejność destrukcyjna z `BOOT_FLOW.md` (guard → format → marker →
mount → extract/verify/sync → prepared) jest **niezmiennikiem**
sprawdzanym przez `run.sh`: plan, w którym krok zapisujący stoi przed
krokiem guard, jest odrzucany przed wykonaniem czegokolwiek.

### 2.6 WinPE

Pliki-flagi (`usos-modern-win7.flag`, …) są zastępowane jednym
`usos-plan.ini` wstrzykiwanym przez wimboot (ten sam format sekcji
`[plan]`), czytanym przez `windows_setup_launcher.c`. Skrypty `.cmd`
zostają; zmienia się tylko wybór gałęzi. Do czasu kroku M5 flagi są
generowane **z planu** (ten sam plik wyjściowy co dziś), więc WinPE nie
zmienia się wcale.

### 2.7 Go (instalator)

Instalator nie wykonuje pipeline'u, ale zna profile w trzech miejscach:
foldery `DATA` (`winhost/data_layout.go`, `windowsProfiles`), szablony
WIM/VHD i integracja Win7. Zamiast drugiej tabeli ręcznej:

```go
// installer/internal/profiles/profiles.go (generated or checked against src/catalog/os_profiles.tsv)
type Profile struct {
    ID          string
    SystemID    string
    Folder      string   // Systems\Windows\<Folder>
    DriverDir   string   // Drivers\<Folder>
    AnswerExt   []string // ".xml", ".sif", ".inf"
    Verified    string
}
```

Źródłem prawdy dla danych współdzielonych jest plik
`src/catalog/os_profiles.tsv` (kolumny: id profilu, system, folder,
rozszerzenia odpowiedzi, folder sterowników, weryfikacja), czytany przez
test Zig i test Go, dokładnie jak `src/image_probe/windows7_pe_rules.tsv`
z `windows7_pe_rules_test.zig` i `pe_rules_agreement_test.go`. Generator
(`usos-profile-gen`, wzorem `usos-i18n-gen`) dopiero gdy ręczne
utrzymanie dwóch stron okaże się kłopotliwe.

## 3. Sprawdzone elementy: opakowanie z zachowaniem bajtów

| Element | Dowód | Jak zostaje zachowany |
|---|---|---|
| Pakiety sterowników XP (bundle per SHA-256 źródła), hive'y, kabinety | X470; `compare_xp_packages.py` (755 identycznych) | Budowane **tym samym kodem** (`xp_driver_overlay.py`, `xp_cab.py`, `xp_hive.py`); krok `nt5_driver_overlay` tylko wywołuje `xp_driver_stage.sh`. `Proven.sha256` = `payload.sha256` bundla |
| `pae.exe` v4 (`bab558bb…`) + `pae-strings.ini` | X470, 31,9 GB | Plik binarny wersjonowany jak dziś; krok `nt5_pae_payload` kopiuje i `cmp`; zmiana tylko w nowym profilu (np. `/switch-only` dla 2003) z nowym hashem |
| `xp_selected_partition.sif` + dopiski PAE | X470 | Do M5: render z generatora musi dać **identyczny** `WINNT.SIF` dla pustego formularza (test bajtowy) |
| Bootstrap NT52 (EDD), MBR Strategy B (440 B), `xp-nt52-ntfs.bin` | MS-7100, X470 | Bez zmian; `verify_release_consistency.ps1` już pilnuje MBR |
| Finalizator WinPE Win7 (`windows7_uefi_finalize.c`), UefiSeven, int10 | QEMU (pełna instalacja UEFI); X470 niepotwierdzone | Binaria WinPE z hashami w manifeście wsparcia; krok `wim_inject` pakuje te same pliki |
| Pomocniki Visty (v10/v11, CAT, odpowiedź serwisowa) | X470 | `windows_vista_install.c` weryfikuje payload hashami już dziś; profil Vista wskazuje ten sam zestaw |
| `prepare_work.sh`/`extract.sh`/`device_guard.sh` | 10/11 UEFI (użytkownik) | Wywoływane w całości jako kroki `work_*`; rozbicie na mniejsze kroki dopiero po M3, z porównaniem zawartości WORK |
| Ścieżka 98 w Core | MS-7100 | Kroki `menu_bios` wywołują istniejące funkcje `dos_*.zig`; zapas Core 43 KiB mierzony w każdym buildzie |

Dla elementów, które **muszą** się zmienić (skrypty XP po usunięciu
podmian tekstu), kryterium jest **identyczność wyniku na dysku
docelowym**, a nie identyczność skryptów: ten sam ISO + pusty dysk w
QEMU → ta sama lista plików i hashy na przygotowanej partycji (bez
znaczników czasu NTFS), ten sam MBR/VBR, ten sam `WINNT.SIF`,
`TXTSETUP.SIF`, `MIGRATE.INF`. Narzędzie: `tools/tests/target_digest.py`
(nowe; mountuje obraz tylko do odczytu i zapisuje manifest).

## 4. Migracja: małe, bezpieczne kroki

Każdy krok: osobny commit (albo kilka), `build.bat` + `tools/tests/run.ps1
-Suite all` zielone, odciski z M0 niezmienione, chyba że krok jawnie
mówi inaczej.

**M0. Siatka bezpieczeństwa (2–3 dni, zero zmian zachowania).**
- Tabela prawdy rozstrzygania: test Zig generuje wynik
  `resolveForFirmware` dla całego iloczynu *system × ImageKind ×
  BootMethod × firmware* i porównuje z zapisanym plikiem
  `testdata/routing_golden.tsv`.
- Odciski: pakiet XP (`compare_xp_packages.py` jako test, baza z
  `zig-out/micro-linux`, nie z `J:`), `target_digest` dla XP UEFI-CSM
  i XP BIOS (harness `run_seabios_xp_uefi_csm_textmode.py`), zawartość
  WORK po przygotowaniu Win11 w QEMU, lista plików wstrzykiwanych przez
  wimboot dla Win7 PE7/PE10 i Visty, obraz FAT16 98 w RAM.
- Naprawić testy zależne od sticka: `check_xp_pae.py` (izolacja bazy
  względem `J:`), `check_xp_driver_integration.py`.

**M1. Profile jako dane (2–3 dni).** `os_profiles.zig`, `select()`;
`resolveForFirmware` i `resolve` jako wrappery; `manual_summary.zig`,
`secure_boot_policy.zig`, `unattended_policy.zig` pytają profil zamiast
`system.id`; `e2e_flow.requestPreparation` używa tego samego wyboru co
podsumowanie. Kryterium: `routing_golden.tsv` bez zmian.

**M2. Plan i postęp z profilu (2 dni).** Plik planu (rozszerzony
`persistent_state_file`), BIOS przez cmdline; etykiety etapów z profilu
na wszystkich trzech ekranach postępu. Zmiana widoczna tylko w UI
(te same etapy co dziś, bo profile odzwierciedlają dzisiejsze ścieżki).
Przy okazji: błąd zatrzymującego się zegara na ekranach postępu (stara
roadmapa pkt 6).

**M3. Kroki w mikro-Linuksie (2–3 dni).** `pipeline/run.sh` + adaptery
kroków nad istniejącymi skryptami; `micro_linux_init.sh` wywołuje
`run.sh` zamiast `case` po `usos.legacy_action` (stare akcje mapowane na
profile przez jedną tabelę, żeby BIOS Core bez zmian działał dalej).
Kryterium: odciski WORK i XP BIOS bez zmian.

**M4. Pakiet XP z repo, bez podmian tekstu (4–5 dni + sprzęt).**
- Różnice UEFI-CSM (geometria kanoniczna, preflight sterowników, PAE,
  `xp_verify_target`, ścieżki `EFI/USOS-XP`) stają się krokami profilu
  `xp-x86-sp3-uefi-csm`, a nie edycjami tekstu.
- `build_xp_uefi_csm_trial.py` buduje z `zig-out/micro-linux`;
  przestarzałe launchery per ISO usunięte; pakiet trafia do
  `payload.zip` (instalator go dostarcza), `deploy_xp_uefi_csm_trial.ps1`
  zostaje dla testów.
- Kryterium: `target_digest` XP UEFI-CSM identyczny; potem **ponowny
  test na X470** (czysta instalacja, PAE). Do potwierdzenia stary pakiet
  zostaje na ESP jako drugi wpis „XP (poprzedni pakiet)”.

**M5. Etap odpowiedzi i towarzysze (3–4 dni).** Render z pustego
formularza = dzisiejsze pliki bajt w bajt (XP `WINNT.SIF`, kopia 1:1
dla 10/11); WinPE czyta `usos-plan.ini`, flagi usunięte.

**M6. Wspólne verify i utwardzenie per profil (2–3 dni + sprzęt).**
`verify` (readback, flush, zero-file) jako kroki dostępne dla każdego
profilu z celem NTFS/FAT; włączenie dla XP BIOS i 2000 to **zmiana
zachowania**: osobny profil-wersja, test MS-7100.

**M7. Porządek (1–2 dni).** Jednorazowe skrypty (`deploy_vista_*`,
`inspect_*`, `wait_*`, `snapshot_*`, 36 nieużywanych) do
`tools/archive/` z README; produkcyjne skrypty initramfs do
`tools/micro-linux/`; jedna lista plików payloadu (Go) czytana przez
`verify_release_consistency.ps1`; deterministyczny `payload.zip`
(stały czas w nagłówkach) i sprawdzanie świeżości po treści.

## 5. Strategia testów

- **Jednostkowe:** `zig build test` (profile, `select`, niezmienniki
  kolejności kroków, parser planu), `go test ./...` (zgodność TSV),
  testy shell kroków w katalogach roboczych (wzór
  `check_xp_menu_overlay.py`).
- **Tabela prawdy rozstrzygania** (M0) jako test regresji na stałe.
- **Odciski wyjścia:** `compare_xp_packages.py`, `target_digest.py`,
  zawartość WORK, lista plików wimboot; uruchamiane w każdym kroku
  migracji i w `-Suite all` (tam, gdzie nie wymagają ISO użytkownika:
  te z ISO jako osobny zestaw `-Suite media` z listą ISO z DATA).
- **Macierz QEMU** (istniejące skrypty): SeaBIOS / OVMF / OVMF + Secure
  Boot × AHCI / IDE / NVMe / virtio / xHCI / EHCI
  (`run_qemu_secure_boot.py --only matrix`) × profil: dym do pierwszego
  ekranu Setup dla każdego profilu (szybko, WHPX dopuszczalne tylko dla
  przygotowania), pełne instalacje na TCG rzadziej (noc), bo trwają
  długo.
- **Powtarzalność:** dwa kolejne buildy dają identyczne `initramfs-usos`,
  `initramfs-xp` i (po M7) `payload.zip`.
- **Sprzęt** (lista kontrolna po krokach zmieniających zachowanie):
  X470 (XP UEFI-CSM, 7, Vista, 10/11), MS-7100 (XP BIOS, 2000, 98, DOS,
  10 x86), Ally (dotyk, Secure Boot). Każdy wynik zapisany w `TESTING.md`
  z numerem buildu.

## 6. Jak wpinają się przyszłe pozycje

| Pozycja | Co dodaje | Gdzie |
|---|---|---|
| Rodzina NT5 (2000, 2003, XP x64) | profile `2000-sp4-*`, `2003-x86-*`, `2003-x64-*`, `xp-x64-*`; parametr `source_dirs` (`AMD64`+`I386`) w krokach NT5; bundle sterowników per jądro/arch; `pae=.native_switch` | [nt5-uefi-family.md](nt5-uefi-family.md) |
| XP bez CSM (CSMWrap) | `FirmwareMask.uefi_csmwrap_target`; kroki: mały ESP na celu, kopia CSMWrap; osobny plan partycji | nt5-uefi-family.md §7 |
| Win98 na X470 | profil `win98se-uefi-csm`: kroki `micro_linux` (MBR/FAT32, kopia `WIN98`, Patcher9x `tlb,creg,mem,speed`), `answer_file=.msbatch_inf`, sterowniki user; hand-off przez CSM jak XP | research/win98-feasibility.md §11 |
| Buildy beta (Longhorn, Whistler) | profile z `media` po strukturze nośnika: NT5-podobne (TXTSETUP.SIF) → kroki NT5; WIM → kroki Vista; `notes` z datą timebomb z tabeli | ROADMAP L7 |
| NT4 | profil `nt4-bios`: kroki NT5 z partycją FAT16, `answer=.unattend_txt` | ROADMAP L8 |
| Generator odpowiedzi | etap `answer_file`: `AnswerFormat` + `UserAnswerPolicy` z profilu, kroki `*_render_answer` w odpowiednim wykonawcy | [answer-file-generator.md](answer-file-generator.md) |
| Pliki-towarzysze | `detect` dołącza towarzyszy do `MediaFacts`; profil decyduje, które rozszerzenia przyjmuje | jw. §2 |
| Ogólny wpis nieznanego ISO/IMG/EFI | profil `generic-unverified` z `verified=.unverified`, bez `prepare_target`; kroki: RAM disk / chainload El Torito EFI / memdisk | ROADMAP N5 |
| 32-bit CPU, mniej RAM | `Runner.micro_linux` dostaje wariant i686; profile deklarują minimalną RAM (z pomiarów), a `validate` sprawdza E820/mapę UEFI przed startem | ROADMAP L3 |
| Secure Boot UKI | plan tylko w pliku (bez cmdline), pakiety jako UKI; profil `secure_boot` bez zmian | ROADMAP N6 |
