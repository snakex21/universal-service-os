package winhost

import "path/filepath"

type dataGuide struct {
	relativePath string
	contents     []byte
}

var dataGuides = []dataGuide{
	{
		relativePath: filepath.Join("Systems", "README.txt"),
		contents: []byte("Universal Service OS - Systems\r\n\r\nKażdy system ma gotowy katalog profilu.\r\nObrazy ISO/WIM/IMG/VHD/VHDX/EFI kopiuj do folderu Images odpowiedniego profilu.\r\nPliki automatycznej instalacji, jeżeli profil je obsługuje, kopiuj do folderu Unattended.\r\n\r\nStabilne Windows: Systems\\Windows\r\nLinux: Systems\\Linux\r\nPrototypy i bety Windows (Whistler, Longhorn, Neptune itd.): Systems\\Betas\r\nDOS: Systems\\DOS\r\n\r\nOpcjonalna ikona profilu: icon.png w katalogu profilu, obok Images.\r\nPo dodaniu lub zmianie icon.png uruchom Aktualizuj USOS, aby odświeżyć metadane menu na ESP.\r\n"),
	},
	{
		relativePath: filepath.Join("Utilities", "README.txt"),
		contents: []byte("Universal Service OS - Utilities\r\n\r\nTutaj sam tworzysz folder dla każdego narzędzia, np. Utilities\\MemTest86.\r\nW folderze narzędzia utwórz Images i umieść tam ISO/WIM/IMG/VHD/VHDX/EFI.\r\nPrzykład: Utilities\\MemTest86\\Images\\memtest86.efi\r\n\r\nOpcjonalna ikona: Utilities\\MemTest86\\icon.png\r\nicon.png musi być prawidłowym PNG i mieć maksymalnie 1 MiB.\r\nPo dodaniu, usunięciu lub zmianie narzędzia albo icon.png uruchom Aktualizuj USOS. Aktualizator odświeży mały katalog metadanych na ESP bez kopiowania dużych obrazów.\r\n"),
	},
	{
		relativePath: filepath.Join("Programs", "README.txt"),
		contents: []byte("Universal Service OS - Programs\r\n\r\nTen katalog jest przeznaczony na programy do instalacji lub uruchamiania już po starcie docelowego systemu operacyjnego.\r\nKażdy program trzymaj w osobnym folderze, np. Programs\\7-Zip lub Programs\\Drivers.\r\n\r\nKonwencja metadanych programu:\r\n  icon.png   - opcjonalna ikona programu do wykorzystania przez interfejsy pracujące już w systemie\r\n\r\nBoot menu USOS wyświetla obecnie icon.png dla profili systemów i narzędzi z Utilities. Programs nie jest menu bootowalnym.\r\nUSOS nie udaje uruchamiania zwykłych plików Windows EXE bez Windows. Narzędzia bootowalne umieszczaj w Utilities.\r\n"),
	},
}

func dataGuidesTotalBytes() uint64 {
	var total uint64
	for _, guide := range dataGuides {
		total += uint64(len(guide.contents))
	}
	return total
}
