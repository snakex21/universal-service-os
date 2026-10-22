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
| `fast-startup-on.txt` | Zostawia własne "Szybkie uruchamianie" Windowsa (`HiberbootEnabled` bez zmian) zamiast je wyłączać. | `Windows 8`, `8.1`, `10` (x86 i amd64) w odpowiedziach USOS: `src/platform/uefi/answer_profiles.zig:275-280`; na ścieżce x86 CSMWrap także helper WinPE `tools/windows_x86_csmwrap.cmd`. | Fast Startup wyłączony: `HiberbootEnabled=0` w `HKLM\SYSTEM\...\Control\Session Manager\Power`. | `src/platform/uefi/answer_profiles.zig:269-307` (nazwa `:293`, otwarcie `:305`, log `:306`), brama odpowiedzi `src/flow/answer/autounattend.zig:32-34` i `:327-331`, helper `tools/windows_x86_csmwrap.cmd:33` i `:100-103`. |
| `native-res-on.txt` | Włącza eksperymentalną natywną rozdzielczość Win7 x64: dwa tryby UefiSeven (1024x768 + natywny z EDID) i staging USOSRES. | `Systems\Windows\Windows 7\Unattended\`: Win7 x64, natywny UEFI, plan `wimboot win7` (`src/flow/testdata/routing_golden.tsv:30619`). | Wyłączone: jeden tryb UefiSeven 1024x768 na cały ekran (decyzja 2026-10-22, X470 PASS dla wariantu z flagą). | `src/flow/plan.zig:155-157` (flaga `:157` → `usos-native-res.flag` na ESP). |
| `testmode-watermark-on.txt` | Pozwala usoswm zostawić napis "Test Mode" Windowsa (wyłącza zamalowanie); bez pliku napis jest zasłonięty. | Vista / Server 2008 na CSMWrap (plany `wimboot vista` i `wimboot_int10`); działa w zainstalowanym systemie przez usoswm. | usoswm zasłania napis (X470 PASS; ścieżka MUI odrzucona). | `src/flow/plan.zig:155` (flaga → ESP), odczyt na DATA `tools/vista_csmwrap_prepare.sh:83`, staging do systemu `tools/windows_vista_install.c:787-788`, runtime `tools/nt6/usoswm/common.h:46`. |
| `display-keep.txt` | **W przygotowaniu (nie ma jeszcze w kodzie).** Miałby zostawić rozdzielczość wybraną przez Windows, czyli wyłączyć automat USOSRES. | - | Automat USOSRES działa jak w [display-policy.md](display-policy.md). | Brak: `display-keep` nie występuje w `src/` ani `tools/`; dziś wyłączeniem automatu jest jawna wartość `display=WxH` w profilu/pliku odpowiedzi (`src/flow/answer/autounattend.zig:377-387`). |

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
