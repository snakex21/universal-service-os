# RAPORT-W95RTM-FIRSTBOOT — poprawka wersji Win9x i hotpatch, 2026-10-26

**PASS zakresu kod/testy/build/hotpatch. Build `B261026-144334-F0539FB7`: 104/104, 632/632 i verify_release_consistency PASS. STOP.**

Gałąź `codex/w95-firstboot`. Kod `715d94ae`, zweryfikowany payload `6b81dac2`. Nowe zlecenie dotyczy poprawki po teście X470 i podmiany helperów na istniejącym dysku. Nie wykonano nowej instalacji ani QEMU; test po poprawce i wznowienie koordynatora na X470 wykona Claude. Pełny pierwszy pulpit po tej poprawce pozostaje do sprawdzenia na X470 — nie jest tutaj oznaczony PASS.

## Dowód z X470 przed poprawką

Zgłoszenie użytkownika/Claude dla `B261026-121414-3132FCB5`: faza1, DOS, Setup, jedna karta po VLATE/DELKEY, GRPCONV5,5s, TZ/DST i DHCP I211 PASS. Odczytano wyłącznie kopię scratchpad `w95rtm-kingston1/micron/USOS9X`. `FIRSTBT.LOG` potwierdza start USOSRES/setup przy tick13436 i błąd przy13440; `FIRSTBT.ERR`: „display request not applied before packages”; `USOSRES.LOG` brak. SHA i tekst czterech małych plików w `artifacts/firstboot/version-fix-x470-evidence.json`. To dowód dostarczonego przebiegu X470, nie uruchomienie sprzętu przez tę sesję.

## Zmieniony kod i audyt GetVersion

| Źródło | Wynik |
| --- | --- |
| `tools/windows_usos_res.c` — bramka /setup | Zamiast GetVersion>>16: sprawdzane GetVersionExA, VER_PLATFORM_WIN32_WINDOWS,4.0 i LOWORD(dwBuildNumber)=950, zgodnie z USOSFB. OSR1 pozostaje w rodzinie950. Brak API/inna platforma/inna wersja/marker: odmowa2 z powodem. |
| Ten sam helper — USOSRES.LOG | Otwarty w katalogu EXE przed bramką wersji i markerami, dopisywanie do istniejącego logu. Rejestrowane wejście/setup, platforma/wersja/build, przyczyna i końcowy exit. Jedno leave() zapisuje kod, FlushFileBuffers i zamyka log dopiero na końcu. DISPLAY.DONE, brak/odczyt profilu i dalsze wyjścia też są opisane. Przy niemożności rozpoznania katalogu lub utworzenia logu helper odmawia zmian; nie zapisuje danych do profilu użytkownika. |
| `tools/windows_usos_lan.c` — native_config | GetVersionExA i maska0xffff rozróżniają1998/2222. Brak API, NT lub nieobsługiwana wersja nie tworzą NETCFG. |
| `tools/windows_usos_lan.c` — native95_handoff; `src/platform/win32_legacy/usosfb.c` | Już poprawne GetVersionExA + LOWORD i platforma; bez zmiany. |
| `src/platform/win32_legacy/usosadd/main.c` | Build już pochodzi z GetVersionExA i maski0xffff. Jedyny GetVersion wybiera rodzinę katalogu po bicie31; bez błędu. |
| `tools/display_compat.h` i pozostałe GetVersion w USOSRES | Rozmiar DEVMODE, major/minor, polityka NT i bit platformy; brak dekodowania kompilacji Win9x. Pozostawione, importy starszych NT nadal PASS. |
| `src/platform/bios/win9x/usoslog_compat.h` i kopie NT3/NT4 | Najpierw dynamiczne GetVersionExA. Fallback odczytuje górne słowo tylko wewnątrz gałęzi NT (bit31=0), a dla Win9x nie udaje znajomości builda. Poprawne, bez zmian. |
| Pozostałe własne Win32 C/H/CPP/Zig | Pełne przeszukanie śledzonych źródeł: narzędzia NT3 zapisują surowe GetVersion albo major/minor, Vista/XP używają wersji rozszerzonej. Pozostałych błędów tego typu nie znaleziono. Win16 GetVersion w usosmous/usoskey ma inną semantykę i nie jest narzędziem Win32. Kod vendorów i zamknięte systemy nie były uruchamiane. |

## Regresja hostowa

Atrapy obu API symulują stare GetVersion z samą flagą Win9x w górnym słowie oraz rozszerzone dwBuildNumber z niezerowym górnym słowem. Kompilowany jest rzeczywisty kod narzędzi; nie kopia ich warunków.

| System | GetVersion | GetVersionEx: major.minor / dwBuildNumber | USOSRES/setup po markerach | NETCFG |
| --- | --- | --- | --- | --- |
| 95 RTM |0x80000004|4.0 /0x040003b6 (950)| zaakceptowane |95|
| 95 OSR1 /950a |0x80000004|4.0 /0x040003b6 (950)| zaakceptowane |95|
| 95 OSR2 |0x80000004|4.0 /0x04000457 (1111)| odmowa2 z logiem |95|
| 98 FE |0x80000a04|4.10 /0x040a07ce (1998)| odmowa2 z logiem |98|
| 98 SE |0x80000a04|4.10 /0x040a08ae (2222)| odmowa2 z logiem |98SE|
| ME |0x80005a04|4.90 /0x045a0bb8 (3000)| odmowa2 z logiem |ME|

- `test_w9x_version_setup.py`:3 testy/19 odrębnych procesów USOSRES. Testy zapisują prawdziwy log i sprawdzają trwały końcowy kod. Obejmują sześć OS, błąd GetVersionExA, NT/major/minor, każdy brakujący marker, DISPLAY.DONE, brak/zerowy/zbyt długi/niepoprawny profil, zajęty RunOnce/Setup i błąd VBE. Registry/ładowanie DLL/proces instalatora są atrapami; ekran i rejestr hosta nie są dotykane.
- Rozszerzony `lan_policy_test.c`: sześć wersji w produkcyjnym writerze NETCFG i native95_handoff oraz brak wersji, NT i nieobsługiwany minor.
- Łącznie `test_display_profile` (bez testu startującego QEMU), `test_network_defaults` i nowa regresja: **54/54 PASS,0 skip**,29,441s; w tym stare importy NT3.5/3.51/4 i no-CRT. Log `artifacts/firstboot/version-fix-host-suite01.log`.
- Kontrola negatywna na poprzednich źródłach4cfba837 z tymi samymi harnessami: USOSRES exit2 i brak logu, LAN exit96 przy błędnej klasyfikacji SE. Poprawiony kod przechodzi. Receipt `artifacts/firstboot/version-negative-control/result.json`.

## Pełny build i spójność

Bez wrappera przechwytującego stderr PowerShell: `cmd /d /c artifacts\firstboot\build08-env.cmd` → cmd/build.bat, BelowNormal, affinity3, Zig -j2 i Go -p2. Oba dowiązania ignorowanych wejść na K zweryfikowano SHA; `artifacts/firstboot/version-fix-build-preflight.json`.

Natywne zakończenie procesu:0. Graf104/104 i632/632, testyGo oraz verify_release_consistency PASS. Początkowy kanał oczekiwania MCP miał własny timeout300s; bez restartu buildu dołączono jednorazowo WaitForExit do tego samego procesu. Nie odczytywano cyklicznie logów ani wyników. Build zachowuje dotychczasowe ostrzeżenie UNSIGNED/brak klucza Secure Boot.

- Build `B261026-144334-F0539FB7`, source SHA `f0539fb76acb46487c6a70663c2f39f3f5b904fe5c4776ac0c5919e8897203d2`.
- Pełny log `artifacts/firstboot/full-build08.log`, SHA `b6fcbc862141f976eef3ca0d20c6c7d471b45d41251b237752f0d38316bce0c7`.
- Receipt `artifacts/firstboot/full-build08.result.json`; `full-build-accepted.json` wskazuje08, wcześniejszy zachowano jako `full-build-accepted-before08.json`.

## Gotowy hotpatch na istniejącą instalację

Katalog: `C:\Users\ASRock\usos-work\codex-w95-firstboot\artifacts\firstboot\hotpatch`. Oba pliki to **Win9x i386 GUI**, wyłącznie kernel32/advapi32, bez CRT. USOSLAN.EXE jest poprawnym wariantem USOSLAN9X.EXE. Porównanie bajtów z zaakceptowanym initramfs: oba PASS; odpowiadają wspólnemu payloadowi release/manual/installer, którego spójność sprawdzono.

| Plik | Bajty | SHA-256 |
| --- | --- | --- |
| USOSRES.EXE | 14336 | `b69dccd128e6d6c46980ddd2140bb9232ab8dd194c682c2d65df04f284a3ac17` |
| USOSLAN.EXE | 17408 | `7db6c57bec4b0d90e6e4db1d616b45414fee9ff86b1e0f4ff3ec6f0bb641ee07` |

Dodatkowo `SHA256SUMS.txt`, `manifest.json` i `README.md`. Docelowe nazwy na istniejącym systemie: `C:\USOS9X\USOSRES.EXE` i `C:\USOS9X\USOSLAN.EXE`. Wdrożenie wykonuje Claude. Koordynator nadal ma dotychczasowe zabezpieczenie: zachowane `FIRSTBT.ERR` i `FIRSTBT.STA=install` blokują automatyczny retry, więc wznowienie wymaga kontrolowanej naprawy tego stanu przez Claude po zachowaniu logów. Nie zmieniano USOSFB ani markerów na X470.

## Pliki, gałąź i zachowane dane

Zmiany tego zlecenia względem4cfba837:8 plików na `codex/w95-firstboot`:

- `tools/windows_usos_res.c`
- `tools/windows_usos_lan.c`
- `tools/tests/lan_policy_test.c`
- `tools/tests/display_setup_test.c`
- `tools/tests/test_w9x_version_setup.py`
- `installer/internal/payload/legacy_boot_generated.go`
- `docs/w95-firstboot-win9x-version-fix-2026-10-26.md`
- `docs/w95-firstboot-win9x-version-fix-evidence-2026-10-26.json`

Raport zadań: `C:\Users\ASRock\Documents\Codex\zadania\RAPORT-W95RTM-FIRSTBOOT.md`. Dokładne receipt i SHA także w `docs/w95-firstboot-win9x-version-fix-evidence-2026-10-26.json`. Hotpatch jest w żądanym katalogu artifacts, poza źródłami śledzonymi Git.

Poprzednie wyjście07 i instalator zachowane w `K:\USOS-VM\W95RTM-FIRSTBOOT-20261025\build-output-07-retained-for-version-fix`. Bazy i VM bez zmian. Inwentaryzacja po zakończeniu: **120 obrazów/nośników/vars zachowanych,0 usuniętych**, pula9.534/150GiB, wolneK134.659GiB przy rezerwie100GiB; pomiar2026-10-26T14:52:03.170307+00:00 (15:52Warsaw). Pełna lista `artifacts/firstboot/version-fix-retained-images.json`. Lista usuniętych obrazów/dowodów: pusta.

**STOP po raporcie. Nowych QEMU0, instalacji0, fizycznych wdrożeń0. MiniOS/w95-vesbind bez zmian, bez merge/push/deploy.**
