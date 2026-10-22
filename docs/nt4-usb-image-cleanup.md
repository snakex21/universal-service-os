# NT4 USB: wykonane sprzątanie własnych zakończonych obrazów

Usunięto jednorazowo dokładnie13 zatwierdzonych plików `.qcow2`, o łącznym
otwartym rozmiarze2294808576B. Wszystkie operacje zakończyły się poprawnie,
bez odmowy, ponawiania lub zmiany techniki. Nie mierzono faktycznego odzysku
przydzielonego miejsca. Nie usuwano katalogów ani innych typów plików.

Użytkownik autoryzował wykonanie po przeglądzie root planu z6457ab4b.
Plan `artifacts/nt4-usb-cleanup-plan.json` ma SHA256
`d45245e87d9194b8f3d5e0a22255a7d0849b43505522b8a3f1a70fa9b4f2ad57`.
Przed pierwszą operacją agent NT4 potwierdził na podstawie zakończonej
preparation i znanego argv09, bez odczytu aktywnego09: jedyny parent09 to
NET08, dalej NET07→original03; nowe USBmedia09 są standalone i nie mają
backingu ani odwołań runtime/argv do żadnego z sześciu własnych katalogów USB.
Reuse obejmuje źródła/operator/helper75cef i zakończone metadane w C,
których nie usuwano. Root nie usuwał tych samych plików równolegle.

## Sprawdzenia i jedna technika wykonania

`tools/tests/coverage/cleanup_nt4_usb_images.py` używa wyłącznie Pythona
oraz natywnych API plikowych Windows. Ma13 literalnych absolutnych ścieżek
i stałą listę sześciu katalogów. Nie wybiera celów globem, nie usuwa
rekurencyjnie i nie uruchamia globalnego query procesów ani nowych VM.

Udana próba `--preflight` poprzedza wykonanie. Oba etapy sprawdziły zgodność
pełnych SHA256, rozmiarów z otwartego uchwytu, dowodów zakończenia/rc0
lub nigdy nieuruchomionego przygotowania, literalne resolved path bez
reparse points i faktyczną końcową ścieżkę uchwytu. Wszystkie13 plików
otwarto równocześnie z share0, Read+DELETE, single-link, przed pierwszym
usunięciem. Każdy pozostawał wyłącznie otwarty aż do własnego unlink.
Zmiana SHA/rozmiaru, blokada lub niezgodny plan powoduje odmowę przed
usuwaniem; nie ma alternatywnej ścieżki usuwania ani ponawiania.

Pełny hash obrazu wiąże aktualne metadane backing z zatwierdzonym planem.
Nie uruchamiano qemu-img ani nie odczytywano aktywnego09. Native
SetFileInformationByHandle/FileDispositionInfo oraz CloseHandle wykonuje
unlink przy zachowaniu wyłącznego uchwytu. Każdy zakończony unlink został
potwierdzony pojedynczym sprawdzeniem braku ścieżki i zapisany w trwałym
journalu. Najpierw usunięto dziecko combo01, następnie jego własny parent
MSC04, potem pozostałe obrazy według planu.

## Dokładny receipt

| Usunięta absolutna ścieżka | Otwarty rozmiar B | SHA256 przed unlink |
|---|---:|---|
| `G:\USOS-Kolekcja\_vm\nt4-installed03-usb-combo01\target.qcow2` | 458031104 | `dc757988b9634acaa03c5a4cb90d64e268c7109e62bdd88ea73b52cd8d0493fa` |
| `G:\USOS-Kolekcja\_vm\nt4-installed03-usb-combo01\usb-test-boot.qcow2` | 589824 | `ed90e0bfdd066c8fe6d889f8d8ac8765df826330e15a2e249d19edd3e5f6aff0` |
| `G:\USOS-Kolekcja\_vm\nt4-installed03-usb-combo01\usb-test-hot.qcow2` | 589824 | `8e85eaabef9214aee3a15a081aa39b92ad81c0a487e51c9bc7125ce93861c404` |
| `G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc04\target.qcow2` | 458031104 | `a6807a432891b47ea20a4eb1650fc981ae8b7fdade6cec138d9ef03818b1de5c` |
| `G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc04\usb-test-boot.qcow2` | 589824 | `ed90e0bfdd066c8fe6d889f8d8ac8765df826330e15a2e249d19edd3e5f6aff0` |
| `G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc04\usb-test-hot.qcow2` | 589824 | `cbf9efb1fe4b03efb2837b605e9de943ee3484710274a76222be44249c1e3912` |
| `G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc03\target.qcow2` | 458031104 | `a3375c70220c47d89c73b1e7960fb55e10d75cfcd8117a2e11dfe9544b298923` |
| `G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc03\usb-test-boot.qcow2` | 589824 | `ed90e0bfdd066c8fe6d889f8d8ac8765df826330e15a2e249d19edd3e5f6aff0` |
| `G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc03\usb-test-hot.qcow2` | 589824 | `29760ec7cbb2dc7e1fbcbbe55fdf3fe6d0155a28484ec002bb75f2f4d0cfe44c` |
| `G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc02\target.qcow2` | 457965568 | `e80a36b11a1df95d01690c2803d9b95dd77f22d692877409c362f8623e7f53b0` |
| `G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc02\usb-test-boot.qcow2` | 589824 | `103a00a4fddec849bc462e64c79bca283503456a7b9bbe8df15cee507d25d787` |
| `G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc02\usb-test-hot.qcow2` | 589824 | `08e1fb107917016e086787d3d73bc6820d01c04007142b31086aca750061d8e0` |
| `G:\USOS-Kolekcja\_vm\nt4-installed03-usb-hid01\target.qcow2` | 458031104 | `f2e16aa356c204db8f4c1eeae1f89dde22e55cb1d0d1d6a3b6ae749246e6cba0` |

`nt4-installed03-usb-msc01` był pusty, więc nie było w nim pliku do usunięcia.
Wszystkie sześć katalogów pozostało, wraz z katalogami aplikacyjnego cache.
Zachowano `G:\USOS-Kolekcja\_vm\nt4-installed03-usb-hid01\fixture.json`,320B,
SHA256 `4c0c60b831ad37d5849db0da2b8ccbbdac299eb0ecf0a750a2353a6e083d3a5e`.

Chroniony wspólny parent
`G:\USOS-Kolekcja\_vm\nt4-sp6a-desktop-net-ps2-candidate03\target-retained.qcow2`
zachował SHA256 przed i po:
`cf04c232df2dc3bcbc2775c0d31963fd1fc4abd4daf7a2967eba9be1f8af2a21`.
Żadnego NT4 NET, żadnego macOS (w tym odmówionych02–04), vars/logów/cache,
źródeł, helperów ani dowodów w C nie usunięto. Utrwalone kwalifikacje
HID01/MSC04/combo01 zachowują swój historyczny zakres i przypięte dowody.

| Dowód w `artifacts/nt4-usb-cleanup/` | SHA256 |
|---|---|
| preflight.json | `2446fcee641c988ef209754d7fa465f897e70a8d8fb6bc4afb29d6cf9e8a3a1a` |
| receipt.json | `8dc4314130ab607f769d5f4b10def6a78f13524044589170de3bca947cc58749` |
| unlink-journal.jsonl | `da02b84a1f046daab4a288a461bf777109a85400f0abe0c7b2590b959c59f929` |

Wykonany skrypt ma SHA256
`7266c268df2b42ba9f666f5bbab9793949e4cb8e6c5a555826d22b5a6c501c28`.
Receipt zawiera13 faktycznych ścieżek/hashy/rozmiarów, closure pins,
wyłączne otwarcia i potwierdzenie zachowanych plików/rodzica. Powtórny
start wykonania jest blokowany obecnością własnego receipt. Nie wykonano
ponownej próby usuwania jako testu guardu. Nie wykonano merge/push/deploy.
