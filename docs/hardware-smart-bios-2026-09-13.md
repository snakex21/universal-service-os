# Hardware & SMART — BIOS, 13 września 2026

Późniejsza aktualizacja dodaje tabele SMART, nazwy dysków bez `/dev/...`
i etapy wykrywania sprzętu: [szczegóły](hardware-smart-tables-2026-09-13.md).
Użytkownik potwierdził start poprzedniego panelu na swoim komputerze.
Poniżej zachowano opis pierwszego wydania i jego weryfikacji.

`Utilities -> Hardware & SMART` jest wbudowaną pozycją dostępną obok
narzędzi odkrywanych na DATA. Nie wymaga dodatkowego obrazu ISO.

Panel udostępnia:

- `System information`: model CPU, liczba procesorów logicznych, użyteczna
  pamięć RAM, identyfikacja komputera, płyty i BIOS-u, dane modułów pamięci
  zgłoszone przez firmware oraz lista urządzeń PCI.
- `Disks & SMART`: całe dyski, modele, numery seryjne, pojemności i interfejsy;
  po wybraniu dysku — bieżący raport SMART oraz przycisk odświeżenia.
- `Return to USOS`: restart do menu głównego. Esc cofa o jeden ekran;
  Esc na ekranie głównym panelu również restartuje komputer.

Działają klawiatura i mysz; PgUp/PgDn lub kółko przewijają szczegóły.
Lista zawiera także nośnik USOS, jeśli system widzi go jako dysk.
Raporty mają ograniczenie 108 wierszy; przy dłuższym raporcie panel informuje
o pominięciu dalszych szczegółów. Brak danych firmware jest widoczny jako
`Unavailable` albo wartość zgłoszona przez firmware.

## Wymagania i odczyt

Ta wersja dodaje start z menu BIOS na procesorze x86-64. Korzysta z
dotychczasowego kernela MicroLinux LTS i jego sterowników ATA/SATA, USB
i NVMe. Nie dodaje uruchamiania tego panelu z menu UEFI ani wariantu i586.
Memtest i586 nadal korzysta z niezależnej ścieżki startu.

Dedykowane żądanie `usos.legacy_action=hardware` jest obsługiwane przed
montowaniem ESP, DATA i WORK oraz przed akcjami instalacyjnymi. Raporty
powstają w RAM, w `/run/usos-hardware`, i znikają po restarcie.
Narzędzia nie montują systemów plików badanych dysków.

SMART korzysta z `smartctl -a -n standby,3` z limitem 20 sekund. Nie włącza
SMART, nie rozpoczyna autotestów ani testu powierzchni, nie naprawia dysków
i nie zmienia ich ustawień. Urządzenie może samo aktualizować własne
liczniki podczas pracy. Mostki USB i niektóre kontrolery nie udostępniają
SMART; panel pokazuje wtedy brak lub niepełny wynik, a nie stan PASSED.
`PASSED` wymaga jawnego pozytywnego raportu bez flag błędu. Flaga awarii
zdrowia dysku ma pierwszeństwo; błędy odczytu, historia błędów, uśpienie
i timeout mają osobne komunikaty. PASSED nie zastępuje testu powierzchni.

Pakiety w `tools/micro_linux.lock.json` mają przypięte wersje i SHA-256:
smartmontools 7.5-r0, dmidecode 3.7-r0, pciutils 3.15.0-r0 oraz ich biblioteki
i baza identyfikatorów PCI. Są dołączane do initramfs podczas budowania.

## Weryfikacja

Pełny build i `tools/tests/run.ps1 -Suite all` przeszły. Testy obejmują
parametry startu, interpretację flag SMART, timeout i uśpienie, zachowanie
kodu błędu, dozwolone argumenty odczytu, sanitację raportu oraz formatowanie
nazw i pojemności dysków. Test VM wykrył surowe kody spacji i zerowe
pojemności na liście; poprawka używa trybu listy lsblk i usuwa padding.

VM: SeaBIOS, qemu64, 2 GiB RAM, VGA 1280x800, źródło USOS jako USB tylko
do odczytu oraz trzy dyski 8 GiB. Zweryfikowano ekran systemu, listę dysków,
wybór klawiaturą i myszą, przewijanie raportu i restart do menu USOS.
NVMe bez ostrzeżeń zgłasza PASSED (exit 0); NVMe z critical warning 0x04
zgłasza failing health (exit 8); wirtualny mostek USB zgłasza brak SMART.
Emulowany ATA również udostępnia pozytywny SMART. Trzy obrazy badanych
dysków były identyczne bajt po bajcie przed i po obu sesjach.

Końcowa paczka `B260913-102107-C30F1115` przeszła ponowny start panelu,
kontrolę poprawionych nazw i pojemności oraz odświeżenie SMART w VM.
Kingston DataTraveler 3.0 został zaktualizowany standardowym updaterem
z kontrolą modelu, rozmiaru, GPT dysku i trzech PARTUUID. Wynik updatera:
PASS. Niezależny odczyt porównał wszystkie 62 pliki ESP z aktualną paczką
instalatora — zgodność bajt po bajcie; identyfikator buildu również zgodny.

Dowody lokalne: `zig-out/hardware-work/`, zrzuty `hardware-*.png`
w `zig-out/win3-work/`. Pełny test nowego panelu na fizycznym Socket 939
pozostaje do wykonania przez użytkownika; wcześniejsze potwierdzenie
sprzętowe dotyczyło Memtest86+.
