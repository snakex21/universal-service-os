# ds/fast-startup-win11 — Fast Startup wyłączony także w Windows 11 (2026-10-22)

Gałąź: `ds/fast-startup-win11` (worktree `C:\Users\ASRock\usos-work\ds-fast-startup-win11`),
baza `test/x470-98se-qemu` (`77fc9f37`, merge `ds/fast-startup-off`). Bez merge'a, bez
wdrożeń, bez dotykania dysków i pendrive'ów.

## Co było i co się zmieniło

W bazie `ds/fast-startup-off` Fast Startup był wyłączany dla Windows 8 / 8.1 / 10
(offline `HiberbootEnabled=0`). Windows 11 ma ten sam problem — „Szybkie
uruchamianie” zostawia zahibernowany NTFS, a dyski USOS są przekładane między
komputerami — więc 11 jest teraz objęty **tą samą drogą**, bez duplikowania logiki:
jedna funkcja `hiberboot()` (odpowiedź autounattend) i jedna brama `fastStartupOn()`
(opt-out na DATA).

## Gdzie rozszerzono na Windows 11

1. `src/flow/answer/autounattend.zig:316-322` — `hiberboot()` (rodziny z Fast
   Startupem): `.windows_8, .windows_8_1, .windows_10, .windows_11 => true`,
   komentarz `:316-317`. Serwery nadal `false` (tam Fast Startup jest ukryty).
2. `src/flow/answer/autounattend.zig:330-335` — komentarz bramki w
   `specializeCommands()` i samo dodanie komendy (bez zmian w treści komendy):
   ```
   reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
       /v HiberbootEnabled /t REG_DWORD /d 0 /f
   ```
3. `src/platform/uefi/answer_profiles.zig:318-323` — `fastStartupOn(system_id)`:
   opt-out `Systems\Windows\<wersja>\Unattended\fast-startup-on.txt` obsługuje
   teraz też `.windows_11` (komentarz `:311-317`). Katalog `Windows 11` pochodzi
   z wpisu katalogu systemów (`unattended_directory`), więc nie ma tu żadnej
   nowej ścieżki.

Nic nie zduplikowano: rodzina `windows_11` była już w `src/flow/answer/target.zig`
(`:29`, `:99`), doszła tylko w dwóch listach rodzin.

## Test Zig

`src/flow/answer/autounattend.zig:785-807` — „Fast Startup off on 8 / 8.1 / 10 / 11
clients only, opt-out keeps it”:

* iteracja po **wszystkich** rodzinach (`inline for` po `Family`), x86 i amd64;
* oczekiwane `true` dla `windows_8`, `windows_8_1`, `windows_10` **i
  `windows_11`** (wcześniej 11 było oczekiwane jako `false`);
* `if (comptime family.server()) try std.testing.expect(!expected)` — jawne
  potwierdzenie, że **żaden** serwer (`server_2008`, `2008_r2`, `2012`,
  `2012_r2`, `2016`, `2019`, `2022`, `2025`) komendy nie dostaje;
* zachowana asercja opt-outu: `fast_startup_on = true` usuwa komendę dla
  każdej rodziny;
* Vista / 7 / NT5 nadal bez komendy (oczekiwane `false`).

Wynik:

```
zig build test --cache-dir tools\cache\zig --global-cache-dir tools\cache\zig-global
Build Summary: 62/62 steps succeeded; 603/603 tests passed
```

`build.bat` (pełny): 96/98 kroków, 603/603 testy, przerywa tylko na `micro-linux`
(`HTTP Error 404` przy `dl-cdn.alpinelinux.org` / Alpine 3.24.1) — znany,
dozwolony warunek, niezwiązany ze zmianą.

## Ścieżka x86 CSMWrap (tools/windows_x86_csmwrap.c + windows_fast_startup.h)

Sprawdzone: brama wersji w `tools/windows_x86_csmwrap.c:618` odcina tylko
`major < 6` oraz `6.0` / `6.1` (Vista / 7), czyli **nie** odcina Windows 11;
`10.0` przechodzi do zapisu hive'a. Dla `10.0` wybierany jest folder opt-outu
`Windows 10` (`:619`) — dla hipotetycznego 11 byłby to zły folder.

**Nie zmieniono** tego, bo ścieżka `win-x86-uefi-csmwrap` obsługuje wyłącznie
media 32-bitowe, a **Windows 11 nie istnieje w x86** (media 11 są amd64 / arm64),
więc ten helper nigdy nie zobaczy Windows 11. Nagłówki
(`tools/windows_fast_startup.h:1-4`, `tools/windows_x86_csmwrap.cmd:29-34`)
opisują więc dalej 8 / 8.1 / 10 — zgodnie ze stanem faktycznym. Gdyby kiedyś
pojawił się 32-bitowy klient NT 10.0 z buildem ≥ 22000, trzeba by dodać rozpoznanie
builda (`file_version` zwraca dziś tylko major/minor) i folder `Windows 11`.

## Goldeny Win11 — zregenerowane

Mechanizm: `USOS_UPDATE_GOLDEN=1 python tools/tests/test_answer_render.py`
(`UPDATE = os.environ.get('USOS_UPDATE_GOLDEN') == '1'`, `golden()` w
`tools/tests/test_answer_render.py:46`, `:87-95`; narzędzie `usos-answer` buduje
się w `main()`, `:510-516`). Uwaga: w `cmd` trzeba `set "USOS_UPDATE_GOLDEN=1"` —
`set VAR=1 && ...` ustawia wartość z trailing space i regeneracja **nie** działa.

Zregenerowane (diff ograniczony do nowej komendy w `Specialize` i przesunięcia
`<Order>`; żaden inny system się nie zmienił):

| Plik | Zmiana |
|---|---|
| `src/flow/answer/testdata/golden/full.windows-11.amd64.xml` | +4 linie (`<Order>2</Order>` + komenda) |
| `src/flow/answer/testdata/golden/full.windows-11.arm64.xml` | +4 linie |
| `src/flow/answer/testdata/golden/minimal.windows-11.amd64.xml` | +8 linii (cały komponent `Microsoft-Windows-Deployment`) |
| `src/flow/answer/testdata/golden/display-keep.windows-11.amd64.xml` | +8 linii (j.w.) |
| `src/flow/answer/testdata/golden/tweaks.windows-11.amd64.xml` | +8 / −4 (komenda + `<Order>`) |
| `src/flow/answer/testdata/golden/options.windows-11.amd64.xml` | +69 / −65 (komenda + `<Order>`) |
| `src/flow/answer/testdata/golden/tweaks.matrix.txt` | tylko wiersze `windows-11` |
| `src/flow/answer/testdata/golden/options.matrix.txt` | tylko wiersze `windows-11` |

Weryfikacja po regeneracji: `python tools/tests/test_answer_render.py` — brak
`FAIL` (0 błędów). Goldeny 8 / 8.1 / 10, serwerów, Visty, 7 i NT5 pozostały
bajtowo identyczne (`git status` ich nie pokazuje). **Nic nie zostało do
regeneracji po merge'u.**

## Dokumentacja

* `docs/data-switches.md:32` — wiersz `fast-startup-on.txt`: systemy
  `Windows 8`, `8.1`, `10`, `11` (wszystkie architektury mediów), informacja, że
  helper x86 CSMWrap dotyczy tylko 8 / 8.1 / 10 (brak x86 Windows 11) oraz
  poprawione odwołania do kodu (`answer_profiles.zig:318-351`, `:336`, `:348`,
  `:349`; `autounattend.zig:32-34`, `:330-335`;
  `windows_x86_csmwrap.cmd:33`, `:100-106`).
* `docs/release-notes-1.0.md:137` (PL) i `:185` (EN) — nagłówek punktu „Nowe od
  RC”: `Fast Startup wyłączony w 8 / 8.1 / 10 / 11` / `off in 8 / 8.1 / 10 / 11`.

## Stan repo i narzędzia

* `tools\zig` (kompilator) skopiowany **wyłącznie** z repo bazowego
  `C:\Users\ASRock\Desktop\usos-x470-98se\tools\zig`; wpis `tools/zig/` dodany do
  `.git/info/exclude`. `tools\cache` **nie** był kopiowany (build zrobił własny).
* W commitcie są tylko pliki własne: źródła, testy, goldeny Win11, dokumentacja.
  Żadnych narzędzi, cache'ów, artefaktów.

## Czego nie sprawdzono

* **Brak testu instalacji Windows 11** (VM ani sprzęt): zmiana to jedna komenda
  `Specialize` i wyłączony opt-out; wartość `HiberbootEnabled=0` jest ignorowana
  przy braku `hiberfil.sys`, więc ryzyko jest niskie, ale pierwszy boot 11 z tą
  odpowiedzią czeka na test.
* **Windows 11 przez CSMWrap x86** — nie istnieje (brak mediów x86 11), patrz
  sekcja wyżej.
* `docs/ds-fast-startup-2026-10-22.md` (raport poprzedniej gałęzi) mówi
  „Windows 11 poza zakresem tej gałęzi” — to zdanie dotyczy
  `ds/fast-startup-off`; niniejszy raport je rozszerza, pliku nie zmieniano.
