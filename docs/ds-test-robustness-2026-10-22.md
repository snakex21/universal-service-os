# Odporność `tools/tests` na brakujące zależności środowiskowe

Data: 2026-10-22
Gałąź: `ds/test-robustness` (baza: `test/x470-98se-qemu`, commit `43976323`)
Worktree: `C:\Users\ASRock\usos-work\ds-test-robustness`

## Cel

W zestawie `tools/tests` część testów padała nie z powodu błędów kodu, lecz
braku zależności: kompilatora `tools/zig`, artefaktów w `zig-out`, Open Watcom
(`USOS_WATCOM`) i plików `tools/vendor`. Każdy taki test ma teraz albo sam
znaleźć zależność w czasie działania, albo zostać pominięty z czytelnym
komunikatem „brak artefaktu X – uruchom build.bat”. Asercje i logika testów
nie zostały zmienione.

## Baseline (przed zmianami)

`python -m pytest tools\tests -q -p no:cacheprovider --continue-on-collection-errors`

| Wynik | Liczba |
|---|---|
| passed | 810 |
| failed | 41 |
| skipped | 27 |
| errors | 252 |

Bez `--continue-on-collection-errors` przebieg przerywał się już na 3 błędach
kolekcji (`tools/zig/zig.exe` brakuje w czasie importu modułu).

## Po zmianach

| Wynik | Przed | Po |
|---|---|---|
| passed | 810 | **812** |
| failed | 41 | **31** |
| skipped | 27 | **287** |
| errors | 252 | **0** |
| subtests passed | – | 145 |

## Co dokładnie zmieniono

Nowy moduł `tools/tests/depguard.py` – sondy zależności liczone **w czasie
wywołania**, nigdy przy imporcie:

* `zig()` / `require_zig()` – `USOS_ZIG`, inaczej `tools/zig/zig.exe`;
* `watcom()` / `require_watcom()` – `USOS_WATCOM`, inaczej **autodetekcja**
  `tools/cache/openwatcom/ow-*` (wybierany katalog zawierający
  `binnt64/wcc.exe` lub `binnt/wcc.exe`);
* `path()` / `require_path()` – artefakty repo-względne (`zig-out/...`,
  `tools/vendor/...`);
* `posix_shell()` / `coreutils()` / `require_posix_shell()` – `sh` z PATH lub
  Git for Windows oraz `rm/cp/mv`.

Testy używają tych sond w `setUpClass` lub na początku modułu i w przypadku
braku zależności zgłaszają `skip` z komunikatem zawierającym brakujący
artefakt i wskazówkę „uruchom build.bat”.

## Tabela: fail/error → skip

Poniższe pozycje przechodziły w baseline jako `error` (głównie
`FileNotFoundError: [WinError 2]` z powodu braku `tools/zig/zig.exe`) i są
teraz pomijane z jawnym powodem.

| Test / moduł | Przed | Po | Przyczyna |
|---|---|---|---|
| `legacy_bios/test_dos_disk_filter.py` | error | skip | brak `tools/zig/zig.exe` |
| `legacy_bios/test_dos_reboot.py` | error | skip | brak `tools/zig/zig.exe` |
| `legacy_bios/test_mbr_timestamp.py` | error | skip | brak `tools/zig/zig.exe` |
| `legacy_bios/test_ordered_wimboot_kexec.py` | error | skip | brak `tools/zig/zig.exe` |
| `legacy_bios/test_usoskbc_mouse.py` | error | skip | brak `tools/zig/zig.exe` |
| `legacy_bios/test_usoskey_wheel.py` | error | skip | brak `tools/zig/zig.exe` |
| `legacy_bios/test_usoskey_xlat.py` | error | skip | brak `tools/zig/zig.exe` |
| `legacy_bios/test_usosmous.py` | error | skip | brak `tools/zig/zig.exe` |
| `legacy_bios/test_usosmous_scale.py` | error | skip | brak `tools/zig/zig.exe` |
| `legacy_bios/test_usosms1.py` | error | skip | brak `tools/zig/zig.exe` (pomijane, gdy `USOSMS1_DRV` ustawione) |
| `legacy_bios/test_usosv10.py` | error | skip | brak `tools/zig/zig.exe` |
| `legacy_bios/test_win9x_u9fix.py` | error | skip | brak `tools/zig/zig.exe` |
| `legacy_bios/test_windows_disk_order.py` | error | skip | brak `tools/zig/zig.exe` |
| `addons/test_legacy_flow.py` (Stage + 2 testy Render) | error | skip | brak `tools/zig/zig.exe` |
| `test_display_profile.py` | error + `KeyError: 'USOS_WATCOM'` | skip | brak `tools/zig` i brak Open Watcom |
| `test_network_defaults.py` | error | skip | brak `tools/zig/zig.exe` |
| `test_vista_autochk.py` | error | skip | brak `tools/zig/zig.exe` |
| `test_vista_int10_dispatcher.py` | error | skip | brak `tools/zig/zig.exe` |
| `test_windows7_nvme.py` | error | skip | brak `tools/zig/zig.exe` |
| `test_windows7_uefi_publish.py` | error | skip | brak `tools/zig/zig.exe` |
| `test_windows_driver_support.py` | error | skip | brak `tools/zig/zig.exe` |
| `test_windows_previous_install.py` | error | skip | brak `tools/zig/zig.exe` |
| `test_windows_setup_logging.py` | error | skip | brak `tools/zig/zig.exe` |
| `test_windows_source_mount.py` | error | skip | brak `tools/zig/zig.exe` |
| `test_testmode_watermark.py` | error | skip | brak `tools/zig/zig.exe` |
| `test_answer_merge_paths.py` | error | skip | brak `tools/zig/zig.exe` |
| `test_uefi_graphics_connect.py` | error kolekcji | skip modułu | brak `tools/zig/zig.exe` |
| `test_uefi_graphics_refresh.py` | error kolekcji | skip modułu | brak `tools/zig/zig.exe` |
| `test_windows7_nvme_prepare.py` | error kolekcji | skip modułu | brak `zig-out/micro-linux/{vmlinuz-virt,initramfs-usos}` |
| `test_x86_vista_oobe_gate.py::test_hidden_console_chain_retains_stdout` | error | skip | brak `tools/zig/zig.exe` |
| `test_nvme_modern_x86.py::ModernNVMe::test_host_is_refused_before_writes` | fail | skip | brak `zig-out/windows-modern/usos-nvme-modern.exe` |
| `windows_native/test_modern_finalize.py` | error | skip | brak `tools/zig/zig.exe` |

## Tabela: skip → pass

**Brak.** W tym środowisku nie ma `tools/cache`, więc żadna autodetekcja nie
miała czego znaleźć i nie odblokowała testów, które wcześniej były pomijane.
Autodetekcja jest jednak gotowa i zadziała po pojawieniu się zależności
(ścieżki liczone w runtime, nic nie jest zapisane na stałe).

## Tabela: nadal failuje (31) i dlaczego

| Test | Liczba | Przyczyna |
|---|---|---|
| `test_target_disk_wait.py` | 5 | skrypt `.sh` uruchamiany przez Git `sh` z PATH bez `/usr/bin`; asercje na wyjściu (`RC=0`, `SLEPT=60`) nie są spełnione |
| `test_stick_write.py` | 4 | to samo: `sh: command not found` / brak coreutils w PATH przekazanym skryptowi |
| `test_vdi_geometry.py` | 4 | `FileNotFoundError: tools/cache/tmp/tmpXXXX` – brak katalogu tymczasowego w `tools/cache` |
| `test_nt52_staging.py` | 6 | brak `tools/vendor/xp-modern/2026-09-21/GenAHCI_6.3.0.1.7z` (paczka niepobrana) + `cp: command not found` w `sh` |
| `test_logon_hint.py` | 3 | `rm: command not found` w `micro_linux_ui.sh` (PATH bez `/usr/bin`) |
| `test_w2k_usosvbe.py` | 3 | `cp: command not found` w `w2k_stage.sh` |
| `test_stick_release.py` | 1 | skrypt `.sh` zwraca inną listę ścieżek niż oczekiwana |
| `test_esp_writes_helper.py` | 1 | `mv: command not found` w `legacy_xp_staging.sh` |
| `test_usosnvme.py::Nt3Flow::test_usosnt3` | 1 | `FileNotFoundError` – brak artefaktu `tools/nt/...` |
| `test_nt3_flow.py::Nt3AnswerProfile::test_usosnt3_imports_exist_on_nt31` | 1 | `FileNotFoundException` – brak artefaktu sterownika NT 3.1 |
| `legacy_bios/test_usosvmd.py` | 1 | asercja `vmouse` (zachowanie kodu) |
| **`test_x86_vista_oobe_gate.py::test_cmd_arms_gate_for_nt60_sp2_only`** | 1 | **prawdziwy błąd kodu** – w `tools/windows_x86_csmwrap.cmd` brak sekwencji `call :usb3` / `call :nt60_gate` |

Rodziny „`sh` bez coreutils” i „brak `tools/cache/tmp`” to nadal kwestie
środowiska wykonawczego, nie brakujących plików, których szuka `depguard`;
zostały zgłoszone, a nie maskowane skipem, bo `sh` + `rm/cp/mv` **są**
osiągalne (Git for Windows), tylko PATH przekazywany skryptom ich nie zawiera.

## Zgłoszone prawdziwe błędy kodu (nienaprawiane)

1. `tools/windows_x86_csmwrap.cmd`: test
   `test_x86_vista_oobe_gate.py::test_cmd_arms_gate_for_nt60_sp2_only`
   oczekuje `call :usb3\ncall :nt60_gate\n`; w pliku tej sekwencji nie ma
   (asercja w linii 66). Zgodnie z zadaniem – zgłoszone, bez zmian w kodzie
   i bez zmiany asercji.
2. `legacy_bios/test_usosvmd.py::test_usosmous_vmouse_mode_and_imports` –
   asercja na trybie `vmouse`; wymaga decyzji właściciela sterownika.

## Autodetekcje dodane

* **`USOS_WATCOM`** – `depguard.watcom()`: zmienna środowiskowa, a gdy jej nie
  ma, `tools/cache/openwatcom/ow-*` (katalog z `binnt64/wcc.exe` lub
  `binnt/wcc.exe`), wybierany przy każdym wywołaniu. Użyte m.in. w
  `test_display_profile.py`, które wcześniej kończyło się
  `KeyError: 'USOS_WATCOM'`.
* **`USOS_ZIG`** – `depguard.zig()`: zmienna, inaczej `tools/zig/zig.exe`.
* **Artefakty `zig-out`** – `depguard.require_path()` (`micro-linux`,
  `windows-modern`).

## Weryfikacja

* Baseline i dwa pełne przebiegi `python -m pytest tools\tests -q
  -p no:cacheprovider --continue-on-collection-errors` (810/41/27/252 →
  808/32/220/49 → **812/31/287/0**).
* Przebiegi celowane po każdej partii zmian (m.in. 188 skipów w podzbiorze
  `legacy_bios` + moduły `zig-out`).

## Pliki zmienione

`tools/tests/depguard.py` (nowy) oraz guardy w:
`test_display_profile.py`, `test_network_defaults.py`, `test_vista_autochk.py`,
`test_vista_int10_dispatcher.py`, `test_windows7_nvme.py`,
`test_windows7_uefi_publish.py`, `test_windows_driver_support.py`,
`test_windows_previous_install.py`, `test_windows_setup_logging.py`,
`test_windows_source_mount.py`, `test_testmode_watermark.py`,
`test_answer_merge_paths.py`, `test_uefi_graphics_connect.py`,
`test_uefi_graphics_refresh.py`, `test_windows7_nvme_prepare.py`,
`test_nvme_modern_x86.py`, `test_x86_vista_oobe_gate.py`,
`windows_native/test_modern_finalize.py`, `addons/test_legacy_flow.py`,
`legacy_bios/{test_dos_disk_filter,test_dos_reboot,test_mbr_timestamp,
test_ordered_wimboot_kexec,test_usoskbc_mouse,test_usoskey_wheel,
test_usoskey_xlat,test_usosmous,test_usosmous_scale,test_usosms1,test_usosv10,
test_win9x_u9fix,test_windows_disk_order}.py`.

## Uwagi

* `tools/zig` nie został skopiowany ani dodany do repo; `tools/cache` nie jest
  dotykane. Build (`build.bat`) nie był wymagany do tych zmian – brak
  kompilatora jest właśnie jedną z obsługiwanych sytuacji.
* Nie zmieniano `CONTRIBUTING.md` ani `docs/ROADMAP.md`; żadne dyski ani
  pendrive'y nie były dotykane.
