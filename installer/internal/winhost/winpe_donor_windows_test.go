//go:build windows

package winhost

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

func attributesOf(t *testing.T, path string) uint32 {
	t.Helper()
	name, _ := windows.UTF16PtrFromString(path)
	value, err := windows.GetFileAttributes(name)
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func writeDonor(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func unprotect(t *testing.T, root string) {
	t.Helper()
	// t.TempDir cleanup cannot delete read-only files.
	t.Cleanup(func() {
		filepath.Walk(root, func(path string, _ os.FileInfo, _ error) error { clearProtection(path); return nil })
	})
}

func TestWinpeDonorMovesFromLegacyFolderRecordsAndProtects(t *testing.T) {
	data, esp := t.TempDir(), t.TempDir()
	unprotect(t, data)
	legacy := filepath.Join(data, legacyWinpeDonorDir)
	writeDonor(t, filepath.Join(legacy, "PE10_x64_19041_USOS.iso"), "donor bytes")
	// A real installer ISO in the same folder stays where it is.
	writeDonor(t, filepath.Join(legacy, "pl-pl_windows_10_22h2_x86.iso"), "install bytes")

	state, err := ensureWinpeDonor(data, esp)
	if err != nil {
		t.Fatal(err)
	}
	moved := filepath.Join(data, winpeDonorDir, "PE10_x64_19041_USOS.iso")
	if got, err := os.ReadFile(moved); err != nil || string(got) != "donor bytes" {
		t.Fatalf("donor not moved intact: %q %v", got, err)
	}
	if _, err := os.Stat(filepath.Join(legacy, "PE10_x64_19041_USOS.iso")); !os.IsNotExist(err) {
		t.Fatalf("legacy donor still present: %v", err)
	}
	if _, err := os.Stat(filepath.Join(legacy, "pl-pl_windows_10_22h2_x86.iso")); err != nil {
		t.Fatalf("installer ISO was touched: %v", err)
	}
	if state.MovedFrom == "" || state.Name != "PE10_x64_19041_USOS.iso" || len(state.SHA256) != 64 {
		t.Fatalf("state=%+v", state)
	}
	record, ok := readWinpeRecord(filepath.Join(esp, filepath.FromSlash(winpeDonorRecord)))
	if !ok || record.name != state.Name || record.size != int64(len("donor bytes")) || record.sha256 != state.SHA256 {
		t.Fatalf("record=%+v ok=%v", record, ok)
	}
	want := uint32(windows.FILE_ATTRIBUTE_HIDDEN | windows.FILE_ATTRIBUTE_SYSTEM | windows.FILE_ATTRIBUTE_READONLY)
	if attributesOf(t, moved)&want != want {
		t.Fatalf("donor attributes %#x", attributesOf(t, moved))
	}
	dir := uint32(windows.FILE_ATTRIBUTE_HIDDEN | windows.FILE_ATTRIBUTE_SYSTEM)
	if attributesOf(t, filepath.Join(data, winpeDonorDir))&dir != dir {
		t.Fatalf("folder attributes %#x", attributesOf(t, filepath.Join(data, winpeDonorDir)))
	}
	if text, ok := verifyWinpeDonor(data, esp); !ok {
		t.Fatalf("verify: %s", text)
	}

	// A second update is idempotent: nothing moves, the record stays.
	again, err := ensureWinpeDonor(data, esp)
	if err != nil || again.MovedFrom != "" || again.Corrupt || again.SHA256 != state.SHA256 {
		t.Fatalf("second run: %+v %v", again, err)
	}
}

func TestWinpeDonorCorruptionIsReportedNotRecorded(t *testing.T) {
	data, esp := t.TempDir(), t.TempDir()
	unprotect(t, data)
	path := filepath.Join(data, winpeDonorDir, "PE10_x64_19041_USOS.iso")
	writeDonor(t, path, "good")
	if _, err := ensureWinpeDonor(data, esp); err != nil {
		t.Fatal(err)
	}
	clearProtection(path)
	writeDonor(t, path, "bad!")
	state, err := ensureWinpeDonor(data, esp)
	if err != nil || !state.Corrupt {
		t.Fatalf("corrupt donor not detected: %+v %v", state, err)
	}
	if text, ok := verifyWinpeDonor(data, esp); ok || !strings.Contains(text, "różni się") {
		t.Fatalf("verify accepted a changed donor: %s", text)
	}
	clearProtection(path)
	os.Remove(path)
	if text, ok := verifyWinpeDonor(data, esp); ok || !strings.Contains(text, "brak") {
		t.Fatalf("verify accepted a missing recorded donor: %s", text)
	}
}

func TestWinpeDonorAbsentIsFine(t *testing.T) {
	data, esp := t.TempDir(), t.TempDir()
	unprotect(t, data)
	if state, err := ensureWinpeDonor(data, esp); err != nil || state.Name != "" {
		t.Fatalf("%+v %v", state, err)
	}
	if text, ok := verifyWinpeDonor(data, esp); !ok {
		t.Fatalf("no donor should verify: %s", text)
	}
}

func TestMirrorUnattendedCopiesSifAnyCase(t *testing.T) {
	source, destination := t.TempDir(), t.TempDir()
	for _, name := range []string{"winnt.SIF", "Answer.Xml", "notes.txt"} {
		if err := os.WriteFile(filepath.Join(source, name), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := mirrorUnattended(source, destination); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"winnt.SIF", "Answer.Xml"} {
		if _, err := os.Stat(filepath.Join(destination, name)); err != nil {
			t.Fatalf("%s not mirrored: %v", name, err)
		}
	}
	if _, err := os.Stat(filepath.Join(destination, "notes.txt")); !os.IsNotExist(err) {
		t.Fatal("notes.txt mirrored")
	}
	if err := compareCatalogXmlFiles(source, destination); err != nil {
		t.Fatal(err)
	}
}
