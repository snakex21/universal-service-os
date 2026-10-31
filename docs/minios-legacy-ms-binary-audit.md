# MiniOS — audyt SYS/CER przed integracją

<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
## Aktualny audyt 1c-0 — 2026-10-25

Target integracji: **0ba50f6ec7cc6256c2f43ace4d1bbae915952955**,
zweryfikowany z rzeczywistego drzewa master wskazanego przez użytkownika.
Końcowe dane: `minios-legacy-ms-binary-audit-1c0-final.json`
(branch `71fdb8bc`; payload bez zmian po audycie pierwotnym). Odtwarzanie:
`tools/minios/audit_legacy_payload.py --repo <branch-repo> --master-repo <target-repo> --master-ref 0ba50f6e --out <new-report.json>`.

Branch `71fdb8bc` śledzi 74 SYS/CER, target 34. W branch jest 40 ścieżek
nieobecnych w target. Z 29 historycznych ścieżek media/Windows **28 ma ten
sam Git blob w obu drzewach**. Nieobecny w target jest jeden:
`media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x64/ACPI/acpi.sys`
(SHA-256 `2aaac644abd3b94d8e1f41d1ea98ba88a18fe8c7273ba423796f0fdac20b6202`).
Nie należy go ponownie dodawać przy integracji MiniOS. To rzeczywisty wynik
odczytu przypiętych drzew, bez założenia, że target usunął wszystkie SYS.

Dodatkowo `src/platform/bios/msdos/windows_config.sys` jest tekstowym plikiem
konfiguracji i różni się pomiędzy drzewami. Pozostałe branch-only ścieżki
obejmują własne sterowniki i vendored payload; rozszerzenie SYS nie ustala
pochodzenia. JSON podaje każdą ścieżkę, Git blob, rozmiar i SHA-256.

Audyt wyłącznie czyta Git, bez fetch/checkout/merge, kopiowania payloadu,
usuwania plików lub instalowania certyfikatów. Obecność pliku w target nie
stanowi oceny licencji lub autentyczności.

## Archiwalny audyt 1b-2 (stary master; nie jest targetem integracji)

Poniższa sekcja zachowuje historyczne piny i szczegółową klasyfikację.
Wnioski o obecności w master odnoszą się w niej wyłącznie do `275696db`;
przed integracją obowiązuje powyższy audyt `0ba50f6e`.

2026-10-24. Tylko odczyt Git i metadanych istniejących plików. Bez usuwania,
merge, zmiany binariów, uruchamiania zamkniętych systemów lub instalacji certyfikatów.

## Wynik

**W przypiętym lokalnym `master` stare binaria są już śledzone.** Założenie,
że są obecne wyłącznie na tej gałęzi, nie potwierdziło się. Wszystkie 29
`media/.../*.sys` mają identyczny Git blob oraz SHA-256 w obu drzewach.
Żaden nowy branch-only `.sys/.cer` nie został rozpoznany jako historyczny
Microsoft/media payload. Nie ma Microsoft `.cer`: jedyny CER to własny
publiczny certyfikat USOS, bez private key.

| Przypięte drzewo | Commit | SYS/CER |
| --- | --- | ---: |
| HEAD | `098720f69611174303c59b18df96c308e680bd4c` | 74 |
| master | `275696db904073a8be8043c1a58fcb8eef4e42a3` | 39 |
| 0bd3c5e9 | `0bd3c5e9583296eb480c53b8f8a4cb56f4dbd7ac` | 33 |

Wspólny przodek HEAD/master: `9884bc099820e53ea15a9e20a6493c70294b61eb`.
`master` to lokalny ref `275696db` z 2026-10-03; audyt nie zmienia ani nie
odświeża remote. Integrację należy porównać ponownie z **rzeczywistym**
ówczesnym targetem, szczególnie jeśli wcześniej usunięto z niego te pliki.

74/74 istniejących plików ma SHA zgodny z przypiętym Git blobem; odczyt
FileVersionInfo/certyfikatu potwierdził niezmienność SHA przed/po.
Bloby Git przechodziły tylko przez RAM do hash/metadanych. Nie utworzono
kopii żadnego standalone Microsoft SYS, modułu, hive ani certyfikatu.

## Historyczne media: dokładna lista i SHA-256

Wszystkie poniższe pliki są identyczne w HEAD i master. Historia `A`
oznacza dodanie w `0bd3c5e9583296eb480c53b8f8a4cb56f4dbd7ac`
(2026-09-22, „checkpoint: XP UEFI-CSM PAE flow working end-to-end”).
Każdy wpis A ma w tej historii tylko jeden commit i niezmienione bajty.
`B` to późniejszy x64 ACPI z `fa58bdea016d793907d68007b768bf1d12ef66fe`
(2026-09-29, jawna decyzja o community x64 ACPI).

`MS` oznacza Microsoft w zasobie wersji, **bez** wniosku o autentyczności,
podpisie lub prawie redystrybucji. `community ACPI` nie ma zasobu wersji;
pochodzenie odnotowuje istniejący manifest XP. GenAHCI zachowuje Microsoft
w zasobie, lecz ma oddzielny source/licence pin — nie jest własnym USOS.

| Ścieżka repo | B | SHA-256 | Historia / zasób lub pochodzenie |
| --- | ---: | --- | --- |
| `media/Systems/Windows/Windows 7/Drivers/x64/NVMe/MS_StorNVMe/stornvme.sys` | 50616 | `040289582e64d60907703f9d1d092441505dc4820299fa203c0710d8aa4f75cb` | A; MS |
| `media/Systems/Windows/Windows 7/Drivers/x64/USB_Generic/uaspstor.sys` | 79320 | `0543fc06970c4f928c9b991dc42f3d82a4a161abf48e850d50d130e2550a40e6` | A; MS |
| `media/Systems/Windows/Windows 7/Drivers/x64/USB_Generic/ucx01000.sys` | 211952 | `ae910a5f24deeabf008a8b645a693f04ef4b9b3bf9d36b5100ecabc7a80538ca` | A; MS |
| `media/Systems/Windows/Windows 7/Drivers/x64/USB_Generic/usbd8.sys` | 22000 | `ae140ef9b0dfcd87a11ecf8316257fe223ae04ab90edcb442a047506e9e14a32` | A; MS |
| `media/Systems/Windows/Windows 7/Drivers/x64/USB_Generic/usbhub3.sys` | 459376 | `87212491d875cfa0034d441cec154720ce66cb654fd40ef292cf2f70afb5cbd5` | A; MS |
| `media/Systems/Windows/Windows 7/Drivers/x64/USB_Generic/usbxhci.sys` | 337904 | `d736a3a2386a1ae815fe7dd839884268b48bbc7b2468883bf9ec2c3b6202316d` | A; MS |
| `media/Systems/Windows/Windows Vista/Drivers/x64/AMD_USB31_PT/Host/x64/amdxhc31.sys` | 465248 | `cd4e891937f5d4386f11c91859503bd73dccbe7472138741b7431b8c2612a16e` | A; Advanced Micro Devices, Inc. |
| `media/Systems/Windows/Windows Vista/Drivers/x64/AMD_USB31_PT/Hub/x64/amdhub31.sys` | 154464 | `bc51a36d3bbb3fd155b1738b59e901ecb03809aaf3098707f73100076f008f7a` | A; Advanced Micro Devices, Inc. |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x64/ACPI/acpi.sys` | 327680 | `2aaac644abd3b94d8e1f41d1ea98ba88a18fe8c7273ba423796f0fdac20b6202` | B; MS |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/ACPI/acpi 5048 - 2020.10.24 - daniel_k, diderius6/acpi.sys` | 239616 | `b386ca0307942806fe2b18e9f2693e133d183faea13a349f1a06958027bc3057` | A; community ACPI; brak version resource |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/ACPI/acpi 6666 - 2021.8.28 - daniel_k, diderius6/acpi.sys` | 195968 | `c5a2d5c9627cd30d86fdd579ee2c4cdb2e4ebdd3fe92b1261195053e254f45a3` | A; MS |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/ACPI/acpi 7777.8 - 2024.11.7 - Dietmar/acpi.sys` | 185472 | `6b15128a105b783291e9102a841b149d80464bdda6799463c6c66f89ece2e672` | A; MS |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/ACPI/acpi.sys` | 185472 | `6b15128a105b783291e9102a841b149d80464bdda6799463c6c66f89ece2e672` | A; MS |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/Dependencies/Win2003/KB2862330/usbd.sys` | 5760 | `62d2cd8fb4acd60c47f64b8b13e388aa8c5bfcd9290bb9b149d99484fd76e8df` | A; MS |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/Dependencies/Win2003/KB2862330/usbport.sys` | 146432 | `d311eed36e89f6db1fbad3ebb427856ad4346356e942f7e4d5c3370456fe5f5d` | A; MS |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/Dependencies/Win2003/KB3139398/usbstor.sys` | 28160 | `e4a6ccc986568dbd28638c1f8a54fb41d602c7fc655b57e3ffdaff452c9ef29d` | A; MS |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/Dependencies/ntoskrn8.sys` | 141952 | `1f603da5938fc8a80efde4e98293b4bd20dd6a4140f825a682611e6a490325b9` | A; MOV AX, 0xDEAD |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/Dependencies/storpor8.sys` | 19456 | `06f407cb155ed16730c7788ea000e9c3d70a55b0046f5786a4d7e2a2daff283a` | A; MOV AX, 0xDEAD |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/Dependencies/storport.sys` | 151808 | `fc49d785021de49c3649c2d2e5adddd1867212121f14327d49ffa3bc75f8d442` | A; MS |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/KMDF/wdf01000.sys` | 527064 | `b1c119f541c46100731b5781964f1c9bed9cdf316cd73e40a5c328eba3933000` | A; MS |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/KMDF/wdfldr.sys` | 47720 | `149de723bf02d8449fb63b71406857db54decf2dae7be0d51d003fbcf5c2a39b` | A; MS |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/SATA/genahci.sys` | 60928 | `de7e22d16bc4d94530789c2061900a0dd5178b2967b5c302c5fe1c9296fb3edd` | A; GenAHCI; MS resource, source GPL pin |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/USB3/ksecd8.sys` | 392160 | `2ba1f6e253dd9a252816d6dd4aa70604f62ca5ff5c8aa683fdf788aca5a3ca58` | A; MS |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/USB3/uaspstor.sys` | 66048 | `c18eb77252f393d75a455ac203f1dc72e2f73685ea43423715c9d593b689f418` | A; VIA Technologies, Inc. |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/USB3/ucx01000.sys` | 179032 | `376cc4ac12e1b1241005ef5227f45057bc381cef286d66fc9b17a5b0f84a65aa` | A; MS |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/USB3/usbd8.sys` | 18776 | `33dfba5429864696c351beb76ac1a6b5141b61a8793ca6e416ec8d0278a7ca99` | A; MS |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/USB3/usbhub3.sys` | 363328 | `7648152c456e48f38fdecad3d637e5b46d86c3a2d190612772f53f6c286de90d` | A; MS |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/USB3/usbxhci.sys` | 268128 | `ce3c1c5aaabd91f20edc55697f4959e39a68b9c823f63cf8dcb433220d8b57af` | A; MS |
| `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/USB3/wpprecor.sys` | 21232 | `a2636f0b9747c032bf3bda44c9c35783f0e11d2f2ede3b6c831f2b1f420436ef` | A; MS |

W grupie jest 23 zasobów z CompanyName Microsoft (w tym GenAHCI), jeden
community ACPI bez zasobu wersji i pięć innych: dwa AMD, dwa extendery
MOV AX, 0xDEAD oraz VIA UASP. Nazwa pliku ani sam CompanyName nie wystarczają
do uznania pliku za oryginalny Microsoft albo własny USOS.

Źródła deklarowanego pochodzenia, już istniejące w repo:

- `media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/{README.md,manifest.json}`
  i `tools/vendor/xp-modern/2026-09-21/download-manifest.json`.
- `tools/release/third-party.json`: `microsoft-xp-driver-bundles`,
  `xp64-community-acpi` oraz osobny `genahci`. To deklaracje repo, nie nowa
  niezależna walidacja podpisu/licencji w tym audycie.
- `tools/vendor/genahci/6.3.0.1-src/SOURCES.txt`: upstream source
  `b936a0d8bdf410928aefa9e0f373fb1d6c7c8240`, deklarowany GPL-3.0-only;
  zgodność source/binary jest opisana jako niezweryfikowana byte-for-byte.

## CER i własne USOS — oddzielnie

`assets/secure-boot/usos-secure-boot.cer`, 851 B, SHA-256
`1039d6f0c8cddf1769f13766edaaac4a30daf55986654655f9d41d6ea517d230`. Subject=Issuer:
`CN=USOS Secure Boot Signing 2026, O=Universal Service OS`;
HasPrivateKey=false. Dodany w `8c894293bac737334851c4fd188eb24e1df302e8`
(2026-09-24, Secure Boot). Identyczny w master; nie występował w 0bd3c5e9.
Nie został zainstalowany do hostowego trust store.

35 ścieżek nieobecnych w master to **24 własne sterowniki USOS**, dziesięć
wariantów source-vendored/third-party i jeden własny tekstowy CONFIG.SYS.
Własne C/build recipes są przy projektach `usosmpart`, `usosnet`,
`usosnvme`, `usosusb`, `usosvbe`, `usosrst`; nie oznaczamy ich jako MS
na podstawie rozszerzenia `.sys`. Poniżej pełna branch-only lista,
z pinem i pierwszym commitem; pełna historia każdej ścieżki jest w receipt.

| Ścieżka repo | Klasa | SHA-256 | Pierwszy commit |
| --- | --- | --- | --- |
| `src/platform/bios/msdos/windows_early_config.sys` | tekst CONFIG | `a9e369d5eff22dbe9878e2cd2d0b88f63a91bb91e94073875dfaaf101c1045ea` | `17504575` |
| `tools/nt/usosmpart/bin/NT6/amd64/usosmpart.sys` | USOS own | `f5ced797ae86ad34b7e72619fe836dc8fae71db75b73e91146fa18b4e4274a7e` | `2435aaba` |
| `tools/nt/usosmpart/bin/amd64/usosmpart.sys` | USOS own | `0998443aa1341992035f531064858280c59f8b82b4f7a3303736a5690da6429d` | `2435aaba` |
| `tools/nt/usosmpart/bin/i386/usosmpart.sys` | USOS own | `3824353d5b13430e3d3a5145eb43b3c5c4c227808eebddca0a33f1b7b8bce1b4` | `2435aaba` |
| `tools/nt/usosnet/bin/i386/usosnet.sys` | USOS own | `8eac15b474b23fb4e7ac2c2431a4b17e6666cc2d03788b78ec2d8e19eeef89f9` | `dfc30455` |
| `tools/nt/usosnet/bin/i386/usosnet35.sys` | USOS own | `d94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85` | `ff8e305b` |
| `tools/nt/usosnet/bin/i386/usosnet351.sys` | USOS own | `f579ef120d296eb5d19c9092f3bd87d7d97866ea2798479d5129a61b758f55cf` | `ecb0973d` |
| `tools/nt/usosnet/bin/i386/usosnet4.sys` | USOS own | `89b7337c294ca0c56415cdc4e7023615a628ae8158a5a7ab80dcf6f35ca02233` | `7b8273ac` |
| `tools/nt/usosnet/bin/i386/win95-rtm/usosnet4.sys` | USOS own | `e075652b41413504654eb471b6a40d5f4c4b981f23d39dfea9bba117cac1fb3e` | `3a5cb387` |
| `tools/nt/usosnvme/bin/2KXP/i386/usosnvme.sys` | USOS own | `2b67abe8c75ac0ee40bbd4dff905d711b22b8776e4c06f0ea67852acbe65d5c4` | `16145c93` |
| `tools/nt/usosnvme/bin/NT31/i386/usosnvme.sys` | USOS own | `6b8ad4a7c04ba9d3d8f0f1630ee3f971dcb6cf9c773bf987af8eb71bc8dbdab4` | `16145c93` |
| `tools/nt/usosnvme/bin/NT351/i386/usosnvme.sys` | USOS own | `9c754f11cb8a130314236e68dfc30971d205b9e2ee664bedb911606d5aa04e5b` | `16145c93` |
| `tools/nt/usosnvme/bin/NT4/i386/usosnvme.sys` | USOS own | `46d6dba9e3b8b62e3b7cb6851fbc8f21bde71c51e5d605b535ed66e171b6a54b` | `16145c93` |
| `tools/nt/usosnvme/bin/NT6/amd64/usosnvme.sys` | USOS own | `9d4125b73c2fcaffb6f479fce3092eef2ea4d266a1b8fbbcea5650a45878cdff` | `bb8f68f6` |
| `tools/nt/usosnvme/bin/NT6/i386/usosnvme.sys` | USOS own | `78cfe4da722b979bda04d0d3301aa558e9153ba3f550adc96024b4ae085a836e` | `9c3f6b5e` |
| `tools/nt4/usosusb/bin/i386/usosusb.sys` | USOS own | `f4c6a0f00a36d7755892df8a7a62bc468e3bf7aae623c790289644403df1df69` | `2de1b4b9` |
| `tools/nt4/usosusb/bin/nt31/i386/usosusb.sys` | USOS own | `f5373eb3bf829d585651bc0da7ea5b1ca9b0cf2b20a1fe74ccb5054955f3ef05` | `2de1b4b9` |
| `tools/nt4/usosusb/bin/nt6/i386/usosusb.sys` | USOS own | `754fcee0c939b4c997283a5b20c7260a90a74f5637b9eb8a7f8f91d5724be8e9` | `2de1b4b9` |
| `tools/nt4/usosvbe/bin/i386/usosvbe.sys` | USOS own | `35bcafe45c8cb8629a3b66923ffedf66ff75ab2ea1df8b42cb0bbfb192eb90bb` | `c9b62a06` |
| `tools/nt4/usosvbe/bin/nt3/i386/usosvbe.sys` | USOS own | `a931282919e0dda8a9f9f659462e78ef628cf815907adee6003f6c3242158366` | `c9b62a06` |
| `tools/vendor/ahcint/1.3.0.0-usos4/bin/2KXP/i386/ahcint.sys` | third-party/source-vendored | `f5f0a8112f941f3833ac43c8104b4d169d2b6831d4ec224f9560ea10e3234f07` | `47f44220` |
| `tools/vendor/ahcint/1.3.0.0-usos4/bin/NT31/i386/ahcint.sys` | third-party/source-vendored | `962db3d8b1d4882fbe6d287fc30abca3335c59fcad1d55fcffd2c47af803b53c` | `e82f3405` |
| `tools/vendor/ahcint/1.3.0.0-usos4/bin/NT351/i386/ahcint.sys` | third-party/source-vendored | `40ba39c123e98ae5129751e7691a8ca5c41b9e88c269daabf3f288b90fdb6ed9` | `cbb01e5a` |
| `tools/vendor/ahcint/1.3.0.0-usos4/bin/NT4/i386/ahcint.sys` | third-party/source-vendored | `f2b90a21b4889229b758dec8478254c1fa5880c30c04831a9244a6c94ea71208` | `b3086857` |
| `tools/vendor/ahcint/1.3.0.0/bin/2KXP/i386/ahcint.sys` | third-party/source-vendored | `94ef734c4ba942debe990958917880f1995c08266600dc2014392bdaa22fac25` | `fea9dc75` |
| `tools/vendor/cregfix/f0693437/cregfix.sys` | third-party/source-vendored | `fa87a564d824969ab59db9831d32c2b8c1d662574ed9f798ebfc44c8436e2314` | `ecb4ae27` |
| `tools/vendor/uniata/0.47b/uniata.sys` | third-party/source-vendored | `f496db42afc5d44723be43d7731e2e220745d82af23ab30dcd3dc6d05f761679` | `d70cfcef` |
| `tools/vendor/xhci98/1.1.1.0-usos3-w9x/release-x86/xhci98.sys` | third-party/source-vendored | `8e0165982e6c4059f60034bd958914ee1a3a0616af043b6272c8f0a374c4edee` | `f4d6f32f` |
| `tools/vendor/xhci98/1.1.1.0-usos3/release-x64/xhci98.sys` | third-party/source-vendored | `c1a851087e4dac088017f71df27a85faa53565501ed74c39ca72bc0402b1f9bb` | `c6f36fc5` |
| `tools/vendor/xhci98/1.1.1.0-usos3/release-x86/xhci98.sys` | third-party/source-vendored | `5c3f1a7adb5903b5e3e26fda8a9c5624e50217f08689b83212cfec300184e944` | `c6f36fc5` |
| `tools/w2k/usosrst/bin/i386/usosrst.sys` | USOS own | `0c38413ad5c6e9f994ad4aa9f050a4ea7fe0aea188cb5abf28c381755ed76af5` | `afc5f79d` |
| `tools/w2k/usosrst/bin/nt31/i386/usosrst.sys` | USOS own | `98b0bd71adee35db2586f5176a5049d95a5cf0e470c16be6631d0531a6c344a9` | `e82f3405` |
| `tools/w2k/usosrst/bin/nt35/i386/usosrst.sys` | USOS own | `f52d33255efa90172769b37a0828baaf0bd9dc896213ddd688855bdbc5b61938` | `de31ebd1` |
| `tools/w2k/usosrst/bin/nt351/i386/usosrst.sys` | USOS own | `2b948d8817a291540e48da03e2aeb5553cd82580d0814ff3511f737eebd1397c` | `cbb01e5a` |
| `tools/w2k/usosrst/bin/nt4/i386/usosrst.sys` | USOS own | `d028580b4040662605d2c88b90094fd4125b2526cfda1083dc9011d6efafb23b` | `b3086857` |

Z plików już obecnych w master różni się tylko tekstowy
`src/platform/bios/msdos/windows_config.sys`; to nie PE driver. FreeDOS
KERNEL i CREGFIX są DOS binaries: brak MZ/PE nie oznacza automatycznie tekstu.
Surowy helper native-version oznaczył non-PE ogólną etykietą text/config;
jawna klasyfikacja w `evaluation.json` i ta nota ją zastępują.

## Zalecenie do późniejszej integracji

1. Użyj allowlisty zmian MiniOS oraz przypiętego targetu integracji. Nie
   przenoś całego starego drzewa `media` ani historycznego snapshotu branch
   jako sposobu dostarczenia WIM parsera/formattera.
2. Przed integracją porównaj **drzewa** kandydata i targetu, nie tylko diff
   wybranych commitów albo `.gitignore` (nie usuwa śledzonych plików).
   Pliki z tabeli legacy mają pozostać poza nowymi zmianami MiniOS. Jeżeli
   target już je usunął, nie przywracaj ich przez merge/rebase/checkout.
3. Nie stosuj zakazu całego `*.sys`/`*.cer`: zablokowałby własne USOS i
   publiczny certyfikat. Użyj dokładnych ścieżek/pinów i klasyfikacji.
4. Microsoft WIM/ISO, runtime moduły/hive i payloady pozostają poza Git.
   Wyrocznia hosta wimlib jest tylko w tools; nie tworzy dystrybucyjnego
   payloadu. Ta nota nie autoryzuje publikacji historycznych MS binariów.

Nie usunięto ani nie zmieniono żadnego z plików audytu. Brak merge/push.
Pełna ewidencja metadata-only:
`<runtime>/legacy-ms-audit01`:
`git-inventory.json` (bloby, SHA, bytes, pełna historia 74 ścieżek),
`native-version-info.json` (odczyt PE version/public CER) i `evaluation.json`.

Git inventory SHA-256: `cf834ae63ce8c08c5e0e5666e57cbf045ae71f2ef43e43dca6ea3feaa5d74662`.
Native metadata SHA-256: `f53940673d969870ae31b221881fe77d198c7a439fb247a8df296c3024614917`.
