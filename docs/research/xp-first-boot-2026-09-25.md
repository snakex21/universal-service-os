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

## Aktualizacja 2026-09-25 wieczorem: autochk przy każdym starcie

Po teście 1 użytkownik zgłosił autochk na C: (i D:) przy **każdym** starcie,
także bez dysku D:. Test 2 na X470 (build B260925-190925, pakiet XP z pae.exe
v5, EN x14-80428 + usos-xp.ini) nie pokazał autochk przy 2–3 czystych
startach, razem z zniknięciem ekranów /SOS. Stan: **rozwiązane, do
obserwacji**.

Sprawdzone w VirtualBox (PL x14-80476 i EN x14-80428, instalacja bez pytań,
3 GB i 6 GB RAM, po 3 starty + twardy reset): za każdym razem logo XP, brak
autochk, `$Volume` flags = 0 po każdym zamknięciu, `BootExecute = autocheck
autochk *`, `CrashDumpEnabled = 0`, `SystemStartOptions = FASTDETECT PAE
NOEXECUTE=OPTIN KERNEL=XPKRNPAE.EXE HAL=XPHALPAE.DLL`. VirtualBox ma inny
kontroler (PIIX4 IDE) niż X470.

Czy /SOS mógł to powodować: nie znalazłem dokumentacji, że `/SOS` zmienia
decyzję autochk (ta zależy od bitu dirty i BootExecute). Pewne jest tylko, że
v4 startował jak z `/SOS` (tekstowy ekran), a autochk zniknął razem z tą
zmianą; mechanizm pozostaje niepotwierdzony. Jeśli wróci: `fsutil dirty query
C:` po zalogowaniu i przed zamknięciem, `chkntfs C:`, BootExecute, zdarzenia
Ntfs/Disk w Podglądzie zdarzeń.

## Jednorazowy STOP 0x0A po resecie (X470, test 2)

Kontekst: pierwsza sesja po instalacji EN x14-80428 (build B260925-190925),
przycisk RESET na obudowie (twardy reset), niebieski ekran przy **następnym**
starcie: `IRQL_NOT_LESS_OR_EQUAL`, STOP 0x0000000A (0x0D939AEC, 0x00000002,
0x00000000, 0x8050923A). Kolejne resety bez błędu; **nie da się powtórzyć**,
analiza przerwana.

Co wiadomo: przy zwykłej bazie jądra XP SP3 (0x804D7000) adres 0x8050923A to
RVA 0x3223A w `ntkrpamp.exe` 5.1.2600.5512 = `MmMapLockedPagesSpecifyCache+0x214`,
instrukcja `mov edx,[ebx+0Ch]` z `ebx = PFN*0x1C + MmPfnDatabase` (odczyt
atrybutu cache z bazy PFN). Odczyt spod 0x0D939AEC przy IRQL 2 oznacza PFN
spoza bazy PFN w MDL, które sterownik mapował na DISPATCH_LEVEL (sterownik
nazwany nie jest, bo IP jest w jądrze). Kandydaci bez rozstrzygnięcia:
sterowniki DMA po ciepłym resecie (backport usbxhci/ucx01000, GenAHCI przez
ntoskrn8, karta sieciowa/GPU), acpi.sys 7777.8. VirtualBox (PL i EN, 6 GB,
`controlvm reset` na ekranie powitalnym) nie odtworzył błędu.

Zrzut pamięci: `CrashDumpEnabled` zostaje **0**. STOP 0x50 w
`dump_ntoskrn8.sys` z 2026-09-22 wystąpił przy `CrashDumpEnabled=3`, czyli
właśnie przy małym zrzucie (64 KB): stos zrzutu (kopia `dump_` sterowników
dysku z importem ntoskrn8) jest ładowany przy starcie niezależnie od rozmiaru
zrzutu, a wymuszone wyłączenie po tym STOP zostawiło wyzerowane pliki WinSxS.
Mały zrzut nie jest więc bezpieczny na tym stosie sterowników. Komentarz w
`windows_xp_pae.c` („full dump”) jest nieprecyzyjny: chodziło o stos zrzutu,
nie o jego rozmiar. Zanim zrzuty zostaną włączone, stos trzeba sprawdzić w
QEMU z AHCI + GenAHCI (np. `CrashOnCtrlScroll` na klawiaturze PS/2).
