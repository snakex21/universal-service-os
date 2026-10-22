# Przełączniki na DATA (`Systems\Windows\<wersja>\Unattended`)

Flagi zachowania instalacji Windows leżą na partycji `USOS_DATA` (NTFS,
montowanej w USOS jako DATA), w folderze wybranej wersji:

```
DATA\Systems\Windows\Windows 10\Unattended\fast-startup-on.txt
```

- Jeden przełącznik to **jeden pusty plik** o dokładnej nazwie. Liczy się sama
  obecność pliku, treść nie ma znaczenia; nazwa mówi, co plik włącza
  (`nvme-off.txt` gasi trasę NVMe, `fast-startup-on.txt` przywraca zachowanie
  Windowsa).
- **Brak pliku = zachowanie domyślne** z tabeli niżej.
- Nazwy folderów wersji są dokładnie takie, jakich używa USOS:
  `Systems\Windows\Windows 7`, `Windows 8`, `Windows 8.1`,
  `Windows Embedded 8.1 Industry`, `Windows 10`, `Windows 11`,
  `Windows Server <wersja>`. Nie skracaj ich i nie tłumacz - katalog systemów
  USOS buduje z nich ścieżkę `\Systems\Windows\<folder>\Unattended`
  (`src/catalog/windows_modern.zig:37`), a te same nazwy ma mapowanie folderów
  na WORK (`tools/windows_setup_media.sh:24-36`) i skrypty WinPE
  (`tools/vista_csmwrap_prepare.sh:66`).
- Flagi czyta kod USOS (menu UEFI, skrypty WinPE, helper w zainstalowanym
  systemie), nie Windows Setup. Działają tylko dla instalacji robionych przez
  USOS.

## Tabela

| Plik | Co robi | Systemy / ścieżki | Bez pliku (domyślnie) | Kod |
|---|---|---|---|---|
| `nvme-off.txt` | Wyłącza trasę instalacji na NVMe: mikro-Linux kończy komunikat, dysk nie jest zmieniany (cel SATA działa dalej). | `win-x86-uefi-csmwrap`: `Windows 8`, `Windows 8.1`, `Windows Embedded 8.1 Industry`, `Windows 10` (32-bit); dotyczy tylko celu NVMe. | Trasa NVMe włączona (od 2026-10-22, X470 PASS). | Menu UEFI: `src/platform/uefi/windows_native_iso.zig:562-572` (odczyt `:567`); mikro-Linux/WinPE: `tools/vista_csmwrap_prepare.sh:64-68` (odczyt `:67`), komunikat `:240`. |
| `fast-startup-on.txt` | Zostawia własne "Szybkie uruchamianie" Windowsa (`HiberbootEnabled` bez zmian) zamiast je wyłączać. | `Windows 8`, `8.1`, `10`, `11` (wszystkie architektury mediów: x86 / amd64 / arm64) w odpowiedziach USOS: `src/platform/uefi/answer_profiles.zig:318-351`; na ścieżce x86 CSMWrap także helper WinPE `tools/windows_x86_csmwrap.cmd` (tylko 8 / 8.1 / 10 — x86 Windows 11 nie istnieje). | Fast Startup wyłączony: `HiberbootEnabled=0` w `HKLM\SYSTEM\...\Control\Session Manager\Power`. | `src/platform/uefi/answer_profiles.zig:318-351` (nazwa `:336`, otwarcie `:348`, log `:349`), brama odpowiedzi `src/flow/answer/autounattend.zig:32-34` i `:330-335`, helper `tools/windows_x86_csmwrap.cmd:33` i `:100-106`. |
| `native-res-on.txt` | Włącza eksperymentalną natywną rozdzielczość Win7 x64: dwa tryby UefiSeven (1024x768 + natywny z EDID) i staging USOSRES. | `Systems\Windows\Windows 7\Unattended\`: Win7 x64, natywny UEFI, plan `wimboot win7` (`src/flow/testdata/routing_golden.tsv:30619`). | Wyłączone: jeden tryb UefiSeven 1024x768 na cały ekran (decyzja 2026-10-22, X470 PASS dla wariantu z flagą). | `src/flow/plan.zig:155-157` (flaga `:157` → `usos-native-res.flag` na ESP). |
| `testmode-watermark-on.txt` | Pozwala usoswm zostawić napis "Test Mode" Windowsa (wyłącza zamalowanie); bez pliku napis jest zasłonięty. | Vista / Server 2008 na CSMWrap (plany `wimboot vista` i `wimboot_int10`); działa w zainstalowanym systemie przez usoswm. | usoswm zasłania napis (X470 PASS; ścieżka MUI odrzucona). | `src/flow/plan.zig:155` (flaga → ESP), odczyt na DATA `tools/vista_csmwrap_prepare.sh:83`, staging do systemu `tools/windows_vista_install.c:787-788`, runtime `tools/nt6/usoswm/common.h:46`. |
| `display-keep.txt` | Zostawia rozdzielczość wybraną przez Windows (lub pierwszy tryb instalacji): USOS nie instaluje USOSRES i nie zmienia trybu po instalacji. Działa dla każdego pliku odpowiedzi, także bez niego; to samo daje w profilu `display=keep` ("Domyślna Windows"). Zaimplementowane 2026-10-22 (merge `feat/res-keep-option`). | 9x / NT 3.5x / NT4 / POSReady na CSMWrap (bez obrazu dysku i DOS ISO), 2000 / XP / 2003 (NT5), Vista / 7 / 2008 / 2008 R2 i 32-bitowe 8 / 8.1 / 10 na CSMWrap. | Automat USOSRES działa jak w [display-policy.md](display-policy.md) (natywny tryb monitora z EDID). | Odczyt na DATA: 9x/NT `tools/w9x_csmwrap_prepare.sh:554-562` (test pliku `:558`), NT5 `tools/legacy_xp_staging.sh:480-484` (`:483`), 6.x `tools/vista_csmwrap_prepare.sh:86-90` (`vista_display_keep`) i `:307-312` (log `:310`); wspólny test `tools/display_profile.sh:9-16` (`usos_display_keep`); skrypty celu np. `tools/vista_csmwrap_target.sh:185-195`, `tools/nt4_csmwrap_target.sh:1110-1113`, `tools/w2k_stage.sh:965-968`, `tools/prepare_xp_ntfs_target.sh:93-96`; testy `tools/tests/test_display_keep.py`. Opis: [display-policy.md](display-policy.md) sekcja "Keep Windows' own mode". |

## Ograniczenie bez przełącznika: CSMWrap zajmuje 1 procesor logiczny

Na ścieżkach CSMWrap zainstalowany system widzi o jeden procesor logiczny
mniej. Nie ma pliku na DATA, który to wyłącza - tak działa sam CSMWrap
(dostawiony w `tools/vendor/csmwrap/3.1.2-src/csmwrap-3.1.2-src.tar.xz`):

- `src/csmwrap.c:630-641` (w archiwum, `csmwrap-3.1.2/`): po `acpi_init`
  wywołuje `bios_proxy_init(Csm16_bin, ..., rsdp_copy)`.
- `src/bios_proxy.c:682-704`: `bios_proxy_init` wybiera jeden rdzeń AP jako
  pomocnika proxy BIOS (`"No AP available for BIOS proxy"` `:698`) i woła
  `patch_acpi_hide_helper(rsdp_copy, selected_ap_id)` (`:704`, funkcja `:623`).
- `src/bios_proxy.c:427-470`: `create_patched_madt` buduje nową tablicę MADT
  bez wpisu LAPIC / x2APIC tego rdzenia (`cpu_visible_to_os` `:412`, `:463`);
  RSDT / XSDT wskazują potem na nową MADT, więc system go nie widzi.
- Pomiar: X470 (Ryzen 7 5700X, 16 wątków), Vista x64 przez CSMWrap,
  `System.evtx` z 2026-10-21 pokazał procesory 0..14, czyli 15 z 16
  (także `docs/w7x64-native-res-2026-10-21.md:8-10`).

## Pliki w tym folderze, które nie są przełącznikami

- `nvme-experimental.txt` - stara flaga, usunięta; kod jej nie czyta i plik
  jest nieszkodliwy (`tools/tests/test_nvme_modern_x86.py:184`,
  [nvme-nt6-2026-10-12.md](nvme-nt6-2026-10-12.md), sekcja 18).
- `*.xml`, `*.sif`, `*.ini` w tym folderze to pliki odpowiedzi i profil
  (`answer-profiles.md`), nie flagi.
- `apm-off.txt` to log w `\EFI\USOS\Logs` (`src/platform/uefi/apm_breadcrumbs.zig:189-192`),
  a `input-devices.txt` to raport urządzeń wejściowych
  (`src/platform/uefi/input_report.zig:275`) - oba leżą poza DATA.

## Sprawdzenie w logach

- `fast-startup-on.txt`: linia serial `[PROFILE] fast-startup-on.txt on DATA:
  Windows keeps its Fast Startup` (`src/platform/uefi/answer_profiles.zig:306`)
  i `[USOS] phase=fast-startup-off` w logu WinPE
  (`tools/windows_x86_csmwrap.cmd:104`).
- `nvme-off.txt`: komunikat "NVMe for 32-bit ... is turned off (nvme-off.txt in
  Unattended on DATA)" z mikro-Linux (`tools/vista_csmwrap_prepare.sh:240`).
