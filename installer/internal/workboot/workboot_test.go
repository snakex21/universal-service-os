package workboot

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

func write(t *testing.T, root, rel, data string) {
	t.Helper()
	path := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
}

func names(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		t.Fatal(err)
	}
	var out []string
	for _, entry := range entries {
		out = append(out, strings.ToLower(entry.Name()))
	}
	sort.Strings(out)
	return out
}

func read(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func assertClean(t *testing.T, root string) {
	t.Helper()
	left, err := RemovableEntries(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(left) != 0 {
		t.Fatalf("removable entries left: %v", left)
	}
}

func TestMigrateRenamesWindows7Chain(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"bootx64.efi", "win7.efi", "win7.original.efi", "UefiSeven.ini", "uefiseven-LICENSE.txt", "usos-boot.log"} {
		write(t, root, "efi/boot/"+name, name)
	}
	write(t, root, "efi/microsoft/boot/bcd", "bcd")
	m, err := Migrate(root)
	if err != nil {
		t.Fatal(err)
	}
	if m.Action != ActionRename {
		t.Fatalf("action=%s", m.Action)
	}
	assertClean(t, root)
	if got := names(t, filepath.Join(root, "efi", "boot")); got != nil {
		t.Fatalf("EFI/BOOT still exists: %v", got)
	}
	if got := read(t, filepath.Join(root, "efi", Dir, "win7.original.efi")); got != "win7.original.efi" {
		t.Fatalf("win7.original.efi content %q", got)
	}
	if got := read(t, filepath.Join(root, "efi", "microsoft", "boot", "bcd")); got != "bcd" {
		t.Fatalf("BCD touched: %q", got)
	}
	again, err := Migrate(root)
	if err != nil || again.Action != ActionNone {
		t.Fatalf("second migration: %v %v", again, err)
	}
}

func TestMigrateSplitsLinuxLoader(t *testing.T) {
	root := t.TempDir()
	write(t, root, "EFI/BOOT/BOOTX64.EFI", "shim")
	write(t, root, "EFI/BOOT/grubx64.efi", "grub")
	write(t, root, "EFI/BOOT/grub.cfg", "cfg")
	write(t, root, "EFI/BOOT/fonts/unicode.pf2", "font")
	m, err := Migrate(root)
	if err != nil {
		t.Fatal(err)
	}
	if m.Action != ActionSplit {
		t.Fatalf("action=%s", m.Action)
	}
	assertClean(t, root)
	if got := strings.Join(names(t, filepath.Join(root, "EFI", "BOOT")), ","); got != "fonts,grub.cfg,grubx64.efi" {
		t.Fatalf("EFI/BOOT=%s", got)
	}
	if got := strings.Join(names(t, filepath.Join(root, "EFI", Dir)), ","); got != "bootx64.efi,fonts,grub.cfg,grubx64.efi" {
		t.Fatalf("EFI/USOS-WORK=%s", got)
	}
	if got := read(t, filepath.Join(root, "EFI", Dir, "BOOTX64.EFI")); got != "shim" {
		t.Fatalf("entry copy %q", got)
	}
}

func TestMigrateMergesKeepingPublishedFiles(t *testing.T) {
	root := t.TempDir()
	write(t, root, "EFI/USOS-WORK/BOOTX64.EFI", "published")
	write(t, root, "EFI/Boot/bootx64.efi", "stale")
	write(t, root, "EFI/Boot/bootia32.efi", "ia32")
	m, err := Migrate(root)
	if err != nil {
		t.Fatal(err)
	}
	if m.Action != ActionMerge {
		t.Fatalf("action=%s", m.Action)
	}
	assertClean(t, root)
	if got := read(t, filepath.Join(root, "EFI", Dir, "BOOTX64.EFI")); got != "published" {
		t.Fatalf("published entry replaced: %q", got)
	}
	if got := read(t, filepath.Join(root, "EFI", Dir, "bootia32.efi")); got != "ia32" {
		t.Fatalf("ia32 entry %q", got)
	}
}

func TestMigrateNoop(t *testing.T) {
	root := t.TempDir()
	if m, err := Migrate(root); err != nil || m.Action != ActionNone {
		t.Fatalf("empty root: %v %v", m, err)
	}
	write(t, root, "EFI/BOOT/grub.cfg", "cfg")
	if m, err := Migrate(root); err != nil || m.Action != ActionNone {
		t.Fatalf("no entry: %v %v", m, err)
	}
	if got := names(t, filepath.Join(root, "EFI")); strings.Join(got, ",") != "boot" {
		t.Fatalf("EFI changed: %v", got)
	}
}

func TestRemovableEntriesIsCaseInsensitive(t *testing.T) {
	root := t.TempDir()
	write(t, root, "efi/Boot/BootIA32.efi", "x")
	left, err := RemovableEntries(root)
	if err != nil || len(left) != 1 {
		t.Fatalf("entries=%v err=%v", left, err)
	}
}
