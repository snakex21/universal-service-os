# Pakiet XP UEFI-CSM a język ISO (PL x14-80476 vs EN x14-80428), 2026-09-25

Kontekst: refaktor M4 ([../design/refactor-os-pipeline.md](../design/refactor-os-pipeline.md))
buduje pakiet XP jako **bazę mikro-Linuksa + pae.exe + pakiet sterowników
wyprowadzony z ISO użytkownika**. Decyzja produktowa (2026-09-25): wydanie 1.0
dostarcza gotowy pakiet dla PL XP SP3 (potwierdzony na X470); dla innych ISO
pakiet jest budowany z ISO użytkownika tymi samymi łatkami USOS (PAE,
sterowniki SATA/AHCI/USB3, skrypty), żeby język i pliki zgadzały się z ISO.
Port skryptu Pythona do Go (instalator) jest osobnym zadaniem.

## Źródła

| ISO | SHA-1 | SHA-256 |
|---|---|---|
| `pl_windows_xp_professional_with_service_pack_3_x86_cd_x14-80476.iso` | – | `bd323425…ff0b` |
| `en_windows_xp_professional_with_service_pack_3_x86_cd_x14-80428.iso` (617 756 672 B) | `1C735B38931BF57FB14EBD9A9BA253CEB443D459` = opublikowany hash MSDN | `62b6c915…2a46` |

## Wynik budowania (gałąź `refactor/os-pipeline`, baza M4)

- PL: dwa buildy bajtowo identyczne (`initramfs-xp` e1b7dd9e…). Względem
  wdrożonego pakietu (d55971bf…, B260925-143728): 754 identyczne wpisy (oba
  pakiety sterowników, hive'y, kabinety, pae.exe bab558bb…), 9 aktualizacji
  bazy (pipeline, `xp_selected_partition_uefi_csm.sif`, usos-fb-ui,
  `prepare_xp_windows_partition.sh`), 4 zamierzone (skrypty z gałęzią profilu
  zamiast podmian tekstu), **0 niewyjaśnionych**.
- EN: dwa buildy identyczne (`initramfs-xp` 9c2b0899…, pakiet sterowników
  26206170…). check_xp_pae (łatka PAE jądra/HAL z EN ISO), check_xp_driver_imports,
  check_xp_menu_overlay, check_xp_driver_integration: PASS. QEMU (TCG,
  SeaBIOS): przygotowanie dysku PASS (7106 plików, 0 zerowych, weryfikacja
  read-only), angielski tryb tekstowy Setup aż do kopiowania plików. Harness
  nie prowadzi GUI Setup ani stanu końcowego PAE — to zostaje na X470.

## Co zależy od języka ISO

Pakiet sterowników ma 29 plików; 21 jest identycznych dla PL i EN, 8 różnych:

| Plik w pakiecie | PL = EN? | Dlaczego |
|---|---|---|
| `I386/TXTSETUP.SIF` | różny | kopia pliku z ISO (zlokalizowane `[Strings]`, listy plików/układów klawiatury); zmiany USOS (79 linii: sekcje sterowników SATA/USB3, ACPI) są **identyczne** w obu |
| `I386/DOSNET.INF` | różny | lista plików do skopiowania z ISO różni się między językami; 35 linii USOS identycznych |
| `I386/HIVESYS.INF` | różny | zlokalizowane nazwy wyświetlane i wartości z ISO (PL 21 699 linii, EN 15 585); 48 linii USOS (usługi sterowników, `CrashDumpEnabled=0`) identycznych |
| `I386/SP3.CAB` | różny | kabinet SP3 z ISO: 143 z 368 plików ma inne bajty (zasoby wersji/komunikaty zlokalizowane także w sterownikach, np. `amdk6.sys`, `adv*.dll`); USOS podmienia tylko `acpi.sys`, i ta podmiana jest identyczna |
| `I386/USBD.SY_` | różny kontener | rozpakowany `usbd.sys` jest identyczny; różnią się tylko metadane kabinetu (data/czas CFFILE), które `compare_xp_packages.py` traktuje jako równoważne |
| `manifest.json`, `payload.sha256`, `source.sha256` | różne | zapisują hash ISO i plików pakietu |
| `I386/SETUPREG.HIV` | **identyczny** | oryginały w PL i EN są już identyczne (SHA-256 8ba8512e…), a łatka hive jest ta sama |
| sterowniki `GENAHCI`, `USBXHCI`, `USBHUB3`, `WDF01000`, `STORPORT`, `NTOSKRN8`, `KSECD8`, `ACPI.SY_`, … | identyczne | dostarczone przez USOS (tools/vendor), niezależne od ISO |

Poza pakietem sterowników: skrypty, `pae.exe`, licencja, `xp_selected_partition_uefi_csm.sif`
i jądro są identyczne. WINNT.SIF nie zawiera ustawień regionalnych, więc jest
wspólny dla wszystkich języków. Język komunikatów `pae.exe` pochodzi z
`lang-xp.ini` instalatora USOS, a nie z ISO.

Wniosek: pliki zależne od języka to te, które USOS **edytuje w kopii z ISO**
(TXTSETUP.SIF, DOSNET.INF, HIVESYS.INF, SP3.CAB). Dlatego pakiet dla innego
ISO musi być budowany z tego ISO; gotowy pakiet PL nie pasuje do EN (i
odwrotnie). Łatki USOS są w obu przypadkach te same linia w linię.

Nie wdrożono pakietu EN na pendrive.
