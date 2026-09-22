# CSMWrap: fizyczna próba rozruchu

Aktualizacja: po zgłoszeniu zatrzymania przy SeaBIOS `Booting drive`
przywrócono oryginalny rozruch USOS. Poniższy opis wdrożenia jest historyczny;
CSMWrap nie jest już aktywnym BOOTX64.EFI. Następna próba dotyczy handlera
INT10 na Intelu: [opis](windows7-int10-return-2026-09-20.md).

Stan: przygotowany pendrive, bez potwierdzenia startu na sprzęcie.
Na życzenie użytkownika usunięto pośredni wybór 1/2: BOOTX64.EFI jest teraz
bezpośrednio oficjalnym CSMWrap. Oryginalny USOS i wcześniejsze menu zachowano.
To próba CSMWrap/SeaBIOS, nie ukończona integracja Windows 7 ani QuickInstall.

## Uruchomienie

1. CSM Disabled, Secure Boot Disabled. Uruchomić UEFI pendrive Kingston.
2. CSMWrap uruchamia się bez dodatkowego menu USOS.
3. Obserwować komunikaty CSMWrap i SeaBIOS. ESC otwiera
   menu urządzeń SeaBIOS, jeśli ta faza została osiągnięta.
4. Sfotografować ostatni ekran, jeżeli start zatrzyma się.

Intel 120 GB został odczytany jako GPT z ESP, MSR i Windows na partycji 3.
CSMWrap kończy usługi EFI i uruchamia rozruch BIOS; nie przekazuje sterowania
do istniejącego winload.efi. Samo wybranie Intela w SeaBIOS nie tworzy
brakującej ścieżki BIOS. `No bootable device` nie oznacza automatycznie,
że CSMWrap nie odblokował pamięci albo nie uruchomił SeaBIOS.
Nie wykonano konwersji GPT/MBR, reinstalacji ani zmian na Intelu.
Problem klawiatury USB podczas sprawdzania dysku Win7 pozostaje niewyjaśniony.

## Pliki i diagnostyka

- `EFI/BOOT/BOOTX64.EFI`: oficjalny CSMWrap 3.1.2 x64, bez dodatkowego menu.
- `EFI/BOOT/csmwrap.ini`: aktywne `verbose = true` dla bezpośredniego startu.
- `EFI/BOOT/USOS-original.efi`: oryginalny USOS, zgodny bitowo z kopią sprzed próby.
- `EFI/CSMWrap/csmwrapx64.efi`: niezmieniona oficjalna wersja 3.1.2.
- `EFI/CSMWrap/trial-menu.efi`: zachowane wcześniejsze menu 1/2, nieaktywne.
- `EFI/CSMWrap/csmwrap.ini`: kopia konfiguracji dla uruchomienia z tego katalogu.
- `EFI/CSMWrap/usos-launch.log`: przy bezpośrednim starcie NIE jest aktualizowany.
  Wcześniejsze menu zapisywało wybór/LoadImage/przekazanie sterowania
  lub błędu EFI. Nie jest pełnym logiem CSMWrap/SeaBIOS. Komunikaty po
  przekazaniu sterowania widoczne są na ekranie. Bezpośredni CSMWrap również
  pokazuje diagnostykę na ekranie, bez obiecanego pełnego zapisu na USB.

CSMWrap SHA256: `96fdb387e177c6340287b7e07713dc09bf1f965dd404311eafd9c6eb99a02745`.
Menu SHA256: `4ed63bea74a5ec63a7317da38fa4e1d9d31b23f8ff64a3b9fffcd8aefa1f3866`.
Oryginalny USOS SHA256: `3008d265b13343fc694bd6fff3985b1d67884a79c684472be39a767f8f2a5b5d`.
Oficjalny digest GitHub, architekturę PE x64 i subsystem EFI Application
sprawdzono przed wdrożeniem. Manifest i licencja są obok pliku EFI.

## Weryfikacja i cofnięcie

`python tools/build_csmwrap_trial.py`: exit 0. Kompiluje tylko menu EFI,
weryfikuje pliki dostawcy i tworzy pakiet; nie uruchamia VM.
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/deploy_csmwrap_trial.ps1`:
exit 0; odczyt zwrotny wszystkich plików zgodny, MBR i układ partycji identyczne.
Zapis tylko na ESP rozpoznanego Kingstona. Bez VM/E2E.
Przełączenie na start bez menu: ten sam skrypt z `-Direct`, sprawdzający
hash CSMWrap i zachowanego oryginalnego USOS przed zastąpieniem menu.

Kopia lokalna: `zig-out/csmwrap-trial-backup-20260920-182857/BOOTX64.EFI`.
Cofnięcie menu (tylko po weryfikacji tożsamości USB i obu hashy):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/deploy_csmwrap_trial.ps1 -Restore
```

Pakiet jest oddzielnym eksperymentem, nie częścią standardowego payload.zip.
Zwykła aktualizacja USOS może zastąpić to menu. Przed kolejnym wdrożeniem
należy uwzględnić obecność `USOS-original.efi` i nie przywracać starego buildu
po późniejszej aktualizacji.

## Źródła

- https://github.com/CSMWrap/CSMWrap/releases/tag/3.1.2
- https://github.com/CSMWrap/CSMWrap/blob/3.1.2/README.md
- https://github.com/CSMWrap/CSMWrap/blob/3.1.2/src/unlock_region.c
- https://github.com/CSMWrap/CSMWrap/blob/3.1.2/src/csmwrap.c

Kod 3.1.2 zawiera własne odblokowanie regionu BIOS przez AMD MTRR.
Nie stanowi to dowodu kompatybilności z badaną płytą X470.
