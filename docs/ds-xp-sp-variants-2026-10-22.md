# Windows XP RTM / SP1 / SP2 na ścieżce XP (x86, PL/EN) — analiza i przygotowanie

Data: 2026-10-22 · Gałąź: `ds/xp-sp-variants` · Worktree: `C:\Users\ASRock\usos-work\ds-xp-sp-variants`
Baza: `test/x470-98se-qemu` (eac23cf5). Zakres: **bez instalacji**, bez pobierania ISO, bez dotykania nośników.

## 1. Co zrobione

| # | Zmiana | Plik |
|---|--------|------|
| 1 | Rozpoznanie poziomu service packa XP z markerów korzenia nośnika (`ServicePack`, `sp_markers`, `servicePack()`, `Info.service_pack`, `Source.service_pack`) + test Zig | `src/image_probe/windows_legacy_media.zig` |
| 2 | `usos_xp_media_service_pack()` i komunikat preflightu sterowników nazywający wykryty poziom nośnika (RTM/SP1/SP2/SP3/unknown); bramka zachowana bez zmian (nadal wymaga `WIN51IP.SP3`) | `tools/xp_driver_stage.sh` |
| 3 | Test pytest nowego helpera i komunikatu (12 przypadków) | `tools/tests/test_xp_driver_service_pack.py` |
| 4 | Ten raport | `docs/ds-xp-sp-variants-2026-10-22.md` |

Bramka SP3 nie została rozluźniona: XP RTM/SP1/SP2 nadal są odrzucane w profilu `xp-x86-sp3-uefi-csm`,
ale komunikat mówi teraz, jaki poziom nośnika wykryto, zamiast sugerować, że nośnik jest nieznany.

## 2. Ustalenia o ścieżce XP

### 2.1 Routing nie patrzy na zawartość nośnika

`src/catalog/os_profiles.zig:268` — profil `xp-x86-sp3-uefi-csm` jest wybierany po
`system.id == "windows-xp"` + `iso` + `automatic` + `uefi`. „sp3” występuje **tylko w identyfikatorze**;
żadna reguła nie sprawdza nośnika. `src/catalog/os_profiles.zig:269` (`xp-uefi-other`) odrzuca każde
inne wywołanie XP z UEFI, a `src/catalog/os_profiles.zig:96` (traits `windows-xp`) nadaje answer
`winnt_sif`, `nt5_staging` i `usos-xp.ini` niezależnie od wersji. Wariant CSMWrap
(`src/catalog/os_profiles.zig:314`) dziedziczy to samo.

Wniosek: **każde** XP x86 (RTM/SP1/SP2/SP3) trafia w ten sam profil i ten sam staging.

### 2.2 Rozpoznawanie wersji ISO/systemu

`src/image_probe/windows_legacy_media.zig` (`inspect`, linia 60) wyprowadza `system_id` z
`SetupData MajorVersion/MinorVersion` (5.1 → `windows-xp`, plus warianty `windows-xp-mce` /
`windows-xp-tablet`), a `version` z wersji pliku setupu, `DOSNET.INF [Version] DriverVer` lub
`SetupData BuildNumber`. **RTM, SP1, SP2 i SP3 mają build 2600**, więc przed tą zmianą poziomu SP nie
dało się odróżnić w ogóle — w repo nie było żadnego pojęcia service packa.

Dodane teraz: `ServicePack` (`none` = RTM, `sp1`, `sp2`, `sp3`, `unknown`), lista `sp_markers`
(`WIN51IP.SP3`, `WIN51IP.SP2`, `WIN51IP.SP1`) i `servicePack(context, exists)` — Setup sam sprawdza te
markery, więc są jedynym wiarygodnym źródłem. `Info.service_pack` jest przenoszony przez `inspect()`.

### 2.3 Co USOS zakłada o źródle instalacyjnym

- `tools/prepare_xp_local_source.sh:22-30` wymaga tylko: `I386\DOSNET.INF`, `I386\SETUPLDR.BIN`,
  `I386\NTDETECT.COM`, `I386\TXTSETUP.SIF`, `I386\USETUP.EXE`. **Markery `WIN51*` nie są wymagane**,
  więc RTM/SP1/SP2 przechodzą ten preflight bez zmian.
- Źródło jest kopiowane w całości do `$WIN_NT$.~LS/I386` (`prepare_xp_local_source.sh:79`), drzewo
  `$WIN_NT$.~BT` budowane z `[FloppyFiles.*]` pliku `DOSNET.INF` (`:43-65`).
- `tools/prepare_nt5_media_markers.sh:6` stage'uje markery **tylko dla Windows 2000**
  (`CDROM_NT.5`, `CDROM_IP.5`, `CDROMSP4.TST`). Dla XP nic nie jest przenoszone — XP Setup weryfikuje
  `WIN51IP[.SPn]` na źródle; przy źródle lokalnym na docelowym NTFS nie jest to sprawdzone (ryzyko,
  sekcja 5).
- `I386\winnt32.exe` nie jest wywoływane przez USOS — staging przygotowuje `$WIN_NT$` i answer file,
  text-mode Setup startuje z `SETUPLDR.BIN` (`WINNT.SIF [Data] msdosinitiated=1, floppyless=1`).
  Nie ma więc zależności od składni `winnt32 /unattend:` poszczególnych SP.
- Sterowniki: **slipstream, nie F6**. `tools/xp_driver_stage.sh:35-53` usuwa stare warianty plików
  (`*.SYS`/`*.SY_`), kopiuje `I386/*` bundla do `~BT` i `~LS/I386` i podmienia `TXTSETUP.SIF`.
  W repo nie ma `txtsetup.oem` ani `$OEM$\TEXTMODE` — ścieżki „F6 z dyskietki" **nie ma**.
  Bundle jest przypięty do konkretnego ISO przez `source.sha256` (`xp_driver_stage.sh:14`, `:19`),
  dlatego zmiana poziomu SP = brak pasującego bundla (STOP, nie cicha podmiana).
- PAE: `tools/prepare_xp_ntfs_target.sh:69-70` kopiuje `pae.exe` do `USOS\XP`, a answer
  (`tools/xp_selected_partition_uefi_csm.sif:21-24`) uruchamia go przez `[SetupParams] UserExecute`
  i `[GuiRunOnce]`. Wpis boot.ini: `/PAE /NOEXECUTE=OPTIN /KERNEL=XPKRNPAE.EXE /HAL=XPHALPAE.DLL`
  (`tools/tests/check_xp_pae.py:65,72`). Konta z `usos-xp.ini` obsługuje ten sam helper
  (`prepare_xp_ntfs_target.sh:73-79`), napisy z `lang-xp.ini` z ESP (`:82-85`).

### 2.4 Profile odpowiedzi WINNT.SIF

Plik bazowy `tools/xp_selected_partition_uefi_csm.sif` (24 linie) jest **jeden dla wszystkich XP**:
`[Data] msdosinitiated/floppyless/InstallDir/EulaComplete`, `winntupgrade="no"`,
`win9xupgrade="no"`, `[Unattended] DriverSigningPolicy=Ignore`, `FileSystem=LeaveAlone`,
`TargetPath=\WINDOWS`, `[SetupParams] UserExecute="C:\USOS\XP\pae.exe"`, `[GuiRunOnce]`.

- `UnattendMode` jest nadpisywany: `FullUnattended` gdy podano klucz, `DefaultHide` w przeciwnym razie
  (`tools/xp_user_settings.sh:177,186`).
- `ProductKey` jest dopisywany **tylko** gdy klucz podano; Windows 2000 dostaje `ProductID`
  (`tools/xp_user_settings.sh:207`). Format klucza: `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`
  (`tools/xp_user_settings.sh:87`) — identyczny dla RTM/SP1/SP2/SP3, więc profile się tu nie różnią.
- `Win9xUpgrade` nie jest polem profilu — jest na stałe `"no"` w `[Data]` (linia 8 pliku .sif).
  To działa na każdym SP (dotyczy tylko ścieżki aktualizacji z 9x, której USOS nie używa).
- Pola zależne od SP (np. `[MassStorage]`, `OemPnpDriversPath`, `[Components]` z SP2+) nie są używane.
  `[Components]`/`[Shell]`/`[Display]` pojawiają się tylko z tweaków profilu (`nt5.zig:78-89`).

**Odpowiedź na pytanie z zadania:** profile WINNT.SIF nie różnią się między RTM/SP1/SP2 — różni się
tylko to, co USOS dokłada (stery SP3, PAE), a tego RTM/SP1/SP2 nie przyjmą.

## 3. Tabela: wersja → co zadziała / co trzeba dodać / ryzyko

Dotyczy XP x86, PL i EN tak samo (markery `WIN51IP[.SPn]`, build 2600 i format klucza są
identyczne; PL różni się tylko `TXTSETUP.SIF [nls] DefaultLayout` → domyślna strefa czasu
`xp_user_settings.sh:12,89-90` oraz `lang-xp.ini` dla napisów `pae.exe`).

| Wersja | Co zadziała | Co trzeba dodać | Ryzyko |
|--------|-------------|-----------------|--------|
| **RTM** (5.1.2600, marker tylko `WIN51IP`) | Preflight źródła (`DOSNET/SETUPLDR/NTDETECT/TXTSETUP/USETUP`), staging NTFS + `$WIN_NT$`, answer `WINNT.SIF` (ProductKey, konta, strefa, tweaki), start text-mode z `SETUPLDR.BIN` | Nowy profil/ścieżka bez bundla SP3 (`os_profiles.zig:268`), wykrywanie SP w routingu, obsługa trybu IDE (brak AHCI), sterownik EHCI (USB 2.0 tylko od SP1), limit 137 GB, osobna decyzja o PAE | Wysokie: dysk SATA/AHCI nie zostanie wykryty przez text-mode Setup; dysk >137 GB obcięty; USB tylko 1.1; `pae.exe` z `/NOEXECUTE` bez efektu (DEP jest od SP2) |
| **SP1** (2600.1106, `WIN51IP.SP1`) | wszystko z RTM + natywny EHCI (USB 2.0) + 48-bit LBA powyżej 137 GB | To samo co RTM, ale bez limitu 137 GB; nadal brak AHCI i brak bundla SP3 | Średnie: SATA/AHCI, brak sterowników masowych; `pae.exe` bez DEP |
| **SP2** (2600.2180, `WIN51IP.SP2`) | wszystko z SP1 + DEP/`/NOEXECUTE`, Security Center; text-mode Setup stabilny | Najmniejsza luka: potrzebny bundle sterowników zgodny z SP2 (`source.sha256`), bo obecny jest SP3-only (`xp_driver_stage.sh:31`) | Średnie: brak AHCI/USB3/KMDF z bundla; ryzyko sterowników tekstowych |
| **SP3** (2600.5512, `WIN51IP.SP3`) — stan obecny | pełna ścieżka: bundle ACPI+SATA+USB3+KMDF, PAE, konta, weryfikacja read-only (`prepare_xp_ntfs_target.sh:61-95`) | — | Potwierdzone wcześniej; poza zakresem tej analizy |

## 4. Nośniki / ISO, których brakuje (NIE pobierano)

Do pokrycia macierzy potrzebne są 4 wersje x86 Professional, każda w PL i EN (8 nośników):

1. **Windows XP Professional RTM, x86, EN** — Volume/OEM, build 2600.0, marker tylko `WIN51IP`
   (MSDN: „Windows XP Professional (5.01.2600.0)"; OEM: „XRMPVOL_EN").
2. **Windows XP Professional RTM, x86, PL** — OEM/BOX PL, build 2600.0.
3. **Windows XP Professional SP1, x86, EN** — build 2600.1106, marker `WIN51IP.SP1`
   (MSDN „…with Service Pack 1"; OEM „XRMPVOL_EN" ze zintegrowanym SP1a).
4. **Windows XP Professional SP1, x86, PL** — build 2600.1106.
5. **Windows XP Professional SP2, x86, EN** — build 2600.2180, marker `WIN51IP.SP2`.
6. **Windows XP Professional SP2, x86, PL** — build 2600.2180.
7. **Windows XP Professional SP3, x86, PL** — brakująca regresja: obecny bundle jest przypięty
   przez `source.sha256` do jednego ISO (`media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86`);
   bez PL SP3 nie da się sprawdzić, czy ścieżka PL w ogóle przechodzi `source.sha256 -c`.
8. **Windows XP Professional SP3, x86, EN** — jeśli obecne ISO w `media/` nie jest EN (do potwierdzenia
   w repo; nie sprawdzano sum).

Nie są potrzebne do tej analizy: XP Home (SKU), XP MCE/Tablet (warianty potwierdzone), XP x64 / Server
2003 (NT 5.2, inna ścieżka), XP SP1a/SP2b (te same markery co SP1/SP2, inne tylko `winnt32`).

Dodatkowo, jeśli ścieżka ma być testowana bez CSM: **CSMWrap 3.1.2-usos1** jest już w repo jako
przypięty artefakt (`tools/xp_csmwrap_esp.sh:6-8`) — nie trzeba pobierać.

## 5. Propozycje zmian w kodzie (pliki:linia)

Wykonane w tym commicie oznaczono **[ZROBIONE]**.

1. **[ZROBIONE] `src/image_probe/windows_legacy_media.zig:7-43`** — `ServicePack`, `sp_markers`,
   `servicePack()`, `Info.service_pack`, `Source.service_pack` + test.
2. **[ZROBIONE] `tools/xp_driver_stage.sh:9`** — `usos_xp_media_service_pack()`; `:31` komunikat
   preflightu z wykrytym poziomem.
3. `src/image_probe/probe.zig` (wywołanie `windows_legacy_media.inspect`) — przekazać wynik
   `servicePack()` z korzenia ISO (probe musi zobaczyć katalog główny; dziś czyta tylko SIF/INF).
   Bez tego `Info.service_pack` zostaje `null` w produkcji.
4. `src/catalog/os_profiles.zig:268` — rozdzielić `xp-x86-sp3-uefi-csm` na warianty SP-aware
   (np. `xp-x86-rtm-uefi-csm` bez bundla) albo dodać do `Profile` pole `requires_service_pack`
   i walidację po probe. Duża zmiana routingu — **nie zaczynana**, wymaga decyzji o golden
   `src/flow/testdata/routing_golden.tsv`.
5. `src/catalog/os_profiles.zig:96` — nowe pole traits (np. `min_service_pack`) + ostrzeżenie
   w podsumowaniu menu, gdy nośnik jest starszy niż profil.
6. `tools/prepare_xp_ntfs_target.sh:61` — warunek `xp_driver_stage.sh apply` uzależnić od wykrytego
   SP3 (dziś tylko od nazwy profilu); dla SP2 albo osobny bundle, albo świadome pominięcie.
7. `tools/prepare_nt5_media_markers.sh:6` — rozszerzyć staging markerów na XP (`WIN51`, `WIN51IP`,
   `WIN51IP.SPn`), jeśli okaże się, że lokalne źródło na NTFS wymaga markerów w korzeniu.
8. `tools/xp_disk_overview.sh` / `tools/xp_verify_target.sh` — walidacja „dysk > 137 GB wymaga SP1"
   i „AHCI wymaga sterownika tekstowego" przed startem instalacji (dziś brak jakiejkolwiek kontroli).
9. `src/flow/answer/nt5.zig:48` — pole `service_pack` w profilu odpowiedzi i ostrzeżenie w podsumowaniu
   (rendering WINNT.SIF sam nie wymaga zmian: pola są wspólne dla RTM–SP3).
10. `src/platform/uefi/xp_preparation.zig:181` — pokazać wykryty SP w podsumowaniu UEFI obok wariantu
    PAE/CSMWrap, żeby użytkownik wiedział, który nośnik trafi na dysk.

## 6. Testy i build

| Sprawdzenie | Wynik |
|-------------|-------|
| `tools\zig\zig.exe build test --summary all` | **598/598 testów passed**, 62/62 kroków (w tym nowy test `XP service level comes from the disc root markers`) |
| `python -m pytest tools\tests\test_xp_driver_service_pack.py -q` | **12 passed** (markery RTM/SP1/SP2/SP3, wariant lowercase, „najwyższy marker wygrywa", komunikat preflightu dla RTM/SP1/SP2/unknown, SP3 przechodzi bramkę wersji) |
| `.\build.bat` | 96/98 kroków, 598/598 testów; **`micro-linux` padł na `HTTP Error 404` z `dl-cdn.alpinelinux.org`** (paczka `alpine/v3.24/...` w `tools/build_micro_linux.py:48`) — awaria sieci/CDN, nie ta zmiana |

## 7. Czego nie sprawdzono

- Nie pobrano i nie uruchomiono **żadnego** nośnika RTM/SP1/SP2 (zadanie tego zabraniało) — tabela
  w sekcji 3 jest analizą kodu i dokumentacji, nie wynikiem testu instalacji.
- Nie testowano w QEMU instalacji z RTM/SP1/SP2, więc nie wiadomo, czy text-mode Setup przyjmie
  przygotowany `$WIN_NT$` bez markerów `WIN51*` w korzeniu wolumenu docelowego.
- Nie sprawdzono nośników PL (brak ISO); nie potwierdzono sum obecnego ISO SP3 w `media/`.
- Nie sprawdzono zachowania HAL/ACPI na RTM (brak podmiany HAL w repo — jest tylko dla NT3/NT4).
- Nie sprawdzono dysku >137 GB ani kontrolera AHCI na żadnym SP.
- `micro-linux` nie zbudował się z powodu 404, więc pełny obraz USB nie powstał; wszystko przed tym
  krokiem (łącznie z `install`, `selftest`, `qemu-x86_64-manual-image`) przeszło.
