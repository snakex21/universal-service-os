# Sieć Intel I211 (PCI\VEN_8086&DEV_1539) w Windows 7 / Server 2008 R2

Windows 7 i Windows Server 2008 R2 nie mają sterownika dla I211. Intel wydał
go jako **e1r62x86 / e1r62x64** (NDIS 6.2) w „Intel Ethernet Adapter Complete
Driver Pack” (katalogi `PROWin32` / `PROWinx64`). Ten dokument mówi, gdzie
położyć rozpakowaną paczkę, żeby USOS sam ją wstrzyknął, i jak sprawdzić, że
karta działa.

USOS nie zawiera plików Intela i nie instaluje ich z repo — paczkę kładzie
użytkownik na partycji `USOS_DATA` (montowanej w USOS jako DATA). Nie kopiuj
jej do repozytorium ani do `tools\cache`.

## 1. Co rozpakować

Z paczki Intela potrzebny jest **cały folder sterownika**, nie pojedyncze
pliki:

```
e1r62x86\        (32-bit: Windows 7 x86, Server 2008 R2 x86)
  e1r62x86.inf
  e1r62x86.cat
  e1r62x86.sys
  ...            (pliki .dll/.bin z paczki zostaw w folderze)
e1r62x64\        (64-bit: Windows 7 x64, Server 2008 R2 x64)
  e1r62x64.inf
  e1r62x64.cat
  e1r62x64.sys
  ...
```

Wystarczy sam folder z `.inf` (i plikami, które ten `.inf` wymienia) — USOS
skanuje drzewo rekursywnie i nie ma żadnej listy plików do edycji.

## 2. Gdzie położyć

### Windows 7 x86 / Server 2008 R2 x86 (ścieżka CSMWrap, `win-x86-uefi-csmwrap`)

Jedno z dwóch miejsc na DATA (oba są czytane):

```
DATA\Systems\Windows\Windows 7\Drivers\x86\Net\e1r62x86\
DATA\Drivers\Windows 7\e1r62x86\            (dowolny podfolder; klasy Storage/USB/Other też)
```

Pierwsze to biblioteka x86 USOS (tym samym drzewem jadą paczki USB 3), drugie
to zwykły folder użytkownika z `docs/drivers.md`. Katalog `Drivers\x86` jest
bezpieczniejszy, gdy na tej samej DATA leżą też paczki 64-bitowe: DISM w tym
kroku instaluje najpierw całe `Drivers\x86`, a dopiero potem
`Drivers\Windows 7`, więc obca architektura w drugim drzewie nie zasłoni
poprawnej paczki (jej błąd jest tylko logowany).
Bez KMDF 1.11 (MSU w `Windows 7\Updates`) z biblioteki idzie tylko podfolder
`Drivers\x86\Net`: paczki USB 3 zostają poza obrazem, żeby ich niedziałająca
usługa xHCI nie wyłączyła fallbacku `usosusb` (klawiatura i mysz na X470).

Po instalacji systemu (Setup `/noreboot`, przed pierwszym rozruchem) USOS
robi offline:

```
dism /Image:<dysk docelowy>\ /Add-Driver /Driver:D:\Systems\Windows\Windows 7\Drivers\x86 /Recurse /ForceUnsigned
dism /Image:<dysk docelowy>\ /Add-Driver /Driver:D:\Drivers\Windows 7              /Recurse /ForceUnsigned
```

### Windows 7 x64 / Server 2008 R2 x64 (natywne UEFI)

```
DATA\Drivers\Windows 7\e1r62x64\            (dowolny podfolder)
DATA\Drivers\Windows 7\Other\e1r62x64\      (klasa "Other" - sieć, grafika, ...)
```

`Drivers\Windows 7\Storage\`, `USB\` i `Other\` to klasy z `docs/drivers.md`;
folder poza nimi (albo pliki wprost w `Drivers\Windows 7`) liczy się jako
`Other`. Karta sieciowa to `Other`, ale dowolne z tych miejsc działa tak samo:
każdy folder z `.inf` jest jedną paczką.

Paczka trafia do archiwum `usos-drivers.bin` (`usos-win7-drivers\user\<klasa>\NN\`)
i dalej do zainstalowanego systemu:

* przez `DriverPaths` (`offlineServicing`, `Microsoft-Windows-PnpCustomizationsNonWinPE`)
  wskazujący `usos-win7-drivers` — Setup skanuje to drzewo rekursywnie:
  `tools/windows7_modern_startup.cmd:56`, `tools/windows7_native_startup.cmd:78`,
  `tools/windows_unattend_drivers.c:36-39`;
* albo, gdy instalacja idzie bez pliku odpowiedzi (ręczny Setup z PE7),
  przez `pnputil -i -a` w `SetupComplete.cmd` zainstalowanego systemu
  (`tools/windows7_setupcomplete.cmd:12-14`), po skopiowaniu paczek do
  `<dysk>:\USOS\Drivers` (`tools/windows7_native_startup.cmd:128`).

## 3. Jak sprawdzić, że działa

1. **Menedżer urządzeń** (`devmgmt.msc`): „Karty sieciowe” →
   `Intel(R) I211 Gigabit Network Connection`, bez żółtego wykrzyknika;
   Właściwości → Sterownik → Dostawca `Intel`, Wersja zgodna z paczką.
2. **Sterownik w magazynie** (konsola administratora):

   ```
   pnputil /enum-drivers
   ```

   Szukaj wpisu z `Nazwa pliku INF: e1r62x86.inf` (x86) lub `e1r62x64.inf`
   (x64) i `Nazwa klasy: Net`.
3. **Interfejs sieciowy**:

   ```
   ipconfig /all
   ```

   Karta „Intel(R) I211…” ma adres sprzętowy i (przy podłączonym kablu)
   adres IP; `ping` bramy działa.
4. **Logi USOS**:
   * x86 CSMWrap, na dysku docelowym: `\USOS-usb3\dism-drivers.log` (biblioteka
     `Drivers\x86`) i `\USOS-usb3\dism-user-drivers.log` (`Drivers\Windows 7`),
     a także `[USOS] USB3: … exit=…` na konsoli i w logu USOS
     (`tools/windows_x86_csmwrap.cmd:249` i `:257`).
   * x64 UEFI: `usos-win7-drivers\user\usos-user-drivers.log` (w archiwum
     i w WinPE), `\USOS\Drivers\usos-pnputil.log` (ścieżka bez pliku
     odpowiedzi), `Windows\Panther\setupact.log` oraz `Windows\INF\setupapi.dev.log`
     zainstalowanego systemu (`oem*.inf` z `e1r62*`).
5. Brak karty w Menedżerze urządzeń mimo poprawnej paczki: sprawdź, czy plik
   `.inf` leży w jednym z drzew z sekcji 2 (USOS nie czyta innych miejsc),
   i czy paczka jest 32/64-bit zgodna z instalowanym systemem.

## Dystrybucja w USOS

Decyzja właściciela projektu (2026-10-22): sterownik Intel I211 dla
Windows 7 / Server 2008 R2 (`e1r62x86` / `e1r62x64`) **dołączamy mimo
licencji**, ale **jako osobną paczkę w wydaniu** — GitHub Release i kopia na
archive.org, tak jak pakiet zgodności z plikami Microsoftu. **Nigdy w
repozytorium git**; paczka jest zawsze opisana jako **pliki Intela na licencji
Intela**, a użytkownik akceptuje licencję Intela przy pobieraniu (tak jak przy
pobieraniu od Intela).

### Układ paczki `USOS-<wersja>-NetDrivers-Intel.zip`

W środku jest dokładnie drzewo DATA, więc rozpakowanie paczki na partycję DATA
instaluje sterownik bez żadnej konwersji:

```
SOURCES.txt
Systems\Windows\Windows 7\Drivers\x86\Net\Intel-I211\   (e1r62x86.inf, .cat, .sys, ...)
Systems\Windows\Windows 7\Drivers\x64\Net\Intel-I211\   (e1r62x64.inf, .cat, .sys, ...)
```

`SOURCES.txt` (kopiowany obok INF każdej architektury) zawiera: wersję pakietu
Intela, URL strony pobrania (ID 15084), SHA-256 plików oraz zdanie „pliki
Intela na licencji Intela”.

### Instalacja paczki

* **Instalator / aktualizacja:** komponent `win7-net-intel`
  (`installer/internal/components`, wpisy w `status.go`, `release.go`,
  `win7net.go`) — pobiera `USOS-<wersja>-NetDrivers-Intel.zip` z wydania
  i weryfikuje SHA-256 (lista wkompilowana + `SHA256SUMS`), albo przyjmuje plik
  lokalny („Mam już plik”, ten sam `components.Runner`),
* **usos-physical-update:** `-components win7-net-intel` (raport bez tej flagi
  nic nie zapisuje; `COMPONENT win7-net-intel=current|missing`),
* **ręcznie:** rozpakuj zip na DATA — układ katalogów jest już właściwy.

Rozpakowanie waliduje obecność `.inf` w `Net\Intel-I211` (inny zip jest
odrzucany przed pierwszym zapisem), każdy plik jest zapisywany przez `.part`
i sprawdzany SHA-256, a plik identyczny z już obecnym nie jest nadpisywany
(ponowna instalacja nic nie duplikuje).

### Uwaga o architekturach

Windows 7 x86 dostaje **nasz** sterownik `usosnet` (nasz kod, `usosnet.sys`),
więc paczka Intel dotyczy głównie **Windows 7 x64 i Server 2008 R2 x64**
(wersja x86 jest w paczce dla 2008 R2 x86 i na wypadek, gdy `usosnet` nie jest
chciany) — dlatego komponent jest opcjonalny i nie wpływa na stan „kompletny”
penden Drive’a.

## Licencja sterownika Intela

Źródło: strona pobierania „Intel® Ethernet Adapter Complete Driver Pack”, ID
15084 —
<https://www.intel.com/content/www/us/en/download/15084/intel-ethernet-adapter-complete-driver-pack.html>.
Pełny tekst umowy jest na tej stronie (akceptacja licencji przed pobraniem),
wersja **Limited Distribution License Agreement [v2025.02.12]**. Sprawdzone
2026-10-22.

Postanowienia istotne dla USOS:

* **§1.6 „Your Products”** — produkt lub rozwiązanie, które **zawiera komponent
  Intel**: „includes an Intel Component implementing or executing Material”.
* **§2.1(c)** — wolno „distribute Redistributables in the format specified in
  redist.txt, or only as object code (or its equivalent) if no format is
  specified, **in Your Product**, provided your distribution is subject to
  terms and conditions consistent with your rights and obligations under this
  Agreement”.
* **§2.3** — poza dozwoleniem z §2.1 nie wolno używać ani modyfikować
  Materiałów w inny sposób.

Wnioski:

1. Redystrybucja jest dozwolona **tylko** dla plików wskazanych jako
   „Redistributables” w `redist.txt` z pakietu, **tylko** jako object code,
   **tylko jako część „Your Product”** (def. §1.6) i pod warunkami spójnymi
   z umową (§2.1(c)).
2. USOS jako uniwersalny instalator **nie jest** „Your Product” w rozumieniu
   §1.6 — **nie ma podstaw, by dołączać `PROWin32` / `PROWinx64` do wydania
   USOS, do assets release ani do „pakietu zgodności”**. Rekomendacja: USOS nie
   redystrybuuje sterowników Intela.
3. Wspierany scenariusz — dokładnie ten, który realizuje kod z sekcji 2:
   użytkownik sam pobiera pakiet od Intela (akceptując umowę) i kładzie
   rozpakowany folder z INF na swoją partycję DATA. To lokalne użycie własnej
   kopii na własnym nośniku, nie redystrybucja przez USOS.
4. Kto chce redystrybuować te pliki, musi sam sprawdzić `redist.txt`
   i §2.1(c) u Intela; USOS tego nie robi i nie odpowiada za taką dystrybucję.
