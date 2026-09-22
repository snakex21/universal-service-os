package winmedia

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// Typowane bledy patchera UEFI.
var (
	// ErrUnknownClass oznacza odmowe patchowania nosnika, ktorego generacji
	// nie rozpoznano (nie wiadomo, skad wziac bootmgfw.efi).
	ErrUnknownClass = errors.New("nierozpoznana generacja nosnika: patch UEFI odmowiony")
	// ErrArchNotUEFICapable oznacza x86 (albo nieznana architekture):
	// czyste UEFI x64 bez CSM nie uruchomi takiego nosnika.
	ErrArchNotUEFICapable = errors.New("architektura nosnika nie nadaje sie na czyste UEFI x64")
	// ErrMissingBCD oznacza brak efi/microsoft/boot/bcd. Patcher nie
	// fabrykuje BCD; oryginalne ISO Windows 7 x64 zawiera kompletny plik.
	ErrMissingBCD = errors.New("brak efi/microsoft/boot/bcd: patcher nie tworzy BCD samodzielnie")
	// ErrExtractorUnavailable oznacza brak narzedzia do wypakowania pliku
	// z WIM (DISM/wimlib). Blad jest zawsze opisowy, nigdy cichy.
	ErrExtractorUnavailable = errors.New("brak narzedzia do wypakowania pliku z obrazu WIM")
	// ErrNoBootloaderSource oznacza, ze w zrodlowym WIM nie ma obrazu
	// x64, z ktorego mozna wziac bootmgfw.efi.
	ErrNoBootloaderSource = errors.New("zrodlowy WIM nie zawiera obrazu x64 z \\Windows\\Boot\\EFI\\bootmgfw.efi")
)

// FAT32MaxFileBytes to najwiekszy plik, jaki miesci sie na FAT32.
// Firmware UEFI widzi tylko FAT32, wiec kazdy wiekszy plik na nosniku
// czyni uklad niezapisywalnym na docelowy pendrive.
const FAT32MaxFileBytes int64 = 4*1024*1024*1024 - 1

// OversizeFileError nazywa plik przekraczajacy limit FAT32.
type OversizeFileError struct {
	// Path to sciezka pliku wzgledem roota nosnika.
	Path string
	// Size to rozmiar w bajtach.
	Size int64
	// Limit to obowiazujacy limit (domyslnie FAT32MaxFileBytes).
	Limit int64
}

func (e *OversizeFileError) Error() string {
	return fmt.Sprintf("plik %s ma %d bajtow i przekracza limit FAT32 (%d bajtow); "+
		"podziel obraz na czesci (dism /Split-Image /FileSize:3800 albo wimlib-imagex split) przed zapisem na nosnik UEFI",
		e.Path, e.Size, e.Limit)
}

// BootmgfwPathInWIM to sciezka bootloadera wewnatrz obrazu WIM.
const BootmgfwPathInWIM = `\Windows\Boot\EFI\bootmgfw.efi`

// WIMExtractor wypakowuje pojedynczy plik z obrazu WIM bez modyfikowania
// zrodla. Interfejs izoluje zaleznosc zewnetrzna (DISM), zeby patcher dal
// sie testowac bez prawdziwego ISO i bez DISM.
type WIMExtractor interface {
	// Available zwraca opisowy blad, gdy narzedzia nie ma w systemie.
	Available() error
	// ExtractFile kopiuje pathInWIM z obrazu wimPath:imageIndex do dst.
	// Zrodlo jest montowane wylacznie do odczytu i odmontowywane bez zapisu.
	ExtractFile(wimPath string, imageIndex int, pathInWIM, dst string) error
}

// PatchResult opisuje, co patcher faktycznie zrobil.
type PatchResult struct {
	// Changed jest false przy powtornym uruchomieniu (idempotencja).
	Changed bool
	// Bootx64Path to sciezka efi/boot/bootx64.efi po patchu.
	Bootx64Path string
	// SourceWIM i SourceImageIndex wskazuja zrodlo bootmgfw.efi.
	SourceWIM        string
	SourceImageIndex int
	// Actions to log krokow do przekazania do UI/journalu.
	Actions []string
}

// Patcher wykonuje patch UEFI. Zerowa wartosc jest gotowa do uzycia
// i stosuje limit FAT32.
type Patcher struct {
	// MaxFileBytes nadpisuje limit rozmiaru pliku; 0 = FAT32MaxFileBytes.
	MaxFileBytes int64
}

// PatchUEFI czyni sklasyfikowany nosnik startowalnym na czystym UEFI x64
// z wylaczonym CSM. Skrot na Patcher{}.Patch.
func PatchUEFI(media Media, extractor WIMExtractor) (PatchResult, error) {
	return Patcher{}.Patch(media, extractor)
}

// Patch wykonuje wlasciwy patch. Wymagania i ograniczenia:
//
//   - nosnik musi byc x64 (x86 odmowa) i rozpoznany (UNKNOWN odmowa),
//   - docelowy system plikow musi byc FAT32, wiec zaden plik nie moze
//     przekraczac 4 GiB - 1 B; wieksze pliki sa zglaszane jako blad,
//   - efi/microsoft/boot/bcd musi istniec; patcher go nie tworzy,
//   - Secure Boot musi byc wylaczony (bootloader Win7 nie jest podpisany
//     kluczem akceptowanym przez wspolczesne UEFI z wlaczonym SB).
//
// Wszystkie kontrole odmowy wykonuja sie przed jakimkolwiek zapisem, wiec
// odmowa nigdy nie zostawia czesciowo zapatchowanego nosnika. Powtorne
// wywolanie na zapatchowanym nosniku jest no-opem (Changed=false).
func (p Patcher) Patch(media Media, extractor WIMExtractor) (PatchResult, error) {
	var result PatchResult

	if media.Class == ClassUnknown {
		return result, fmt.Errorf("%w (install=%s boot=%s)", ErrUnknownClass,
			versionOrNone(media.InstallVersion, media.InstallVersionKnown),
			versionOrNone(media.BootVersion, media.BootVersionKnown))
	}
	if media.Arch != ArchX64 {
		return result, fmt.Errorf("%w: arch=%s", ErrArchNotUEFICapable, ArchName(media.Arch))
	}
	if err := checkFileSizeLimit(media.Root, p.limit()); err != nil {
		return result, err
	}
	if _, ok := lookupPath(media.Root, "efi", "microsoft", "boot", "bcd"); !ok {
		return result, fmt.Errorf("%w (root=%s)", ErrMissingBCD, media.Root)
	}

	if path, ok := lookupPath(media.Root, "efi", "boot", "bootx64.efi"); ok {
		result.Bootx64Path = path
		result.Actions = append(result.Actions, "efi/boot/bootx64.efi juz istnieje: brak zmian")
		return result, nil
	}

	sourceWIM, imageIndex, err := bootloaderSource(media)
	if err != nil {
		return result, err
	}
	if extractor == nil {
		return result, fmt.Errorf("%w: nie podano implementacji WIMExtractor", ErrExtractorUnavailable)
	}
	if err := extractor.Available(); err != nil {
		return result, fmt.Errorf("%w: %v", ErrExtractorUnavailable, err)
	}

	bootDir, err := ensureDir(media.Root, "efi", "boot")
	if err != nil {
		return result, err
	}
	dst := filepath.Join(bootDir, "bootx64.efi")
	if err := extractor.ExtractFile(sourceWIM, imageIndex, BootmgfwPathInWIM, dst); err != nil {
		return result, fmt.Errorf("wypakowanie %s z %s:%d: %w", BootmgfwPathInWIM, sourceWIM, imageIndex, err)
	}
	if stat, err := os.Stat(dst); err != nil || stat.Size() == 0 {
		return result, fmt.Errorf("wypakowany %s jest pusty albo nieczytelny", dst)
	}

	result.Changed = true
	result.Bootx64Path = dst
	result.SourceWIM = sourceWIM
	result.SourceImageIndex = imageIndex
	result.Actions = append(result.Actions,
		fmt.Sprintf("wypakowano %s z %s (index %d) do efi/boot/bootx64.efi", BootmgfwPathInWIM, filepath.Base(sourceWIM), imageIndex))
	return result, nil
}

// bootloaderSource wybiera zrodlo bootmgfw.efi:
//   - WIN7_PE10 i WIN10: boot.wim (bootloader Win10 podpisany przez MS,
//     obsluguje wspolczesne firmware lepiej niz bootmgr z 2009 roku),
//   - WIN7_PE7: install.wim (boot.wim WinPE 3.x bywa bez katalogu Boot\EFI).
func bootloaderSource(media Media) (string, int, error) {
	candidates := []string{media.InstallImagePath}
	if media.Class == ClassWin7PE10 || media.Class == ClassWin10 {
		candidates = []string{media.BootImagePath, media.InstallImagePath}
	}
	for _, path := range candidates {
		if path == "" {
			continue
		}
		info, err := ReadWIMInfo(path)
		if err != nil {
			return "", 0, err
		}
		// boot.wim: ostatni obraz to Setup (pelny katalog \Windows\Boot\EFI).
		// install.wim: pierwszy obraz x64 wystarczy, bootloader jest wspolny.
		if path == media.BootImagePath {
			if index, ok := info.LastImageIndexForArch(ArchX64); ok {
				return path, index, nil
			}
			continue
		}
		if index, ok := info.FirstImageIndexForArch(ArchX64); ok {
			return path, index, nil
		}
	}
	return "", 0, ErrNoBootloaderSource
}

func (p Patcher) limit() int64 {
	if p.MaxFileBytes > 0 {
		return p.MaxFileBytes
	}
	return FAT32MaxFileBytes
}

// CheckFAT32Compatible sprawdza, czy caly uklad nosnika da sie zapisac na
// FAT32 (wymog firmware UEFI). Zwraca *OversizeFileError dla pierwszego
// pliku przekraczajacego limit.
func CheckFAT32Compatible(root string) error {
	return checkFileSizeLimit(root, FAT32MaxFileBytes)
}

func checkFileSizeLimit(root string, limit int64) error {
	return filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return fmt.Errorf("skan nosnika %s: %w", path, err)
		}
		if entry.IsDir() || !entry.Type().IsRegular() {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return fmt.Errorf("odczyt rozmiaru %s: %w", path, err)
		}
		if info.Size() > limit {
			rel, relErr := filepath.Rel(root, path)
			if relErr != nil {
				rel = path
			}
			return &OversizeFileError{Path: filepath.ToSlash(rel), Size: info.Size(), Limit: limit}
		}
		return nil
	})
}

// ensureDir znajduje albo tworzy katalog wzgledny, zachowujac istniejaca
// wielkosc liter segmentow, ktore juz sa na nosniku.
func ensureDir(root string, parts ...string) (string, error) {
	current := root
	for _, want := range parts {
		if match, ok := lookupChild(current, want); ok {
			current = match
			continue
		}
		current = filepath.Join(current, want)
		if err := os.MkdirAll(current, 0o755); err != nil {
			return "", fmt.Errorf("utworzenie katalogu %s: %w", current, err)
		}
	}
	return current, nil
}

func versionOrNone(v Version, known bool) string {
	if !known {
		return "brak"
	}
	return v.String()
}
