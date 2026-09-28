# USOS 1.0.0: test świeżej instalacji (release test, fresh stick)

Cel: jedno popołudnie. Nowy pendrive z plików wydania, tak jak zrobi to
nowy użytkownik, i krótki smoke test na trzech maszynach. Instalacje tylko
do pierwszego ekranu Setup, chyba że krok mówi inaczej.

- **[MUST]**: musi przejść, inaczej nie ma tagu `v1.0.0`.
- **[OPC]**: opcjonalne, jeśli starczy czasu.
- **[NOWE]**: pierwszy raz na sprzęcie (wcześniej tylko QEMU), więc
  obserwuj dokładnie.

Dysk docelowy do instalacji: tylko testowy (np. Biostar S100 120 GB w X470,
dysk testowy w MS-7100). Każdy test z wyborem dysku **kasuje ten dysk**.

## 0. Przygotowanie

1. **[MUST]** Z `zig-out\release-1.0\` weź:
   - `USOS-Installer-1.0.0.exe`,
   - `USOS-1.0.0-WinPE-PE10-donor.zip`,
   - `USOS-1.0.0-XP-package-PL.zip`,
   - `SHA256SUMS`.

   Sprawdź też, czy obok są `USOS-1.0.0-XP-package-EN.zip`,
   `USOS-1.0.0-sources.zip`, `SOURCE-OFFER.txt`, `LICENSES\` i
   `THIRD-PARTY-NOTICES.txt`.
2. **[MUST]** Sprawdź sumy (PowerShell w tym folderze). Każdy wiersz ma
   pokazać `OK`:
   ```powershell
   Get-Content SHA256SUMS | % { $h,$f = $_ -split '\s+\*?',2; if ((Get-FileHash $f -Algorithm SHA256).Hash -eq $h.ToUpper()) {"OK   $f"} else {"FAIL $f"} }
   ```
3. Przygotuj ISO. Te, które masz, są na Kingstonie (`L:`), a Linuksy dodatkowo
   w `%LOCALAPPDATA%\USOS\test-assets\linux\`:

   | Folder na DATA | ISO |
   |---|---|
   | `Systems\Windows\Windows XP\Images` | `pl_windows_xp_professional_with_service_pack_3_x86_cd_x14-80476.iso` |
   | `Systems\Windows\Windows Vista\Images` | `pl_windows_vista_with_sp2_x64_dvd_x15-36359.iso` |
   | `Systems\Windows\Windows 7\Images` | `WIN7X64.6in1.pl-PL.JULY2019.ISO`, opcjonalnie `pl_windows_7_professional_with_sp1_x64_dvd_u_676944.iso` |
   | `Systems\Windows\Windows 10\Images` | `Win10_Pro_x64.iso` (dla MS-7100 dodatkowo `pl-pl_windows_10_22h2_..._x86_c20a40ff.iso`) |
   | `Systems\Windows\Windows 11\Images` | `Win11_25H2_Polish_x64_v2.iso` |
   | `Systems\Windows\Windows 98 SE\Images` | `Windows_98_SE_PL_OEM.iso` (opcjonalnie) |
   | `Systems\Windows\Windows Server 2003\Images` | `pl_win_srv_2003_r2_enterprise_with_sp2_vl_cd1_x13-46476.iso` (tylko do sprawdzenia ikony) |
   | `Systems\Linux\Ubuntu\Images` | `ubuntu-24.04.5.1-desktop-amd64.iso` |
   | `Systems\Linux\Linux Mint\Images` | `linuxmint-22.3-xfce-64bit.iso` |
   | `Systems\Linux\SystemRescue\Images` | `systemrescue-13.02-amd64.iso` |
   | `Utilities\MemTest86\Images` | `memtest86plus-8.10-i586.iso` |

## 1. Nowy pendrive: SanDisk (dawny E2B)

To **Twoja** czynność, nie agenta. Kingstona **nie ruszaj**: zostaje jako
pendrive zapasowy.

1. **[MUST]** Podłącz SanDiska i obejrzyj jego zawartość w Eksploratorze.
   Skopiuj z niego wszystko, czego chcesz używać dalej. Formatowanie usuwa
   wszystko.
2. **[MUST]** Uruchom `USOS-Installer-1.0.0.exe` i wybierz **Instalacja**.
   Na liście dysków **sprawdź model i rozmiar** (SanDisk, ok. 128 GB, a nie
   Kingston DataTraveler 3.0 61,9 GB ani żaden dysk wewnętrzny). Dopiero wtedy
   potwierdź formatowanie.
3. **[MUST]** Wynik: operacja zakończona bez błędu. W Eksploratorze widać
   `USOS_ESP` i `USOS_DATA`, a na DATA są foldery `Systems`, `Utilities`,
   `Drivers` i `Programs`.

## 2. Wypełnienie pendrive'a

1. **[MUST]** Skopiuj ISO z tabeli z punktu 0 do folderów na `USOS_DATA`.
2. **[MUST]** Rozpakuj `USOS-1.0.0-WinPE-PE10-donor.zip` i skopiuj
   `PE10_x64_19041_USOS.iso` do `USOS_DATA\Programs\USOS\WinPE\`.
3. **[MUST]** Instalator: **Aktualizacja lokalna** -> **Aktualizuj USOS** na
   SanDisku. Oczekiwane: PASS, a dawca PE10 zapisany w
   `EFI\USOS\winpe-donor.ini` (folder i plik stają się ukryte).
4. **[MUST]** Rozpakuj `USOS-1.0.0-XP-package-PL.zip` i uruchom PowerShell
   **jako administrator** w rozpakowanym folderze:
   `powershell -ExecutionPolicy Bypass -File .\install-xp-package.ps1`
   (przy dwóch podłączonych pendrive'ach USOS dodaj `-EspRoot X:\`).
   Skrypt sprawdza, czy pendrive ma ten sam build co pakiet. Oczekiwane:
   `PASS: XP package installed and verified`, pakiet w
   `USOS_ESP\EFI\USOS-XP\`.
5. Po każdym zapisie: wysuń pendrive bezpiecznie w Windows.

## 3. Testy dymne

Nagłówek menu na każdej maszynie powinien pokazywać **„Universal Service OS
1.0.0”** i ten sam build (skrócony, np. `Build B260928-214844`; pierwszy
kandydat: `B260928-214844-A6711A1F`). Na wąskim ekranie (np. 800x600) napis
„Build” jest ukryty; pełny ID jest w `EFI\USOS\build-info.ini`. Zapisz go
w tabeli z punktu 4.

**A. MS-7100 (Socket 939), Legacy BIOS**

- **[MUST]** Menu BIOS startuje, a nagłówek i build są poprawne.
- **[MUST] [NOWE]** Lista obrazów pokazuje pełne nazwy ISO, bez krzaków i bez
  powtórzonej nazwy (np. Linux Mint, Windows XP).
- **[MUST] [NOWE]** Utilities -> FreeDOS: startuje panel FreeDOS.
- **[MUST]** Utilities -> MemTest86: test rusza.
- **[MUST]** XP (x14-80476), Automatic: wybór dysku testowego, potem Setup XP
  w trybie tekstowym. Zamiennie: Windows 98 SE do startu DOS Setup.
- **[OPC] [NOWE]** Motyw użytkownika w BIOS: najpierw w UEFI (X470) ustaw
  Tools -> Motyw -> `usos-sunset`. Wtedy menu BIOS ma kolory „sunset”.
- **[OPC] [NOWE]** Na liście Windows w BIOS XP x64 i Server 2003 mają ikonę XP.
- **[OPC]** Utilities -> Hardware & SMART: widać dyski i raport SMART.

**B. X470, UEFI z CSM, Secure Boot wyłączony**

- **[MUST]** Menu UEFI startuje po polsku, z poprawnym nagłówkiem.
- **[MUST]** XP PL (pakiet z punktu 2): podsumowanie, dysk, Setup XP
  w trybie tekstowym kopiuje pliki.
- **[MUST] [NOWE]** Vista z CSM i profilem: w menedżerze profili utwórz
  profil „Tylko Windows Vista” (Ultimate, użytkownik Retro, bez hasła i
  klucza) i uruchom z nim Vistę. Oczekiwane: Setup pomija język i EULA, a
  dysk wybierasz ręcznie. Mignięcie konsoli `winpeshl` (ok. 1 s) jest znane.
- **[OPC] [NOWE]** Ta sama Vista do pulpitu: brak okien konsoli z poleceń
  profilu, a w `C:\Windows\Panther\` jest `usos-hidden-commands.log`. Konsola
  „USOS - Vista USB diagnostics” przy pierwszym starcie jest znana.
- **[MUST]** Windows 10 x64: pierwszy ekran Setup.
- **[MUST] [NOWE]** Windows 11 z profilem (np. „Każdy Windows”): Setup
  rusza, a polecenia profilu (LabConfig) nie otwierają okien konsoli.
- **[OPC] [NOWE]** Windows 7 SP1 retail (`..._676944.iso`) przez dawcę PE10:
  pierwszy ekran Setup.
- **[OPC] [NOWE]** XP x64 i Server 2003 mają ikonę XP na liście UEFI.
  Instalacji nie uruchamiaj: na X470 spodziewany jest STOP 0xA5, który jest
  znany.

**C. X470, UEFI bez CSM (CSM off, Secure Boot off)**

- **[MUST] [NOWE]** XP przez CSMWrap: podsumowanie mówi „XP bez CSM
  (eksperymentalne)”, potem dysk i restart. Boot jest cichy: bez logo
  CSMWrap, bez banera SeaBIOS i bez „Press ESC”. Migający kursor w lewym
  górnym rogu jest znany. Na końcu Setup XP w trybie tekstowym.
- **[OPC]** Ten sam XP do pulpitu. Sprawdź PAE i 31,9 GB, liczbę CPU (o 1
  wątek mniej) oraz klawiaturę i mysz USB.
- **[MUST] [NOWE]** Vista przez CSMWrap: jeden licznik 1/5 do 5/5, ekran
  „FORMAT THE ENTIRE DISK?”, restart, cichy boot, potem PE10 i Setup Visty.
- **[MUST]** Windows 7 6in1 bez CSM: Setup z obrazem (pulpit opcjonalnie).

**D. X470, Secure Boot włączony (CSM off)**

X470 ma już klucz USOS w MokList. Klucz jest ten sam dla każdego pendrive'a
USOS, więc SanDisk powinien wystartować od razu, bez MokManagera.

- **[MUST]** Menu startuje przez shim, bez „Verification failed”.
- **[MUST]** XP, Vista i 7 mają odznakę „Wymaga wyłączenia Secure Boot” i
  nie startują.
- **[MUST] [NOWE]** Windows 10 lub 11: pierwszy ekran Setup przy włączonym
  Secure Boot.
- **[MUST] [NOWE]** Ubuntu Desktop 24.04.5.1 (lub Mint): pulpit live, bez
  komunikatu „Verification failed” przed startem.
- **[OPC]** Ubuntu Desktop: instalator na pulpicie live startuje bez „Something
  went wrong” (w QEMU pod TCG był błąd).
- **[MUST]** SystemRescue: odznaka Secure Boot, start zablokowany komunikatem,
  który zamyka dowolny klawisz. Jeśli pojawi się ekran firmware i 30 s
  czekania, zrób zdjęcie.
- **[MUST]** Utilities -> Powłoka UEFI: startuje i znajduje DATA. Przy
  włączonym Secure Boot wypisuje, że narzędzi `.efi` nie da się uruchomić.
- **[OPC]** Rejestracja klucza MOK na komputerze, który nigdy nie startował
  USOS z Secure Boot: Tools -> Secure Boot (przy wyłączonym SB) albo
  MokManager -> Enroll key from disk -> `USOS_ESP` -> `USOS-KEY.cer`.

**E. Instalator: ścieżka aktualizacji**

- **[MUST]** Ponownie **Aktualizuj USOS** na SanDisku. Oczekiwane: PASS,
  ISO na DATA nietknięte, a profil i motyw z testów nadal są. Menu dalej
  startuje XP UEFI (sprawdź, czy `EFI\USOS-XP` zostało).
- **[OPC]** **Naprawa** (Napraw ESP): PASS, a menu startuje.

**F. ROG Ally RC71L [OPC]**: w menu UEFI działa dotyk (dotknięcie,
przewijanie) i pad z podpowiedziami A/B. Start z włączonym Secure Boot (klucz
jest już zarejestrowany).

## 4. Gdy coś nie działa: co zebrać

- Zdjęcie ekranu, zwłaszcza ekranów firmware i komunikatów shim.
- Z pendrive'a (`USOS_ESP`): cały folder `EFI\USOS\Logs\`
  (`input-devices.txt`, `drivers.txt`, `secure-boot-<UUID>.ini`,
  `usos-startup.log`, `vista-install.log`), pliki `EFI\USOS\*.log` (XP:
  `legacy-xp-*.log`), `EFI\USOS\vista-csmwrap\prepare.log`,
  `EFI\USOS\build-info.ini` i `EFI\USOS\install-state.ini`.
- CSMWrap: utwórz pusty plik `EFI\USOS\csmwrap-verbose.flag` i powtórz próbę
  (pełny log na ekranie).
- Z dysku docelowego:
  - XP: `C:\USOS\XP\pae-install.log`;
  - Vista: `C:\USOS\Vista\firstboot-usb.log`;
  - Vista, 7, 10 i 11: `C:\Windows\Panther\setupact.log` i
    `usos-hidden-commands.log`;
  - Win7 bez CSM: `EFI\Microsoft\Boot\usos-boot-uefiseven.log` i
    `UefiSeven.log` na ESP celu.
- Instalator: `USOS Installer.log` obok pliku EXE.

Tabela wyników (build z nagłówka menu: `B________________`):

| Krok | Maszyna / tryb | PASS / FAIL | Uwagi |
|---|---|---|---|
| 0 sumy SHA256 | dev PC | | |
| 1 instalacja SanDisk | dev PC | | |
| 2 DATA, dawca, Update, pakiet XP | dev PC | | |
| 3A BIOS: menu, nazwy, FreeDOS, MemTest, XP/98 | MS-7100 | | |
| 3B UEFI+CSM: XP, Vista+profil, 10, 11 | X470 | | |
| 3C bez CSM: XP CSMWrap, Vista CSMWrap, 7 | X470 | | |
| 3D Secure Boot: menu, 10/11, Linux, SystemRescue, Shell | X470 | | |
| 3E ponowna aktualizacja | dev PC | | |
| opcjonalne (lista) | | | |

## 5. Po teście

Gdy wszystkie **[MUST]** mają PASS, przekaż koordynatorowi tabelę i build ID.
Tag git `v1.0.0` powstaje **dopiero po** tym teście. Przy FAIL przekaż zdjęcia
i logi z punktu 4. Kingston zostaje jako działający pendrive zapasowy.
