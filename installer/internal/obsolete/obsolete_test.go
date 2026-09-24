package obsolete

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

func sum(data []byte) string {
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}

func write(t *testing.T, root, rel string, data []byte) {
	t.Helper()
	path := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

func exists(root, rel string) bool {
	_, err := os.Stat(filepath.Join(root, filepath.FromSlash(rel)))
	return err == nil
}

func TestCSMWrapTrialConfigHashMatchesTheTrialBuilder(t *testing.T) {
	// tools/build_csmwrap_trial.py writes exactly these bytes.
	data := []byte("; USOS physical hardware trial\r\nverbose = true\r\n")
	for _, file := range ESPFiles {
		if file.Path == "EFI/BOOT/csmwrap.ini" && file.SHA256 != sum(data) {
			t.Fatalf("csmwrap.ini hash %s, want %s", file.SHA256, sum(data))
		}
	}
}

func TestRemovesOnlyExactKnownFiles(t *testing.T) {
	root := t.TempDir()
	known := []byte("old usos")
	other := []byte("someone else's file")
	files := []File{
		{Path: "EFI/BOOT/USOS-original.efi", SHA256: sum(known), Reason: "test"},
		{Path: "EFI/BOOT/csmwrap.ini", SHA256: sum([]byte("ini")), Reason: "test"},
		{Path: "EFI/BOOT/gone.efi", SHA256: sum([]byte("x")), Reason: "test"},
	}
	write(t, root, "EFI/BOOT/USOS-original.efi", known)
	write(t, root, "EFI/BOOT/csmwrap.ini", other) // known path, unknown content
	write(t, root, "EFI/BOOT/BOOTX64.EFI", []byte("shim"))
	write(t, root, "EFI/CSMWrap/csmwrap.ini", []byte("ini")) // same content, other path
	results, err := RemoveKnown(root, files)
	if err != nil {
		t.Fatal(err)
	}
	want := []Action{ActionRemoved, ActionKept, ActionAbsent}
	for i, result := range results {
		if result.Action != want[i] {
			t.Fatalf("%s: %s, want %s", result.Path, result.Action, want[i])
		}
	}
	if exists(root, "EFI/BOOT/USOS-original.efi") {
		t.Fatal("known obsolete file still present")
	}
	for _, keep := range []string{"EFI/BOOT/csmwrap.ini", "EFI/BOOT/BOOTX64.EFI", "EFI/CSMWrap/csmwrap.ini"} {
		if !exists(root, keep) {
			t.Fatalf("%s was removed", keep)
		}
	}
	if results[1].SHA256 != sum(other) {
		t.Fatalf("kept file logged with hash %s", results[1].SHA256)
	}
}

func TestDirectoryAtKnownPathIsKept(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "EFI", "BOOT", "csmwrap.ini"), 0o755); err != nil {
		t.Fatal(err)
	}
	results, err := RemoveKnown(root, ESPFiles)
	if err != nil {
		t.Fatal(err)
	}
	if results[1].Action != ActionKept || !exists(root, "EFI/BOOT/csmwrap.ini") {
		t.Fatalf("directory not kept: %+v", results[1])
	}
}

func TestRejectsUnsafeEntries(t *testing.T) {
	for _, path := range []string{"", "../x", "/EFI/x"} {
		if _, err := RemoveKnown(t.TempDir(), []File{{Path: path, SHA256: sum(nil)}}); err == nil {
			t.Fatalf("entry %q accepted", path)
		}
	}
	if _, err := RemoveKnown("", ESPFiles); err == nil {
		t.Fatal("empty root accepted")
	}
}
