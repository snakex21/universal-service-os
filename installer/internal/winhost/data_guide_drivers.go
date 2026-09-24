package winhost

import (
	"path/filepath"
	"strings"
)

// driversGuide is DATA\Drivers\README.txt (Polish, then English). It is
// written on install and update; everything else under Drivers belongs to
// the user.
var driversGuide = dataGuide{
	relativePath: filepath.Join("Drivers", "README.txt"),
	contents:     []byte(strings.ReplaceAll(driversGuideText, "\n", "\r\n")),
}

const driversGuideText = `Universal Service OS - Sterowniki (Drivers)

=== POLSKI ===

Ten folder należy do Ciebie: instalacja i aktualizacja USOS tworzą tylko
brakujące foldery i nadpisują ten plik README.txt; nic innego nie jest usuwane.

1. Drivers\UEFI\<Nazwa>\ - sterowniki uruchamiane w menu USOS
   (dotyk, wejście, dyski, systemy plików). Każdy sterownik w osobnym folderze:
   plik .efi (sterownik x64 boot-service lub runtime, nie aplikacja) i opcjonalny
   driver.ini:

   [driver]
   name=Przyjazna nazwa
   type=input|storage|filesystem|other
   load=auto|off
   [match]                        ; opcjonalne; w jednej sekcji muszą pasować wszystkie klucze;
                                  ; kilka sekcji [match] = LUB
   smbios_manufacturer=ASUSTeK    ; prefiks, bez rozróżniania wielkości liter
   smbios_product=RC71L
   smbios_baseboard=RC71L
   pci=8086:9A0B                  ; obecne urządzenie PCI vendor:device
   acpi_hid=PNP0C50               ; ACPI HID obecny w DSDT/SSDT

   Bez [match] sterownik ładuje się na każdym komputerze (USOS pokazuje to
   w Narzędzia -> Sterowniki). Przy włączonym Secure Boot ładują się tylko
   sterowniki podpisane kluczem z bazy db firmware lub zarejestrowanym MOK
   (np. kluczem USOS); niepodpisane są pomijane ("wymaga wyłączenia Secure Boot
   lub podpisu"). Przy wyłączonym Secure Boot ładują się normalnie.
   Narzędzia -> Sterowniki pokazuje listę i włącza/wyłącza sterowniki.
   Sterownik, który zawiesił lub wywrócił menu, jest automatycznie blokowany
   przy następnym starcie (włączysz go ponownie na stronie Sterowniki).
   Dziennik: na ESP EFI\USOS\Logs\drivers.txt.

2. Drivers\<wersja Windows>\ - rozpakowane pakiety sterowników INF
   (INF+SYS+CAT, każdy pakiet w osobnym podfolderze). Tylko dodają sterowniki
   do tych, które USOS ma wbudowane: wbudowane są stosowane najpierw; gdy ten
   sam identyfikator sprzętu jest w obu, wybiera ranking Windows. Nic nie jest
   usuwane.
   Storage\ - kontrolery dysków potrzebne do startu (SATA/AHCI, RAID,
              Intel VMD/RST, NVMe): ładowane w Instalatorze Windows ORAZ
              dodawane do zainstalowanego systemu.
   USB\     - kontrolery USB 3, tak samo jak Storage.
   Other\   - wszystko inne (sieć, grafika, chipset): dodawane tylko do
              zainstalowanego systemu. Pliki leżące bezpośrednio w
              Drivers\<system>\ traktowane są jak Other.
   Używane są tylko sterowniki dla architektury instalacji (x64 - INF amd64,
   32-bit - INF x86). 64-bitowe Vista/7/10/11 ładują tylko podpisane sterowniki
   (pakiet musi mieć plik .cat); USOS nigdy nie omija podpisu sterowników.
   Uszkodzony pakiet jest pomijany i zapisywany w dzienniku, instalacja trwa dalej.

   Windows 11/10/8.1/8: sterowniki INF (USOS przygotowuje je przez folder
     $WinPEDriver$ Instalatora Windows: ładowane w instalatorze i dodawane
     do zainstalowanego systemu).
   Windows 7: sterowniki INF (x64; dodawane do biblioteki sterowników
     Windows 7 w USOS).
   Windows Vista: sterowniki INF - folder przygotowany, USOS jeszcze go nie
     używa (planowane).
   Windows XP: rozpakowane sterowniki INF; sterowniki dysków w trybie
     tekstowym wymagają txtsetup.oem - folder przygotowany, USOS jeszcze go
     nie używa (planowane; domyślne pozostają pakiety sterowników wbudowane
     w pakiet XP).
   Windows 98/Me/95: sterowniki INF - folder do ręcznego użycia.

=== ENGLISH ===

This folder is yours: installing and updating USOS only creates missing
folders and overwrites this README.txt; nothing else is deleted.

1. Drivers\UEFI\<Name>\ - drivers loaded by the USOS menu
   (touch, input, storage, filesystems). Each driver in its own folder:
   the .efi (x64 boot-service or runtime driver, not an application) and an
   optional driver.ini:

   [driver]
   name=Friendly name
   type=input|storage|filesystem|other
   load=auto|off
   [match]                        ; optional; all keys in one section must match;
                                  ; several [match] sections = OR
   smbios_manufacturer=ASUSTeK    ; prefix, case-insensitive
   smbios_product=RC71L
   smbios_baseboard=RC71L
   pci=8086:9A0B                  ; PCI vendor:device present
   acpi_hid=PNP0C50               ; ACPI HID present in DSDT/SSDT

   Without [match] the driver loads on every computer (USOS shows that on
   Tools -> Drivers). With Secure Boot on, only drivers signed by the firmware
   db or an enrolled MOK (e.g. the USOS key) load; unsigned ones are skipped
   ("requires Secure Boot off or a signature"). With Secure Boot off they load
   normally. Tools -> Drivers lists them and turns them on or off.
   A driver that hung or crashed the menu is blocked automatically on the next
   start (re-enable it on the Drivers page).
   Log: on the ESP, EFI\USOS\Logs\drivers.txt.

2. Drivers\<Windows version>\ - extracted INF driver packages
   (INF+SYS+CAT, each package in its own subfolder). They only add to the
   drivers USOS already bundles: bundled ones are applied first; if the same
   hardware ID is in both, Windows' own ranking picks. Nothing is deleted.
   Storage\ - boot-critical disk controllers (SATA/AHCI, RAID,
              Intel VMD/RST, NVMe): loaded in Windows Setup AND injected into
              the installed system.
   USB\     - USB 3 controllers, same treatment as Storage.
   Other\   - everything else (network, GPU, chipset): injected into the
              installed system only. Files directly in Drivers\<OS>\ count
              as Other.
   Only drivers for the target architecture are used (x64 installs use amd64
   INFs, 32-bit installs x86). 64-bit Vista/7/10/11 load only signed drivers
   (the package must have its .cat); USOS never bypasses driver signing.
   A broken package is skipped and logged; the installation goes on.

   Windows 11/10/8.1/8: INF drivers (prepared by USOS through Windows Setup's
     $WinPEDriver$ folder: loaded in Setup and added to the installed system).
   Windows 7: INF drivers (x64; added to USOS's Windows 7 driver library).
   Windows Vista: INF drivers - folder prepared, not yet used by USOS
     (planned).
   Windows XP: extracted INF drivers; textmode storage drivers need
     txtsetup.oem - folder prepared, not yet used by USOS (planned; the XP
     package's built-in driver bundles stay the default).
   Windows 98/Me/95: INF drivers - folder prepared for manual use.
`
