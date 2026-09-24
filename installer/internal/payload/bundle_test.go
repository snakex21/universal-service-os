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
		"EFI/BOOT/BOOTX64.EFI":                    false,
		"EFI/USOS/build-info.ini":                 false,
		"EFI/BOOT/BOOTAA64.EFI":                   false,
		"EFI/USOS/ntfs_x64.efi":                   false,
		"EFI/USOS/systemd-bootx64.efi":            false,
		"EFI/USOS/micro-linux/vmlinuz-virt":       false,
		"EFI/USOS/micro-linux/initramfs-usos":     false,
		"UI/index.html":                           false,
		"UI/theme.css":                            false,
		"UI/Icons/Systems/windows-11.png":         false,
		"EFI/USOS/dos-native/msdos/HIMEMX.EXE":    false,
		"EFI/USOS/dos-native/msdos/HIMEMX.TXT":    false,
		"EFI/USOS/dos-native/msdos/HIMEMSRC.ZIP":  false,
		"EFI/USOS/dos-native/msdos/LICENSE.TXT":   false,
		"EFI/USOS/dos-native/msdos/manifest.json": false,
		"EFI/USOS/dos-native/msdos/INSTALL.BAT":   false,
		"EFI/USOS/dos-native/msdos/LIVE.BAT":      false,
		"EFI/USOS/dos-native/msdos/PREPDOS.BAT":   false,
		"EFI/USOS/dos-native/msdos/COPYDOS.BAT":   false,
		"EFI/USOS/dos-native/msdos/UNPACK.BAT":    false,
		"EFI/USOS/dos-native/msdos/W3START.BAT":   false,
		"EFI/USOS/dos-native/msdos/WINMENU.BAT":   false,
		"EFI/USOS/dos-native/msdos/W3CONFIG.SYS":  false,
		"EFI/USOS/dos-native/msdos/W3AUTO.BAT":    false,
		"EFI/USOS/dos-native/msdos/REBOOT.COM":    false,
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

func TestEmbeddedPayloadExposesBootManagerIdentity(t *testing.T) {
	bundle, err := Embedded()
	if err != nil {
		t.Fatal(err)
	}
	file, err := bundle.File(BootManagerPath)
	if err != nil {
		t.Fatal(err)
	}
	if file.Path != BootManagerPath || file.Size == 0 || len(file.SHA256) != 64 {
		t.Fatalf("invalid BOOTX64.EFI identity: %+v", file)
	}
}

func TestEmbeddedPayloadBuildInfoIsValid(t *testing.T) {
	bundle, err := Embedded()
	if err != nil {
		t.Fatal(err)
	}
	info, err := bundle.BuildInfo()
	if err != nil {
		t.Fatal(err)
	}
	if !info.Valid() {
		t.Fatalf("invalid embedded build info: %+v", info)
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
		// USOS-KEY.cer: the Secure Boot certificate at the ESP root.
		if !strings.HasPrefix(file.Path, "EFI/") && !strings.HasPrefix(file.Path, "UI/") && file.Path != "USOS-KEY.cer" {
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
		"widoczna jako `USOS_WORK` dla Windows Setup",
		"jej zawartość jest usuwana przed każdą instalacją",
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

func TestExtractOverwritesExistingBootManager(t *testing.T) {
	bundle, err := Embedded()
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	bootPath := filepath.Join(root, "EFI", "BOOT", "BOOTX64.EFI")
	if err := os.MkdirAll(filepath.Dir(bootPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(bootPath, []byte("stale bootmanager"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := bundle.Extract(root, nil); err != nil {
		t.Fatal(err)
	}
	if err := bundle.Verify(root); err != nil {
		t.Fatalf("overwritten payload failed SHA-256 verification: %v", err)
	}
	info, err := os.Stat(bootPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Size() == int64(len("stale bootmanager")) {
		t.Fatalf("BOOTX64.EFI was not overwritten: size=%d", info.Size())
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
