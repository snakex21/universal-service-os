package payload

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEmbeddedPayloadHasRequiredFiles(t *testing.T) {
	bundle, err := Embedded()
	if err != nil {
		t.Fatal(err)
	}
	manifest, err := bundle.Manifest()
	if err != nil {
		t.Fatal(err)
	}
	required := map[string]bool{
		"EFI/BOOT/BOOTX64.EFI":                false,
		"EFI/BOOT/BOOTAA64.EFI":               false,
		"EFI/USOS/ntfs_x64.efi":               false,
		"EFI/USOS/systemd-bootx64.efi":        false,
		"EFI/USOS/micro-linux/vmlinuz-virt":   false,
		"EFI/USOS/micro-linux/initramfs-usos": false,
		"UI/index.html":                       false,
		"UI/theme.css":                        false,
		"UI/Icons/Systems/windows-11.png":     false,
	}
	for _, file := range manifest {
		if file.Size == 0 || file.SHA256 == "" {
			t.Fatalf("invalid manifest entry: %+v", file)
		}
		if _, ok := required[file.Path]; ok {
			required[file.Path] = true
		}
	}
	for path, found := range required {
		if !found {
			t.Fatalf("embedded payload missing %s", path)
		}
	}
}

func TestEmbeddedPayloadContainsOnlyStaticESPFiles(t *testing.T) {
	bundle, err := Embedded()
	if err != nil {
		t.Fatal(err)
	}
	manifest, err := bundle.Manifest()
	if err != nil {
		t.Fatal(err)
	}
	for _, file := range manifest {
		if !strings.HasPrefix(file.Path, "EFI/") && !strings.HasPrefix(file.Path, "UI/") {
			t.Fatalf("non-ESP DATA/catalog file embedded in payload: %s", file.Path)
		}
	}
}

func TestEmbeddedREADMEContainsOperationalInstructions(t *testing.T) {
	readme, err := README()
	if err != nil {
		t.Fatal(err)
	}
	text := string(readme)
	required := []string{
		"DATA:\\Systems\\Windows\\Windows 11\\Images",
		"DATA:\\Systems\\Windows\\Windows 11\\Unattended",
		"DATA:\\Programs\\USOS\\USOS Installer.exe",
		"WORK",
		"ukryta partycja robocza",
		"Instalacja",
		"Aktualizacja lokalna",
		"Naprawa",
		"Deinstalacja",
		"USOS Installer.log",
		"Nie uruchamiaj instalatora bezpośrednio z pendrive'a",
	}
	for _, fragment := range required {
		if !strings.Contains(text, fragment) {
			t.Fatalf("embedded README missing %q", fragment)
		}
	}
}

func TestExtractReportsRealByteProgress(t *testing.T) {
	bundle, err := Embedded()
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	var lastDone, lastTotal uint64
	if err := bundle.Extract(root, func(done, total uint64) {
		if done < lastDone {
			t.Fatalf("progress regressed: %d -> %d", lastDone, done)
		}
		lastDone, lastTotal = done, total
	}); err != nil {
		t.Fatal(err)
	}
	if lastTotal == 0 || lastDone != lastTotal {
		t.Fatalf("final progress=%d/%d", lastDone, lastTotal)
	}
	if info, err := os.Stat(filepath.Join(root, "EFI", "BOOT", "BOOTX64.EFI")); err != nil || info.Size() == 0 {
		t.Fatalf("BOOTX64.EFI not extracted correctly: info=%v err=%v", info, err)
	}
	if info, err := os.Stat(filepath.Join(root, "UI", "Icons", "Systems", "windows-11.png")); err != nil || info.Size() == 0 {
		t.Fatalf("Windows 11 icon not extracted correctly: info=%v err=%v", info, err)
	}
}
