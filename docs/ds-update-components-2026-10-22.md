# usos-physical-update: raport i instalacja komponentów opcjonalnych (2026-10-22)

Gałąź: `ds/update-components` (baza: `test/x470-98se-qemu`, commit `77fc9f37`).
Worktree: `C:\Users\ASRock\usos-work\ds-update-components`.

## Problem

`usos-physical-update` (aktualizacja pendrive'a bez formatowania) przepisywał ESP
i Core, ale nie sprawdzał ani nie instalował komponentów opcjonalnych:

- pakiet Windows XP = ESP `EFI\USOS-XP` (`initramfs-xp`, `vmlinuz.efi`, `manifest.json`),
- donory WinPE PE10 x64/x86 = DATA `Programs\USOS\WinPE` + ESP `EFI\USOS\winpe-donor.ini`.

Pendrive zainstalowany bez komponentu nie dostawał go przy aktualizacji.

## Gdzie jest źródło

`installer/cmd/usos-physical-update/main.go` (package `main`, `//go:build windows`,
272 linie przed zmianą, 300 po zmianie). To narzędzie CLI: `-disk`, `-model`,
`-size`, `-confirm`, `-ptuuid`, `-esp-partuuid`, `-data-partuuid`,
`-work-partuuid`, `-installer` (USOS Installer.exe dla `CopyInstallPayload`),
`-log`, `-language`. Silnik aktualizacji: `localupdate.NewEngine`.

## Istniejący kod instalacji komponentów (bez duplikacji)

Krok „Komponenty" instalatora to dwie warstwy, których `usos-physical-update`
teraz używa bezpośrednio:

1. `components.Runner.Run` — `installer/internal/components/runner.go:88`:
   pobiera/rozpakowuje zip, weryfikuje go względem skompilowanej listy hashy
   (`Release.Pinned`) / `SHA256SUMS` i wywołuje `Installer.InstallComponent`.
2. `winhost.Backend.InstallComponent` — `installer/internal/winhost/components_windows.go:37`,
   po rozwiązaniu wolumenów woła `installComponentAt`
   (`installer/internal/winhost/components_windows.go:45`), które:
   - dla WinPE: `installWinpeComponent` → `ensureWinpeDonor`
     (`installer/internal/winhost/winpe_donor_windows.go:247`) — ten sam kod co
     install/update/repair, wpis nazwa/rozmiar/SHA-256 do `EFI\USOS\winpe-donor.ini`,
   - dla XP: `installXPComponent`
     (`installer/internal/winhost/components_windows.go:141`) — uruchamia
     `install-xp-package.ps1` z pakietu (PASS + weryfikacja SHA-256 po kopiowaniu).

## Zmiany

### 1. Raport (tylko odczyt) — `installer/internal/winhost/components_update_windows.go`

- `ReportComponents(espRoot, dataRoot string) ComponentReport` — **:86**
  (`inspectXPComponent` :99, `inspectWinpeComponent` :163) — czyta stan
  pendrive'a bez żadnego zapisu:
  - XP: `components.Inspect` (obecność `manifest.json`, język, `base_initramfs_sha256`
    vs `EFI\USOS\micro-linux\initramfs-usos` = porównanie z buildem) **oraz**
    rozmiary i SHA-256 `initramfs-xp`/`vmlinuz.efi` z `manifest.sha256`;
  - WinPE x64/x86: ISO w `Programs\USOS\WinPE` + zgodność z rekordem
    `EFI\USOS\winpe-donor.ini` (`verifyWinpeDonorArch`,
    `winpe_donor_windows.go:355` — ta sama weryfikacja, której używa menu UEFI).
  - Stany: `current` / `outdated` / `missing`; `ComponentReport.Lines()` drukuje
    `COMPONENT <nazwa>=<stan> id=<asset> detail=<...>`.
- Wywołanie w CLI: `installer/cmd/usos-physical-update/main.go:178` — raport jest
  drukowany (i wpisywany do logu operacji) **zawsze**, przed aktualizacją.
- **Domyślnie (bez `-components`): tylko raport, zero zapisów.** Widać to wprost
  w kodzie: `main.go:184` drukuje `COMPONENTS mode=report-only (...)`, a
  `InstallComponents` ma strażnik `if len(ids) == 0 { return }` na początku
  (`components_update_windows.go:206`) — przy pustej liście nie powstaje żaden
  plik, katalog ani wpis.

### 2. Opcja `-components xp,winpe,winpe-x86`

- Flaga: `main.go:39`. Parsowanie: `components.ParseComponentSelection`
  (`installer/internal/components/update.go:15`) — `xp` = pakiet dla języka UI
  (`PreferredXP`, jak w kroku „Komponenty"), `xp-pl`, `xp-en`, `winpe`
  (= `winpe-x64`), `winpe-x86`; nieznany token = błąd. Parsowanie odbywa się
  **przed pierwszym zapisem** (`main.go:134`), więc literówka przerywa bieg,
  zanim ESP zostanie tknięte.
- Instalacja: `winhost.InstallComponents` — `components_update_windows.go:204`,
  wywołane z `main.go:284` po udanej aktualizacji i weryfikacji końcowej.
  Buduje `components.Runner{...}` z `Installer: componentInstallerAt{espRoot, dataRoot}`
  (`:271`), którego `InstallComponent` woła `installComponentAt` — czyli
  **dokładnie tę funkcję, którą woła `Backend.InstallComponent` instalatora**
  (`components_windows.go:37`). Źródło zipów: overlay `-installer`
  (`components.OpenBundle`, ten sam all-in-one co krok „Komponenty"), a gdy go
  nie ma — pobranie z release do `%TEMP%` (`components.DefaultDir`).
  Komponenty już obecne i aktualne są pomijane, jak w UI (`status.Present`).
- Weryfikacja po zapisie: po `Runner.Run` wołany jest ponownie
  `ReportComponents`; każdy właśnie zainstalowany komponent musi być `current`
  i mieć właściwy `id` (XP: PL/EN), inaczej wynik = błąd (`:250-262`).
  Raport po instalacji jest drukowany i logowany (`main.go:290-295`).

### 3. Testy

`installer/internal/components/update_test.go` (przenośne, bez Windows):

- `TestParseComponentSelection` — mapowanie tokenów na `components.ID`.
- `TestParseComponentSelectionUnknown` — `bogus` i `legacy-ms` = błąd.

`installer/internal/winhost/components_update_windows_test.go` (`t.TempDir()`,
fałszywe ESP/DATA, żadnych prawdziwych dysków):

- `TestReportComponentsStatesOnFakeStick` — pusty stick: wszystkie `missing`;
  XP po instalacji krokiem „Komponenty": `current`; uszkodzony `initramfs-xp`:
  `outdated`; donor bez `winpe-donor.ini`: `outdated`, po `ensureWinpeDonor`:
  `current`. Raport nie zmienia drzewa (odczyt).
- `TestInstallComponentsXPOnly` — `-components xp` z bundle zawierającym także
  WinPE: powstaje tylko `EFI\USOS-XP\{initramfs-xp,vmlinuz.efi,manifest.json}`,
  `DATA\Programs\USOS\WinPE` nie istnieje, raport WinPE nadal `missing`.
- `TestInstallComponentsDefaultWritesNothing` — pusta lista komponentów:
  snapshot ESP i DATA (ścieżka + SHA-256 każdego pliku) przed/po jest
  identyczny, brak błędów.

Wynik: `go test ./internal/components ./internal/winhost` — **ok**
(components 1.5 s, winhost 12.1 s). `go vet ./cmd/usos-physical-update` — ok,
`go build ./cmd/usos-physical-update` — ok, `gofmt -l` — brak różnic,
`usos-physical-update.exe -h` pokazuje nową flagę `-components`.

## Czego nie sprawdzono (i dlaczego)

- Brak prawdziwego pendrive'a: żadnego dysku, litery ani montowania nie ruszano;
  cała instalacja była ćwiczona wyłącznie na katalogach `t.TempDir()`.
  `usos-physical-update` nie został uruchomiony przeciw `PhysicalDriveN`.
- Nie sprawdzono end-to-end z prawdziwym `USOS Installer.exe` (overlay
  `USOSCMP1`) ani pobierania komponentów z GitHuba — w testach bundle jest
  syntetyczny (te same funkcje `WriteBundle`/`OpenBundle`), a `BaseURL` wskazuje
  `127.0.0.1:1`, więc ścieżka `SourceDownload` nie jest pokryta.
- `install-xp-package.ps1` był uruchamiany przez PowerShell na fałszywym ESP
  (test), ale nie na wolumenie FAT32 z prawdziwą partycją USOS_ESP.
- `go build ./...` w `installer/` nie przechodzi w tym worktree z powodu
  **istniejącego** braku `installer/internal/payload/assets/payload.zip`
  (build output, `.gitignore:75`); do kompilacji testów użyto lokalnego,
  niecommitowanego 151-bajtowego stubu (wyłącznie `//go:embed`, nieużywany
  w testach). Nie zmieniano `CONTRIBUTING.md` ani `docs/ROADMAP.md`, nie
  kopiowano `tools\cache` ani toolchainów; Zig/build.bat nie były potrzebne.
