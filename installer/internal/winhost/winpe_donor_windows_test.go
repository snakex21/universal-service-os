//go:build windows

package winhost

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/components"
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

// Two donors, one per architecture, in Programs\USOS\WinPE: both recorded in
// the one winpe-donor.ini (x86 under x86_ keys an older reader ignores), an
// x64-only record of an older install is kept, a damaged x86 donor blocks
// only the x86 entry.
func TestWinpeDonorsOnePerArchitecture(t *testing.T) {
	data, esp := t.TempDir(), t.TempDir()
	unprotect(t, data)
	recordPath := filepath.Join(esp, filepath.FromSlash(winpeDonorRecord))
	x64 := filepath.Join(data, winpeDonorDir, "PE10_x64_19041_USOS.iso")
	writeDonor(t, x64, "x64 donor")
	// An install from before the x86 donor: x64 record in the old format.
	writeDonor(t, recordPath, "; old\r\nname=PE10_x64_19041_USOS.iso\r\nsize=9\r\nsha256="+hexSum([]byte("x64 donor"))+"\r\n")
	// The x86 donor is still in the legacy folder next to a user's own
	// Windows 10 x86 install ISO (which stays there: it is the fallback).
	legacy := filepath.Join(data, legacyWinpeDonorDir)
	writeDonor(t, filepath.Join(legacy, "PE10_x86_19041_USOS.iso"), "x86 donor")
	writeDonor(t, filepath.Join(legacy, "pl-pl_windows_10_22h2_x86.iso"), "install bytes")
	state, err := ensureWinpeDonor(data, esp)
	if err != nil {
		t.Fatal(err)
	}
	if state.Name != "PE10_x64_19041_USOS.iso" || state.MovedFrom != "" || state.X86.Name != "PE10_x86_19041_USOS.iso" || state.X86.MovedFrom == "" || state.Ambiguous || state.X86.Ambiguous {
		t.Fatalf("state %+v", state)
	}
	if _, err := os.Stat(filepath.Join(legacy, "pl-pl_windows_10_22h2_x86.iso")); err != nil {
		t.Fatalf("user ISO touched: %v", err)
	}
	records := readWinpeRecords(recordPath)
	if records[archX64].sha256 != hexSum([]byte("x64 donor")) || records[archX86].name != "PE10_x86_19041_USOS.iso" || records[archX86].sha256 != hexSum([]byte("x86 donor")) || records[archX86].size != 9 {
		t.Fatalf("records %+v", records)
	}
	if old, ok := readWinpeRecord(recordPath); !ok || old.name != "PE10_x64_19041_USOS.iso" {
		t.Fatalf("x64 record for older readers: %+v %v", old, ok)
	}
	text, _ := os.ReadFile(recordPath)
	if !strings.Contains(string(text), "\r\nname=PE10_x64_19041_USOS.iso\r\n") || !strings.Contains(string(text), "\r\nx86_sha256="+hexSum([]byte("x86 donor"))+"\r\n") {
		t.Fatalf("record text %q", text)
	}
	if detail, ok := verifyWinpeDonor(data, esp); !ok {
		t.Fatal(detail)
	}
	if line := state.logLine(); !strings.Contains(line, "PE10_x64_19041_USOS.iso") || !strings.Contains(line, "x86: PE10_x86_19041_USOS.iso") {
		t.Fatal(line)
	}
	// A user's x86 ISO dropped next to the shipped donor: the shipped one stays the recorded one.
	writeDonor(t, filepath.Join(data, winpeDonorDir, "my_win10_x86.iso"), "user x86")
	if again, err := ensureWinpeDonor(data, esp); err != nil || again.X86.Name != "PE10_x86_19041_USOS.iso" || again.X86.Ambiguous {
		t.Fatalf("extra x86 ISO: %+v %v", again, err)
	}
	if detail, ok := verifyWinpeDonor(data, esp); !ok {
		t.Fatal(detail)
	}
	os.Remove(filepath.Join(data, winpeDonorDir, "my_win10_x86.iso"))
	// Damaged x86 donor: reported, record kept, the x64 donor is unaffected.
	x86 := filepath.Join(data, winpeDonorDir, "PE10_x86_19041_USOS.iso")
	clearProtection(x86)
	writeDonor(t, x86, "x86 DAMAGE")
	damaged, err := ensureWinpeDonor(data, esp)
	if err != nil || !damaged.X86.Corrupt || damaged.Corrupt {
		t.Fatalf("damaged x86: %+v %v", damaged, err)
	}
	if readWinpeRecords(recordPath)[archX86].sha256 != hexSum([]byte("x86 donor")) {
		t.Fatal("record of the damaged donor overwritten")
	}
	if detail, ok := verifyWinpeDonor(data, esp); ok || !strings.Contains(detail, "x86: PE10_x86_19041_USOS.iso SHA-256") || !strings.Contains(detail, "różni się") {
		t.Fatalf("verify: %s", detail)
	}
	if err := installComponentAt(esp, data, components.WinPEX86, writeX86Zip(t), false, nil); err == nil {
		t.Fatal("component install accepted a damaged x86 donor")
	}
}

// Only the x86 donor (no x64): recorded alone; the x64 entry stays absent.
func TestWinpeDonorOnlyX86(t *testing.T) {
	data, esp := t.TempDir(), t.TempDir()
	unprotect(t, data)
	if err := installComponentAt(esp, data, components.WinPEX86, writeX86Zip(t), false, nil); err != nil {
		t.Fatal(err)
	}
	records := readWinpeRecords(filepath.Join(esp, filepath.FromSlash(winpeDonorRecord)))
	if _, ok := records[archX64]; ok || records[archX86].name != "PE10_x86_19041_USOS.iso" {
		t.Fatalf("records %+v", records)
	}
	if detail, ok := verifyWinpeDonor(data, esp); !ok {
		t.Fatal(detail)
	}
	if err := installComponentAt(esp, data, components.WinPE, writeX86Zip(t), false, nil); err == nil {
		t.Fatal("the x86 zip was accepted as the x64 donor")
	}
}

func writeX86Zip(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "USOS-9.9.9-WinPE-PE10-x86-donor.zip")
	writeZip(t, path, map[string][]byte{"Programs/USOS/WinPE/PE10_x86_19041_USOS.iso": []byte("x86 zip donor"), "README.txt": []byte("r")})
	return path
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
