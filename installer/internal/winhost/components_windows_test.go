//go:build windows

package winhost

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/components"
)

func hexSum(data []byte) string {
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}

func writeZip(t *testing.T, path string, files map[string][]byte) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	z := zip.NewWriter(f)
	for name, data := range files {
		w, err := z.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		w.Write(data)
	}
	if err := z.Close(); err != nil {
		t.Fatal(err)
	}
	f.Close()
}

// fakeESP is a folder laid out like a USOS_ESP (build-info.ini, micro-Linux).
func fakeESP(t *testing.T, base []byte) string {
	t.Helper()
	esp := t.TempDir()
	os.MkdirAll(filepath.Join(esp, "EFI", "USOS", "micro-linux"), 0o755)
	os.WriteFile(filepath.Join(esp, "EFI", "USOS", "build-info.ini"), []byte("[build]\r\nid=B260929-000000-TEST\r\n"), 0o644)
	os.WriteFile(filepath.Join(esp, "EFI", "USOS", "micro-linux", "initramfs-usos"), base, 0o644)
	return esp
}

func xpPackageZip(t *testing.T, lang string, base []byte) string {
	t.Helper()
	script, err := os.ReadFile(filepath.Join("..", "..", "..", "tools", "release", "install-xp-package.ps1"))
	if err != nil {
		t.Fatal(err)
	}
	initramfs, kernel := []byte("xp initramfs "+lang), []byte("xp kernel")
	manifest := `{"release":true,"release_lang":"` + lang + `","base_initramfs_sha256":"` + hexSum(base) + `",` +
		`"sha256":{"initramfs-xp":"` + hexSum(initramfs) + `","vmlinuz.efi":"` + hexSum(kernel) + `"},` +
		`"driver_sources":[{"name":"test.iso","sha256":"` + strings.Repeat("0", 64) + `"}]}`
	path := filepath.Join(t.TempDir(), "USOS-9.9.9-XP-package-"+strings.ToUpper(lang)+".zip")
	writeZip(t, path, map[string][]byte{
		"EFI/USOS-XP/initramfs-xp":  initramfs,
		"EFI/USOS-XP/vmlinuz.efi":   kernel,
		"EFI/USOS-XP/manifest.json": []byte(manifest),
		"install-xp-package.ps1":    script,
		"README.txt":                []byte("readme"),
	})
	return path
}

// The XP package is installed by its own install-xp-package.ps1, run against
// a fake ESP folder (no disk is touched).
func TestInstallXPComponentRunsPackageScriptOnFakeESP(t *testing.T) {
	base := []byte("micro-linux of this build")
	esp, data := fakeESP(t, base), t.TempDir()
	var log []string
	if err := installComponentAt(esp, data, components.XPPL, xpPackageZip(t, "pl", base), false, func(s string) { log = append(log, s) }); err != nil {
		t.Fatalf("%v\n%s", err, strings.Join(log, "\n"))
	}
	if got, _ := os.ReadFile(filepath.Join(esp, "EFI", "USOS-XP", "initramfs-xp")); string(got) != "xp initramfs pl" {
		t.Fatalf("initramfs-xp not installed: %q", got)
	}
	if status := components.Inspect(esp, data); !status.Present(components.XPPL) {
		t.Fatalf("status after install: %+v", status)
	}

	// A package for another build is refused by the script (no -Force).
	other := fakeESP(t, []byte("another build"))
	err := installComponentAt(other, data, components.XPEN, xpPackageZip(t, "en", base), false, nil)
	if err == nil || !strings.Contains(err.Error(), "another build") {
		t.Fatalf("mismatched package: %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(other, "EFI", "USOS-XP")); !os.IsNotExist(statErr) {
		t.Fatal("mismatched package was written")
	}
}

func TestStoreXPComponentKeepsZipOnData(t *testing.T) {
	base := []byte("b")
	data := t.TempDir()
	zipPath := xpPackageZip(t, "en", base)
	if err := installComponentAt(t.TempDir(), data, components.XPEN, zipPath, true, nil); err != nil {
		t.Fatal(err)
	}
	matches, _ := filepath.Glob(filepath.Join(data, components.XPStoreDir, "*.zip"))
	if len(matches) != 1 {
		t.Fatalf("stored zips: %v", matches)
	}
}

// The WinPE zip lands in DATA\Programs\USOS\WinPE and is recorded by the
// same ensureWinpeDonor as install/update/repair.
func TestInstallWinpeComponentRecordsDonor(t *testing.T) {
	esp, data := t.TempDir(), t.TempDir()
	unprotect(t, data)
	zipPath := filepath.Join(t.TempDir(), "USOS-9.9.9-WinPE-PE10-donor.zip")
	writeZip(t, zipPath, map[string][]byte{"Programs/USOS/WinPE/PE10_x64_19041_USOS.iso": []byte("donor"), "README.txt": []byte("r")})
	if err := installComponentAt(esp, data, components.WinPE, zipPath, false, nil); err != nil {
		t.Fatal(err)
	}
	record, ok := readWinpeRecord(filepath.Join(esp, filepath.FromSlash(winpeDonorRecord)))
	if !ok || record.name != "PE10_x64_19041_USOS.iso" || record.sha256 != hexSum([]byte("donor")) {
		t.Fatalf("record %+v %v", record, ok)
	}
	if detail, ok := verifyWinpeDonor(data, esp); !ok {
		t.Fatal(detail)
	}
	// Running it again (Repair offering it once more) keeps the donor.
	if err := installComponentAt(esp, data, components.WinPE, zipPath, false, nil); err != nil {
		t.Fatal(err)
	}
}
