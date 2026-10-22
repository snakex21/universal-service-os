# ds/fast-startup-off — Fast Startup wyłączony domyślnie (2026-10-22)

Gałąź: `ds/fast-startup-off` (worktree `C:\Users\ASRock\usos-work\ds-fast-startup-off`,
baza `test/x470-98se-qemu`). Bez merge'a, bez wdrożeń, bez dotykania dysków.

## Co zrobione

Instalacje Windows 8, 8.1 i 10 robione przez USOS mają w zainstalowanym systemie:

```
HKLM\SYSTEM\<CurrentControlSet>\Control\Session Manager\Power
    HiberbootEnabled = 0 (REG_DWORD)
```

Powód: „Szybkie uruchamianie" to częściowa hibernacja — wyłączenie zapisuje
sesję jądra i sterowniki do `hiberfil.sys`, a wolumin NTFS zostaje w stanie
„zahibernowanym". To jest bezpieczne tylko na maszynie, która hibernowała;
dyski USOS są przekładane między komputerami, więc każdy zainstalowany przez
USOS 8 / 8.1 / 10 startuje pełnym bootem. W offline hive nie ma
`CurrentControlSet` — używany jest `ControlSet00N` wskazany przez
`Select\Current` (ten, z którego wystartuje następny boot).

Dwie ścieżki, po jednym spójnym miejscu na każdą (żadna nie przerywa instalacji,
błąd = wpis w logu):

### 1. WinPE po Setupie (x86 8 / 8.1 / 10 przez CSMWrap)

* `tools/windows_fast_startup.h` (nowy): edycja offline hive'a
  `X:\Windows\System32\config\SYSTEM` — wzorzec jak `windows_csmwrap_hide.h` /
  `windows_display_register.h` (`RegLoadKeyW` pod `HKLM\USOS_FASTSTARTUP`,
  `Select\Current` → `ControlSet00N`, zapis `HiberbootEnabled=0`, readback,
  unload). Kody: `USOS_FS_WRITTEN` 0, `USOS_FS_PRESENT` 1, błędy 100+.
  Test hosta: `usos_fast_startup_in_system` na dowolnym kluczu-hive.
* `tools/windows_x86_csmwrap.c`: tryb `faststartup` (nowy) + tryb
  `faststartup-test <klucz HKCU>` (test hosta). `faststartup` czyta wersję
  zainstalowanego jądra (`file_version` na `Windows\System32\ntoskrnl.exe`) —
  Vista / 7 (NT 6.0 / 6.1) nic nie robią; dalej wybiera folder DATA
  (`Windows 8` / `Windows 8.1` / `Windows 10`), sprawdza opcję wyłączenia na
  wszystkich woluminach `C:`–`Z:` i dopiero potem edytuje hive. Exit 0 = zrobione
  / nie dotyczy / opcja wyłączenia, 11 = błąd (tylko log).
* `tools/windows_x86_csmwrap.cmd`: faza `3h` — `usos-x86-csmwrap.exe faststartup`
  po udanym Setupie, przed `:nt60_gate`; `if errorlevel 1 echo ...` — instalacja
  leci dalej.

### 2. Natywna ścieżka UEFI (odpowiedź autounattend)

* `src/flow/answer/autounattend.zig`: `Input.fast_startup_on` (domyślnie
  `false`) i `specializeCommands(...)` dodaje
  `reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f`
  dla rodzin `.windows_8`, `.windows_8_1`, `.windows_10` (`hiberboot()`).
  Server SKU są nietknięte (Fast Startup jest tam ukryty).
* `src/flow/answer/root.zig`: `render(..., fast_startup_on, buffer)` przekazuje
  flagę do generatora (pozostałe ścieżki: `false`).
* `src/platform/uefi/answer_profiles.zig`: `fastStartupOn(system_id)` czyta
  `\Systems\Windows\<wersja>\Unattended\fast-startup-on.txt` z partycji DATA
  (NTFS, `data_volume` + `ntfs.openFile`, jak `theme_loader`) i przekazuje do
  `answer.render`. Brak DATA / brak pliku = wyłączone (zachowanie domyślne).

### Opcja wyłączenia

Pusty plik `Systems\Windows\<wersja>\Unattended\fast-startup-on.txt` na DATA
(np. `Systems\Windows\Windows 10\Unattended\fast-startup-on.txt`) zostawia
ustawienie Windowsa — działa na obu ścieżkach i jest opisany w nagłówkach
pliku `.c` / `.cmd` oraz w tym raporcie.

## Pliki

* `tools/windows_fast_startup.h` (nowy)
* `tools/windows_x86_csmwrap.c` (include + `fast_startup()` + tryby)
* `tools/windows_x86_csmwrap.cmd` (faza `3h`)
* `src/flow/answer/autounattend.zig` (`Input.fast_startup_on`, `hiberboot`, komenda, testy)
* `src/flow/answer/root.zig` (argument `fast_startup_on`)
* `src/platform/uefi/answer_profiles.zig` (`fastStartupOn` + importy)
* `src/tools/answer_main.zig` (nowy argument `render`)
* `tools/tests/test_windows_fast_startup.py` (nowy)
* `docs/ds-fast-startup-2026-10-22.md` (ten raport)

## Testy

* `.\build.bat` w worktree: kroki Zig + 597/597 testów Zig przeszły; całość
  zakończona błędem **tylko** na kroku `micro-linux` —
  `python tools/build_micro_linux.py` dostał `HTTP Error 404` z
  `dl-cdn.alpinelinux.org` (pobieranie pakietów Alpine; sieć/ lustro, nie
  dotyczy tej zmiany).
* `python -m pytest tools\tests\test_answer_render.py -q` — przechodzi.
* `python tools/tests/test_windows_fast_startup.py` — część „wiring" sprawdza
  `windows_fast_startup.h`, wywołanie w cmd, komendę i rodzinę w
  `autounattend.zig` oraz opt-out w `answer_profiles.zig`.

## Czego nie sprawdzono

* **Test hosta hive'a nie został uruchomiony** — `usos-x86-csmwrap.exe`
  (`zig-out\windows-modern\`) nie powstał, bo `build.bat` przerywa na kroku
  `micro-linux` (404). Test pytest sam się wtedy pomija (`pytest.skip`), więc
  po naprawie sieci należy go powtórzyć.
* **Brak testu na sprzęcie / VM**: żadna instalacja Windows 8 / 8.1 / 10 nie
  była zrobiona tą gałęzią; nie sprawdzono, czy pierwszy boot instaluje się
  poprawnie z `HiberbootEnabled=0` (wartość jest ignorowana przy braku
  `hiberfil.sys`, więc ryzyko jest niskie).
* **Goldeny XML** `src/flow/answer/testdata/golden/*windows-8*/8-1*/10*` nie
  zostały zregenerowane (w repo nie ma porównania bajt-po-bajcie w testach:
  `test_answer_render.py` przechodzi), ale nowa komenda w `specialize`
  pojawi się w nich po najbliższym `zig build test` / regeneracji —
  do potwierdzenia po merge'u.
* Aby w ogóle uruchomić `build.bat` w worktree, skopiowałem **tylko**
  kompilator `tools\zig` (177 MB), bez `tools\cache` (16 GB) — build zbudował
  własny cache w worktree.
