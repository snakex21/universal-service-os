package winmedia

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

// DismExtractor wypakowuje plik z WIM przez DISM. Wybrano DISM, bo jest
// czescia Windows i nie wymaga dokladania binarki do payloadu.
//
// Zaleznosci i ograniczenia (celowo jawne, nigdy ciche):
//   - dziala tylko na Windows: DISM nie istnieje na innych GOOS,
//   - wymaga uprawnien administratora (Mount-Wim),
//   - montuje zrodlo z /ReadOnly i odmontowuje z /Discard, wiec zrodlowy
//     WIM nigdy nie jest modyfikowany,
//   - dism /Export-Image NIE potrafi wyjac pojedynczego pliku, dlatego
//     sciezka to Mount-Wim -> copy -> Unmount-Wim.
type DismExtractor struct {
	// Exe to sciezka do dism.exe; puste = wyszukanie w PATH.
	Exe string
	// MountRoot to katalog na punkty montowania; puste = os.TempDir().
	MountRoot string
	// Run pozwala podmienic wykonanie komendy w testach; nil = exec.
	Run func(name string, args ...string) ([]byte, error)
}

// Available sprawdza, czy DISM jest osiagalny. Blad jest opisowy i mowi
// wywolujacemu, co zrobic.
func (d DismExtractor) Available() error {
	if runtime.GOOS != "windows" {
		return fmt.Errorf("DISM jest dostepny tylko na Windows (GOOS=%s); "+
			"na innym systemie wypakuj \\Windows\\Boot\\EFI\\bootmgfw.efi recznie (np. wimlib-imagex extract)", runtime.GOOS)
	}
	if _, err := d.resolveExe(); err != nil {
		return err
	}
	return nil
}

func (d DismExtractor) resolveExe() (string, error) {
	if strings.TrimSpace(d.Exe) != "" {
		return d.Exe, nil
	}
	path, err := exec.LookPath("dism")
	if err != nil {
		return "", fmt.Errorf("nie znaleziono dism.exe w PATH: %w; "+
			"uruchom instalator na Windows z uprawnieniami administratora", err)
	}
	return path, nil
}

// ExtractFile montuje wimPath:imageIndex tylko do odczytu, kopiuje
// pathInWIM do dst i odmontowuje obraz z /Discard.
func (d DismExtractor) ExtractFile(wimPath string, imageIndex int, pathInWIM, dst string) error {
	exe, err := d.resolveExe()
	if err != nil {
		return err
	}
	mountRoot := d.MountRoot
	if strings.TrimSpace(mountRoot) == "" {
		mountRoot = os.TempDir()
	}
	mountDir, err := os.MkdirTemp(mountRoot, "usos-wim-mount-")
	if err != nil {
		return fmt.Errorf("utworzenie punktu montowania: %w", err)
	}
	defer os.Remove(mountDir)

	if out, err := d.run(exe, "/Mount-Wim",
		"/WimFile:"+wimPath,
		"/index:"+strconv.Itoa(imageIndex),
		"/MountDir:"+mountDir,
		"/ReadOnly"); err != nil {
		return fmt.Errorf("dism /Mount-Wim %s:%d: %w: %s", wimPath, imageIndex, err, strings.TrimSpace(string(out)))
	}
	copyErr := copyFile(filepath.Join(mountDir, strings.TrimPrefix(filepath.FromSlash(pathInWIM), string(filepath.Separator))), dst)
	if out, err := d.run(exe, "/Unmount-Wim", "/MountDir:"+mountDir, "/Discard"); err != nil {
		if copyErr != nil {
			return fmt.Errorf("%w (dodatkowo dism /Unmount-Wim: %v: %s)", copyErr, err, strings.TrimSpace(string(out)))
		}
		return fmt.Errorf("dism /Unmount-Wim %s: %w: %s", mountDir, err, strings.TrimSpace(string(out)))
	}
	return copyErr
}

func (d DismExtractor) run(name string, args ...string) ([]byte, error) {
	if d.Run != nil {
		return d.Run(name, args...)
	}
	return exec.Command(name, args...).CombinedOutput()
}

// copyFile kopiuje plik zachowujac zwykle uprawnienia; katalog docelowy
// musi juz istniec.
func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return fmt.Errorf("odczyt %s z zamontowanego obrazu: %w", src, err)
	}
	if err := os.WriteFile(dst, data, 0o644); err != nil {
		return fmt.Errorf("zapis %s: %w", dst, err)
	}
	return nil
}
