# Układ danych na nośniku

## Główne kategorie

Nośnik jest czytelny również bez uruchamiania Universal Service OS:

- `Systems/Windows/` - stabilne wydania Windows,
- `Systems/Linux/` - dystrybucje Linux,
- `Systems/Betas/` - rozwojowe i beta buildy Windows,
- `Systems/DOS/` - systemy DOS,
- `Utilities/` - diagnostyka, recovery, firmware, sieć i narzędzia bootujące,
- `Programs/` - programy przeznaczone do instalacji po instalacji systemu,
- `UI/` - HTML i CSS interfejsu.

## Partycje techniczne

- ESP: FAT32, pliki startowe USOS i sterownik NTFS UEFI.
- DATA: NTFS, Microsoft Basic Data GPT.
- WORK: NTFS, Microsoft Basic Data GPT `EBD0A0A2-B9E5-4433-87C0-68B6B72699C7`, etykieta `USOS_WORK`.

WORK nie używa własnego typu GPT, ponieważ WinPE nie montuje niestandardowego typu jako zwykłej partycji danych. Tożsamość WORK jest chroniona przez PARTUUID i dysk nadrzędny oraz dodatkowo przez `.usos-work`; plik zawiera nonce zgodny z `EFI/USOS/usos-device.ini`. Po formatowaniu `.usos-work` jest pierwszym zwykłym plikiem zapisywanym na WORK, przed rozpakowaniem instalatora.

## Obrazy

Każdy profil ma własny katalog `Images`. Obsługiwane w katalogu są obecnie formaty rozpoznawane jako:

- ISO,
- WIM,
- IMG,
- VHD,
- VHDX,
- EFI.

Nazwa pliku jest dowolna. Format i metoda startu są rozdzielone: po wybraniu obrazu GUI pokazuje tylko metody zgodne z profilem i typem pliku.

## Windows

Przykład:

`Systems/Windows/Windows 11/Images/`
`Systems/Windows/Windows 11/Unattended/`

Wbudowane profile obejmują Windows 11, 10, 8.1, 8, 7, Vista, XP, 2000, NT 4.0, Me, 98 SE, 98, 95 i 3.11.

## Linux

`Systems/Linux/`

Wbudowane profile: Ubuntu, Debian, Fedora, Linux Mint, Arch Linux, openSUSE, Manjaro, Kali Linux i Other Linux. Każdy ma `Images` i `Unattended`.

## Beta builds

`Systems/Betas/`

Whistler, Longhorn, Neptune, Chicago, Memphis i Nashville są oddzielone od normalnych Windowsów. Każdy profil ma `Images` i `Unattended`.

## DOS

`Systems/DOS/`

FreeDOS, MS-DOS, PC DOS, DR-DOS, OpenDOS i Other DOS. Każdy ma `Images`; obrazy IMG mogą później korzystać także z trybów floppy/disk/memdisk.

## Utilities

`Utilities/`

- `Memory Tests/Images/`
- `Disk & Storage/Images/`
- `Recovery/Images/`
- `Firmware & BIOS/Images/`
- `Network/Images/`
- `Boot & Partition/Images/`
- `Hardware Diagnostics/Images/`
- `Other Utilities/Images/`

Utilities są osobną kategorią GUI, a nie systemem operacyjnym w menu.
