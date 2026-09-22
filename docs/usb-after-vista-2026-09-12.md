# Kingston niewidoczny jako nośnik startowy po instalacji Visty

Użytkownik potwierdził instalację Visty na MS-7100 i poprosił o odłożenie
diagnostyki jej niepełnych automatycznych restartów, aby pracować nad kolejnymi
Windowsami. Następnie zgłosił brak Kingstona wśród urządzeń rozruchowych BIOS-u.

## Kontrola nośnika — tylko odczyt

- Windows wykrywa Kingston DataTraveler 3.0, 61 991 813 632 bajty,
  GPT `31c644bf-74dd-4807-9cb2-46745adeadd4`.
- Wszystkie trzy partycje mają oczekiwane GUID-y, offsety i rozmiary.
- Obie kopie GPT mają poprawne CRC nagłówków i tablic wpisów.
- MBR ma sygnaturę `55 AA`; kod Stage 1 ma SHA-256
  `cc35473164009c30221bcc26fde48b42e1bcfcda1adaa512bf78020d9511c065`,
  zgodny ze sprawdzonym wydaniem.
- Cały Core jest identyczny bajt w bajt z `zig-out/legacy-bios/core-slot.bin`.
- ESP ma poprawną sygnaturę VBR i oznaczenie FAT32.
- BOOTX64.EFI, BOOTAA64.EFI i build-info.ini są zgodne SHA-256 z wydaniem
  `B260911-215613-B7E30104`.
- MBR zawiera jeden nieaktywny wpis ochronny GPT typu EE z rozmiarem
  `FFFFFFFF`. Ten wariant jest akceptowany przez dotychczasowy walidator
  projektu; nie stanowi sam w sobie dowodu zmiany po instalacji.

Nie wykryto uszkodzenia sprawdzonych składników rozruchu. Nie przepisywano
pendrive'a ani nie zmieniano partycji. Sam brak wpisu w BIOS-ie nie został
odtworzony lokalnie i nie jest oznaczony jako naprawiony.

Kolejny krok na MS-7100: całkowite wyłączenie zasilania na około 30 sekund,
następnie start z Kingstonem w tylnym porcie USB. Ma to sprawdzić wykrywanie
USB przy zimnym starcie po zgłoszonych niepełnych restartach. Jeśli nośnika
nadal nie ma, potrzebna jest kontrola wykrywania USB i listy dysków w BIOS-ie.
Nie zmieniać układu GPT ani nie formatować DATA bez ustalenia przyczyny.

Dowody: `zig-out/usb-after-vista/head.bin`, `tail.bin`; skrypty odczytu
`zig-out/native-vista-work/check_boot_usb.ps1`, `inspect_boot_usb.py`,
`verify_boot_files.ps1`.
