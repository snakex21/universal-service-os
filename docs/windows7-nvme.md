# Windows 7 SP1 x64 — natywne NVMe

USOS przygotowuje obsługę Microsoft NVMe automatycznie w ścieżce UEFI
oryginalnego instalatora Windows 7 SP1 x64 (WinPE 6.1). Nie trzeba mieć
dysku NVMe podczas przygotowania. SATA korzysta z tego samego instalatora.
Źródłowy ISO i oryginalny plik odpowiedzi pozostają bez zmian.

## Przygotowanie i instalacja

Mikro-Linux wyodrębnia wersje składników boot.wim i przygotowuje na WORK
kopię środowiska WinPE. Uzupełnia oryginalne składniki Classpnp, Storport
i Setup z KB2990941 oraz KB3087873. Rozpoznaje gałęzie GDR/LDR i nie
zastępuje nowszych plików starszymi. Obraz RTM bez SP1 zachowuje starą
ścieżkę bez dodatku NVMe. Uszkodzone lub niejednoznaczne składniki
zatrzymują przygotowanie z komunikatem.

W WinPE oryginalny katalog Microsoft umożliwia normalną weryfikację
sterownika stornvme. Sprawdzanie podpisów nie jest wyłączane. Gdy obraz
ma już natywny sterownik, zachowywana jest jego konfiguracja usługi.

Pełne pakiety CBS trafiają do instalowanego Windows przez natywny etap
serwisowania Windows Setup, przed pierwszym uruchomieniem z dysku.
Osobny plik XML łączy pakiety z ustawieniami użytkownika; w trybie ręcznym
zawiera tylko pakiety i pozostawia wybory w kreatorze. Pomocnik odrzuca
nieprawidłowy XML, DTD, konfliktujące wpisy tych poprawek i wskazanie
fizycznego nośnika USOS jako DiskID. Nośnik jest ustalany z jego chronionej
tożsamości GPT, a nie z założenia, że USB zawsze ma numer 0 lub 1.

Pakiety, hashe i odtwarzanie archiwum:
[pochodzenie składników](../tools/vendor/windows7-nvme/README.md).

## Ograniczenia

- Integracja obejmuje WinPE instalatora i instalowany Windows. WinRE nie
  otrzymuje tych poprawek; odzyskiwanie z fabrycznego WinRE na NVMe nie jest
  potwierdzone.
- W WinPE stosowana jest kopia oryginalnych plików bootstrapu. Pełne
  serwisowanie CBS dotyczy instalowanego systemu, nie magazynu CBS WinPE.
- Obrazy z Windows 7 Image Updater Atak_Snajpera mogą używać WinPE 10.
  Taki instalator pozostaje poza tą ścieżką i wymaga osobnego testu.
- Pakiety Microsoft nie zastępują sterowników USB 3, grafiki, RAID/VMD ani
  testu zgodności konkretnego kontrolera i firmware.

## Powtarzalna weryfikacja

```text
python tools/tests/test_windows7_nvme.py
python tools/tests/test_windows7_nvme_prepare.py
```

Pierwszy test weryfikuje XML, ochronę nośnika, parser wersji PE i zasoby.
Drugi uruchamia rzeczywisty skrypt przygotowania w mikro-Linuksie, bez
podłączonych dysków. Buduje syntetyczne WIM-y w RAM i sprawdza GDR, LDR,
nowsze składniki, RTM, mieszane wersje oraz uszkodzony PE. Kontroluje też
niezmienność wejściowego WIM i zgodność użytych plików z pakietem.
Wymaga zbudowanego `zig-out/micro-linux` i QEMU z projektu.

13 września 2026: oba zestawy PASS (14 testów pomocników i 6 scenariuszy
przygotowania). Pełna instalacja ręczna na SATA, OOBE i pulpit bez źródłowego
USB: PASS. Polecenie `wmic qfe get HotFixID` potwierdziło KB2990941 i
KB3087873 w zainstalowanym systemie; oba sterowniki NEC USB 3 mają stan
RUNNING. Kontrola wyłączonego dysku, zamontowanego tylko do odczytu,
potwierdziła zgodność SHA-256 EFI, USB 3, stornvme, Storport i Classpnp
z oryginałami oraz obecność obu manifestów pakietów CBS.

W zainstalowanym Windows są `stornvme.sys` i `Classpnp.sys` 6.1.7601.18615
oraz `storport.sys` 6.1.7601.18969. Zbudowany pakiet
`B260913-183930-83CD1F61` przeszedł build, testy Go, pełny zestaw testów
projektu i kontrolę spójności payloadu. Spośród 167 plików ścieżki Win7
i zasobów NVMe, 166 jest identycznych z użytymi w pełnej instalacji SATA.
Jedyną późniejszą zmianą jest przekazywanie błędu przez skrypt startowy:
wyjście następuje poza blokiem warunkowym, co zapobiega restartowi WinPE
zamiast komunikatu. Poprawiony skrypt przeszedł osobne próby prawidłowego
startu kreatora oraz odrzucenia pliku odpowiedzi wskazującego nośnik USOS.
W drugiej próbie pojawił się komunikat i dziennik, a oba dyski miały zero
zapisanych bajtów. Wszystkie 167 plików obu tych prób odpowiada końcowemu
initramfs.

**Pełna instalacja do pulpitu na NVMe: NIEPOTWIERDZONA.** Oryginalny Setup
zapisał system na wirtualnym NVMe, a po odłączeniu źródłowego USB uruchomił
z niego Windows i etap końcowej konfiguracji. Ten etap postępował bardzo
wolno; próbę zakończono po około 33 minutach pierwszego rozruchu, bez
osiągnięcia pulpitu. Wcześniejszy prototyp także nie osiągnął pulpitu.
Nie ustalono ostatecznej przyczyny spowolnienia. Brak zgłoszonych błędów
odczytu/zapisu QEMU nie oznacza zaliczenia instalacji. Dodatkowa próba
startu kopii systemu zainstalowanego na SATA po podłączeniu jej jako NVMe
również nie potwierdziła pulpitu i nie jest testem pełnej instalacji NVMe.
Maszyny testowe zatrzymano; wyniku nie pozostawiono jako aktywnej próby.
Fizycznego NVMe nie testowano. Integracja jest dostępna, lecz pełna zgodność
NVMe wymaga dalszej weryfikacji.

Kingston został zaktualizowany do `B260913-183930-83CD1F61` bez formatowania.
Odczyt zwrotny wszystkich 78 statycznych plików ESP potwierdził zgodność
bajtową z końcowym payloadem, a kopia instalatora na DATA ma zgodne SHA-256.
Pierwszy odczyt wykrył użycie starszego wbudowanego payloadu w pomocniczym
aktualizatorze testowym. Przebudowano ten aktualizator, ponowiono zapis
i uzyskano pełną zgodność; wcześniejszy wynik nie został zaliczony.

Dowody w `zig-out/win7-nvme-work`: `sata-desktop.png`,
`sata-kb-installed.png`, `sata-usb3-services.png`,
`sata-production-installed-sha256.json`, `tested-runtime-sha256.json`,
`linux-sata-production.log`, `guard-fixed-result.png`, `guard-error-log.png`,
`startup-success.png`, `production-setup-log.png`,
`nvme-test-session-result.json`, `build.log`, `tests.log`,
`kingston-win7-nvme-operation.log`, `verify-usb.log`,
`kingston-payload-readback.json`.

### Warunki testu NVMe

Użyty QEMU 11.1 przedstawia w identyfikatorze kontrolera maksymalną liczbę
256 przestrzeni nazw, mimo podłączenia tylko jednej. Sterownik Windows 7
tworzył wtedy pozorne dyski i blokował wyliczanie woluminów. Próba z jedną
zadeklarowaną przestrzenią nazw pozwoliła przejść do instalacji.
Ten parametr zmieniono wyłącznie w pamięci osobnego, zatrzymanego procesu
testowego QEMU. Pliki QEMU, sterowniki Windows i ich podpisy nie były
modyfikowane. Obejście nie trafia do USOS i wynik wymaga tego zastrzeżenia.
Starszy QEMU 4.2 nie ukończył próby na tym hoście i nie jest wynikiem PASS.

Obrazy dysków są plikami w katalogu roboczym projektu; fizyczne dyski hosta
nie są podłączone do maszyn testowych. Numeracja USB/NVMe zależy od kolejności
wykrycia przez WinPE. Próby z błędnym DiskID zatrzymał pomocnik ochrony
źródła przed uruchomieniem Setup; nie są zaliczonymi instalacjami.
