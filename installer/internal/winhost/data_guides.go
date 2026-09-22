package winhost

import "path/filepath"

type dataGuide struct {
	relativePath string
	contents     []byte
}

var dataGuides = []dataGuide{
	{
		relativePath: filepath.Join("Systems", "Windows", "Windows 7", "Drivers", "README.txt"),
		contents:     []byte("Windows 7 x64 UEFI (WinPE10 staging, nowy sprzet: Ryzen/XHCI) + retro BIOS vanilla\r\n\r\nDo podfolderu x64 skopiuj rozpakowane sterowniki Windows 7 dla kontrolera USB 3 (XHCI, podpisane INF+SYS+CAT). Zachowaj komplet INF, SYS, CAT w osobnych katalogach producentow. Sam instalator EXE nie wystarcza. Nazwy ASCII; maks. 512 plikow i 64 MiB.\r\n\r\nZASADY STAGINGU (win7-uefi-x64-modern): staging ZAWSZE z WinPE10 (WinPE7 nie wchodzi na nowym USB - brak XHCI), tylko Win7 x64, GPT+FAT32 ESP, Secure Boot OFF.\r\n- win7-bios-vanilla (retro): bez zmian, vanilla WIM nietkniety.\r\n- win7-uefi-x64-modern: Autounattend.xml (oobeSystem: SkipMachineOOBE, SkipUserOOBE, ProtectYourPC=3, HideEULA, InputLocale pl-PL, AutoLogon + FirstLogonCommands -> SetupComplete.cmd) + DriverPaths -> Drivers\\x64; offline DISM: mount boot.wim:1,2 + install.wim + /Image:W:\\ /Add-Driver /Recurse /ForceUnsigned; SetupComplete.cmd fallback z pnputil gdy OOBE przeszlo bez USB (martwe USB). Patch tylko na target po apply-image, nigdy vanilla WIM na stale.\r\n- Rollback bootloadera PRZED zapisem na dysk SATA: backup ESP:\\EFI\\Microsoft\\Boot\\{BCD,BCD.LOG*,bootmgfw.efi} + dump bcdedit /enum firmware (lub efibootmgr -v) + journal; staging jako one-shot BootNext + timeout bez ruszania BootOrder; bcdboot W:\\Windows /s S: /f UEFI dopiero po verify apply-image; watchdog: brak 2. rebootu / SetupComplete OK -> restore BCD+NVRAM + domyslny wpis, USB zostaje do potwierdzenia.\r\n\r\nBIOS/UEFI (ASRock X470, Ryzen 7 5700X, RX560, SATA, brak PS/2): do pierwszego testu CSM Enabled, SecureBoot Off, FastBoot Off, SATA AHCI, XHCI Handoff Enabled. Potem czyste UEFI + UefiSeven_am5 (bootx64.efi chainload - tylko opis, bez binarek: podmien ESP\\EFI\\Boot\\bootx64.efi na chainloader UefiSeven, oryginal zachowaj jako bootx64-usos.efi i dodaj wpis BootNext; po udanym starcie Win7 na czystym UEFI zostaw chainload, po niepowodzeniu wroc do kopii).\r\n"),
	},
	{
		relativePath: filepath.Join("Utilities", "FreeDOS", "README.txt"),
		contents:     []byte("Universal Service OS - FreeDOS\r\n\r\nProgramy DOS kopiuj do Utilities\\FreeDOS\\Programs.\r\nKażdy program może mieć osobny folder; trzymaj razem EXE/COM/BAT, pliki danych, BIOS-u i wymagany DOS extender.\r\nUżywaj nazw DOS 8.3 (do 8 znaków nazwy i do 3 znaków rozszerzenia).\r\n\r\nUruchom pendrive w trybie BIOS i wybierz Utilities -> FreeDOS.\r\nFreeDOS jest wbudowany; nie trzeba dodawać ISO ani uruchamiać aktualizatora po skopiowaniu programów.\r\nWymagane co najmniej 128 MiB RAM. Procesor 64-bitowy nie jest wymagany.\r\n\r\nMenedżer plików: strzałki i Enter wybierają folder lub program.\r\nCtrl+Enter wstawia nazwę programu do wiersza poleceń: dopisz potrzebne parametry i naciśnij Enter.\r\nF3: podgląd pliku, F10: wyjście do DOS. Polecenie TOOLS otwiera ponownie menedżer; REBOOT restartuje USOS.\r\n\r\nProgramy są kopiowane do C:\\PROGRAMS na dysku RAM 64 MiB. Pliki wynikowe i zmiany znikają po restarcie.\r\nKopia BIOS-u zapisana wyłącznie na C: nie przetrwa restartu.\r\nFreeDOS uruchamia się bez HIMEM/EMM386. Zgodność flashera z FreeDOS i sprzętem sprawdź w jego instrukcji; nic nie jest flashowane automatycznie.\r\n"),
	},
	{
		relativePath: filepath.Join("Systems", "README.txt"),
		contents:     []byte("Universal Service OS - Systems\r\n\r\nKażdy system ma gotowy katalog profilu.\r\nObrazy ISO/WIM/IMG/VHD/VHDX/EFI kopiuj do folderu Images odpowiedniego profilu.\r\nPliki automatycznej instalacji, jeżeli profil je obsługuje, kopiuj do folderu Unattended.\r\n\r\nStabilne Windows: Systems\\Windows\r\nLinux: Systems\\Linux\r\nPrototypy i bety Windows (Whistler, Longhorn, Neptune itd.): Systems\\Betas\r\nDOS: Systems\\DOS\r\n\r\nOpcjonalna ikona profilu: icon.png w katalogu profilu, obok Images.\r\nPo dodaniu lub zmianie icon.png uruchom Aktualizuj USOS, aby odświeżyć metadane menu na ESP.\r\n"),
	},
	{
		relativePath: filepath.Join("Utilities", "README.txt"),
		contents:     []byte("Universal Service OS - Utilities\r\n\r\nTutaj sam tworzysz folder dla każdego narzędzia, np. Utilities\\MemTest86.\r\nW folderze narzędzia utwórz Images i umieść tam ISO/WIM/IMG/VHD/VHDX/EFI.\r\nPrzykład: Utilities\\MemTest86\\Images\\memtest86.efi\r\n\r\nOpcjonalna ikona: Utilities\\MemTest86\\icon.png\r\nicon.png musi być prawidłowym PNG i mieć maksymalnie 1 MiB.\r\nPo dodaniu, usunięciu lub zmianie narzędzia albo icon.png uruchom Aktualizuj USOS. Aktualizator odświeży mały katalog metadanych na ESP bez kopiowania dużych obrazów.\r\n"),
	},
	{
		relativePath: filepath.Join("Programs", "README.txt"),
		contents:     []byte("Universal Service OS - Programs\r\n\r\nTen katalog jest przeznaczony na programy do instalacji lub uruchamiania już po starcie docelowego systemu operacyjnego.\r\nKażdy program trzymaj w osobnym folderze, np. Programs\\7-Zip lub Programs\\Drivers.\r\n\r\nKonwencja metadanych programu:\r\n  icon.png   - opcjonalna ikona programu do wykorzystania przez interfejsy pracujące już w systemie\r\n\r\nBoot menu USOS wyświetla obecnie icon.png dla profili systemów i narzędzi z Utilities. Programs nie jest menu bootowalnym.\r\nUSOS nie udaje uruchamiania zwykłych plików Windows EXE bez Windows. Narzędzia bootowalne umieszczaj w Utilities.\r\n"),
	},
}

func dataGuidesTotalBytes() uint64 {
	var total uint64
	for _, guide := range dataGuides {
		total += uint64(len(guide.contents))
	}
	return total
}
