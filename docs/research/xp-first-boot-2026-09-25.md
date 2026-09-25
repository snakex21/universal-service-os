# XP po teście 1 na X470: /SOS przy każdym starcie i jednorazowy autochk (2026-09-25)

Test 1 (build B260925-155911-756B569B, pakiet XP 6e776371) przeszedł: czysta
instalacja PL, 31,9 GB, PAE, bez dodatkowego restartu. Zdjęcia użytkownika
pokazały dwie rzeczy do wyjaśnienia.

## (a) + (b) Lista sterowników i tekst zamiast logo = /SOS z nazw plików PAE

**Przyczyna (pewność wysoka).** NTLDR i jądro XP wykrywają przełączniki
rozruchu jako **podciągi** opcji zamienionych na wielkie litery
(`strstr(LoadOptions, "SOS")`, tak samo `NOGUIBOOT`, `BOOTLOG`, `DEBUG`…).
Wpis dodawany przez `pae.exe` v4:

```
... /fastdetect /pae /noexecute=optin /kernel=usospae.exe /hal=usoshal.dll
```

zawiera `SOS` dwa razy (`U`**`SOS`**`PAE.EXE`, `U`**`SOS`**`HAL.DLL`), więc każdy start
wpisu PAE działał jak `/SOS`: NTLDR wypisuje
`multi(0)disk(0)rdisk(0)partition(1)\WINDOWS\system32\DRIVERS\*.sys`, a jądro
pokazuje niebieski ekran z banerem („16 procesory systemowe [32693 MB
pamięci] Jądro wieloprocesorowe”) zamiast logo.

Sprawdzone, że nic innego nie dodaje przełącznika:
- w repozytorium nie ma `/sos` (WINNT.SIF, skrypty, pae.exe, TXTSETUP.SIF);
- `OsLoadOptions = "/fastdetect /noguiboot /nodebug"` w `[SetupData]`
  TXTSETUP.SIF to oryginał Microsoftu (także w EN) i dotyczy tylko rozruchu
  samego Setup;
- `boot.ini` zapisany przez tryb tekstowy Setup w QEMU (pakiet z testu 1):
  `"Microsoft Windows XP Professional" /noexecute=optin /fastdetect`.

To nie była pozostałość diagnostyki 0x50: nazwy `usospae.exe/usoshal.dll`
pochodzą z v4 („własne nazwy wyjściowe”), a podciąg nie był wcześniej
sprawdzany.

**Poprawka (v5, commit e12d9293).** Kopie jądra i HAL mają nazwy
`xpkrnpae.exe` / `xphalpae.dll` (8.3, bez nazw przełączników), wpis:

```
... /fastdetect /pae /noexecute=optin /kernel=xpkrnpae.exe /hal=xphalpae.dll
```

`check_xp_pae.py` sprawdza dokładną listę opcji i brak podciągów `SOS`,
`NOGUIBOOT`, `BOOTLOG`, `BASEVIDEO`, `SAFEBOOT`, `DEBUG`, `3GB`, `ONECPU`,
`NUMPROC`, `MAXMEM`, `BURNMEMORY`, `NOPAE`, `REDIRECT`, `USERVA`, `NOLOWMEM`.
Istniejąca instalacja z wpisem v4 jest rozpoznawana i zostaje bez zmian
(ręcznie: w `boot.ini` zmienić nazwy plików po ich skopiowaniu albo
zainstalować ponownie). Pakiet PL po zmianie: `initramfs-xp` 7acfac22…,
`pae.exe` 4d1d0703…, jedyna zamierzona różnica względem 6e776371 to
`xp-pae.exe` (plus aktualizacja bazy `usos-fb-ui` z ID buildu); dysk
przygotowany w QEMU różni się od baseline wyłącznie plikiem `USOS\XP\pae.exe`.
Do potwierdzenia na X470: logo XP przy starcie, 31,9 GB, PAE.

## (c) Jednorazowy autochk na D: i C:

**Co jest D:.** Pendrive USOS ma GPT, a XP 32-bit nie czyta dysków GPT, więc
ani DATA, ani WORK, ani ESP sticka nie dostają litery w XP. Układ USOS na
dysku docelowym ma jedną partycję (`layout=single-volume … Windows=C:`), a
istniejące partycje są zachowane. D: to więc **inna partycja MBR na X470**:
wcześniej istniejąca partycja dysku docelowego albo partycja innego dysku.

**Czy to USOS (pewność wysoka, że nie).**
- Przygotowany przez USOS dysk jest czysty: `$Volume` flags = 0 (bez DIRTY)
  w obrazach QEMU przygotowanych przed M4 i po M4 oraz po trybie tekstowym
  (`tools/tests/ntfs_volume_flags.py`).
- mikro-Linux montuje zapisywalnie tylko nową partycję docelową (ntfs3),
  odmontowuje ją, robi `blockdev --flushbufs` i ponowny montaż tylko do
  odczytu (`xp_verify_target.sh`). DATA jest montowana `ro`, WORK w ścieżce XP
  nie jest dotykana, inne dyski są tylko czytane (snapshot tabel partycji).
- `pae.exe` podmienia `boot.ini` przez `MoveFileEx(... WRITE_THROUGH)`, bez
  twardego restartu.

**Najbardziej prawdopodobna przyczyna (pewność średnia).** Bit „dirty” na
dwóch woluminach naraz przy jednym starcie oznacza, że XP albo inny system
nie zakończył ich czysto:
1. twardy reset / wyłączenie przy zamontowanych C: i D:, np. znany niestabilny
   restart X470 (z testu Windows 10) albo wyłączenie przyciskiem;
2. albo start innego systemu (np. Windows 10 z drugiego dysku), który
   zamontował te woluminy i zostawił je nie w pełni zamknięte (szybkie
   uruchamianie Windows 8+ na woluminach widocznych dla XP powoduje sprawdzanie
   dysku w starszym Windows).
Rozstrzygnie to pytanie do użytkownika, czy między tymi startami był twardy
restart albo start Windows 10. Autochk zgłosił „wolny od błędów”, więc nie ma
uszkodzeń. Poprawka w USOS nie jest potrzebna.
