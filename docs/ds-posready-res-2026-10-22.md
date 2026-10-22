# POSReady 2009: automatyczna rozdzielczość (USOSRES) — 2026-10-22

Gałąź `ds/posready-res` (baza `test/x470-98se-qemu`, commit `eac23cf5`).
Zakres: POSReady 2009 dostał ten sam kontrakt USOSRES co XP / Server 2003
(NT 5.1 jądro), pod `\USOS\POSR` zamiast `\USOS\XP`.

## Co ustalono na wejściu (ścieżka POSReady)

- POSReady 2009 = jądro NT 5.1 (XP SP3 Embedded), więc wzorcem jest ścieżka
  NT52 (`prepare_xp_ntfs_target.sh` → `usos_nt52_display_stage`,
  rejestracja przez `usos-users.cmd`).
- POSReady ma własny tok instalacji: PE + Setup na partycji 1 FAT16, Windows
  na partycji 2; `tools/posready_csmwrap_target.sh` przygotowuje dysk i
  katalog `\USOS\POSR` (FIRST.CMD, LOGON.CMD, LOGON.EXE, X470.REG,
  LOGON.REG, DRV/*), `posready_after_setup` w `tools/posready_qemu_install.sh`
  kopiuje `\USOS\POSR` na partycję Windows jako `C:\USOS\POSR`.
- Pierwsze logowanie: `LOGON.REG` (RunOnce) uruchamia `LOGON.CMD` — to
  odpowiednik `usos-users.cmd` z XP, więc tam trafia rejestracja.
- POSReady NIE ma transportu żądania rozdzielczości: `POSR.SIF`
  (`src/flow/answer/posready.zig`) niesie tylko `[UserData]`
  (FullName, Organization, ComputerName, AdminPassword, ProductKey), a
  `tools/posready_unattended.xml` nie ma sekcji display. Dlatego żądanie to
  `autoxauto` (+ `native=` z rekordu EDID menu UEFI), a nie wartość z profilu.
- Wcześniej POSReady nie było objęte: brak USOSRES w `\USOS\POSR`, brak
  wpisu `USOSDisplay`. Sterownik (zestaw XP x86: community ACPI, GenAHCI,
  USB3 xHCI) nie ustawiał żadnego trybu — system startował na VGA, więc
  zmiana była potrzebna (nie „już działa”).

## Zmienione pliki

1. `tools/posready_csmwrap_target.sh`
   - nowa funkcja `usos_posr_display_stage DIR`: woła wspólny helper
     `tools/display_profile.sh` (`usos_display_stage`) z żądaniem
     `autoxauto`, kopiuje `$LIB/USOSRES.EXE` i `DISPLAY.TXT` do
     `\USOS\POSR`, weryfikuje odczyt (`cmp`) i loguje
     `[POSREADY] DISPLAY request=autoxauto native=… apply=first-logon`;
     brak USOSRES w buildzie → log `DISPLAY USOSRES.EXE missing in this
     build; display unchanged` i przygotowanie leci dalej.
   - wywołanie dla `$work/pe/USOS/POSR` (obok FIRST.CMD/LOGON.CMD).
   - read-back `mdir` dla `::/USOS/POSR/DISPLAY.TXT` po odmontowaniu
     partycji PE.
2. `tools/posready_logon.cmd` (pierwsze logowanie, odpowiednik
   `usos-users.cmd`): przed `shutdown`
   `if exist "%S%USOSRES.EXE" reg add "HKLM\SOFTWARE\Microsoft\Windows
   \CurrentVersion\Run" /v USOSDisplay /t REG_SZ /d
   "%SystemDrive%\USOS\POSR\USOSRES.EXE" /f` + linia do `FIRST.LOG`
   (`display registered <rc>`). Ten sam wpis i ta sama nazwa wartości co
   na XP (`usos_display_nt52_run_line`).
3. `tools/posready_qemu_install.sh` (`posready_after_setup`): read-back
   `DISPLAY.TXT` po kopiowaniu `\USOS\POSR` na partycję Windows
   (błąd w `runs.txt`, gdy różny).
4. `tools/tests/test_display_posready.py` (nowy): test hostowy funkcji
   stagingu (żądanie auto, `native=` z rekordu EDID, rekord niepoprawny/brak,
   brak USOSRES, bajtowo identyczny `DISPLAY.TXT` ze ścieżką NT52) oraz
   „okablowania”: wywołanie w skrypcie celu, `mdir` read-back, read-back w
   `posready_after_setup`, linia rejestracji w `posready_logon.cmd` przed
   `shutdown` oraz obecność USOSRES/`display_profile.sh` w payloadzie
   micro-Linux.
5. `docs/display-policy.md`: wiersz tabeli dla POSReady 2009 i sekcja
   „Windows Embedded POSReady 2009 (2026-10-22)” (staging, rejestracja,
   pierwsze logowanie, status testów); usunięte zdanie „not covered yet”.

## Jak działa teraz POSReady (`\USOS\POSR`)

1. Przygotowanie dysku (`posready_csmwrap_target.sh`): do `\USOS\POSR` na
   partycji PE trafiają `USOSRES.EXE` + `DISPLAY.TXT` (`autoxauto`, plus
   `native=WxH` z `/mnt/esp/EFI/USOS/display-native.txt`) — ten sam plik i
   ten sam format co dla `\USOS\NT6` i `\USOS\XP`.
2. `posready_after_setup`: `\USOS\POSR` (już z USOSRES/DISPLAY.TXT) jest
   kopiowany na partycję Windows jako `C:\USOS\POSR`; kopie są sprawdzane.
3. Pierwsze logowanie (`LOGON.CMD`): rejestruje `USOSDisplay` w
   `HKLM\...\CurrentVersion\Run` na `%SystemDrive%\USOS\POSR\USOSRES.EXE`
   i loguje wynik; dalej ACPI-check, DONE.TXT, shutdown jak dotąd.
4. Przy następnym logowaniu USOSRES (to samo binarium NT52/NT5) wybiera
   natywny tryb z EDID, inaczej najwyższy, wyłącznie z listy sterownika,
   pełny ekran; gdy sterownik już w nim jest → `DISPLAY already at the
   selected mode; unchanged`; log `C:\USOS\POSR\USOSRES.LOG`.

## Testy

Uruchomione w worktree (host, bez instalacji):

- `python tools/tests/test_display_posready.py` → 8 testów, **OK**.
- `python tools/tests/test_posready.py` → 15 testów, **OK** (2 skipped:
  brak `sh`-zależnych warunków/QEMU).
- `python tools/tests/test_display_profile.py` → 13 testów OK, 2 **ERROR
  środowiskowe**: `test_collector_uses_pinned_buildkit_resolver_when_no_override`
  (brak `USOS_WATCOM`) i `setUpClass(TargetBuilds)` (brak zbudowanego
  USOSRES z powodu `USOS_WATCOM`/kompilatora w tym worktree) — niezależne
  od zmiany (nie dotknięto `display_profile.sh`).
- `sh -n tools/posready_csmwrap_target.sh tools/posready_qemu_install.sh`
  → **OK**.
- `build.bat` → Zig: **592/592 testów passed**, artefakty zbudowane;
  3 kroki failed: 2× „test runner failed to respond” (timeout runnera) i
  `micro-linux` — **HTTP download z dl-cdn.alpinelinux.org** (dozwolony,
  oczekiwany fail tego kroku, zgodnie z instrukcją).
- `python tools/tests/test_display_register.py` **nie uruchomiony**:
  wymaga `zig-out/windows-modern/usos-x86-csmwrap.exe`, którego ten build
  nie wyprodukował (NO_CSMWRAP_EXE).

## Czego nie sprawdzono

- Żadnej instalacji POSReady 2009 w QEMU ani na X470 z tą zmianą — brak
  dowodu z hardware, że USOSRES faktycznie przełącza tryb po pierwszym
  logowaniu (kod wyboru trybu jest ten sam, co przetestowany na XP).
- `posready_csmwrap_target.sh` i `posready_after_setup` nie były wykonane
  end-to-end (wymagają Linuksa, losetup, mkfs.fat, ntfs3, ISO POSReady);
  testy hostowe sprawdzają funkcję stagingu i okablowanie, nie sam zapis
  na dysk.
- `test_display_register.py` (DACL/Run na żywym helperze) — patrz wyżej.
- `micro-linux` w `build.bat` nie powstał (HTTP), więc pełny payload
  instalacyjny nie został złożony.

## Commit

- Gałąź: `ds/posready-res` (worktree `C:\Users\ASRock\usos-work\ds-posready-res`).
- Do commita weszły wyłącznie pliki własne (lista wyżej); `tools/zig`
  skopiowany z repo bazowego tylko do kompilacji, wpisany do
  `.git/info/exclude` tego worktree i **niecommitowany**; `tools/cache`
  nie był kopiowany.
