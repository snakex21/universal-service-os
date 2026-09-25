package winhost

import (
	"os"
	"path/filepath"
	"testing"
)

func writeTestFile(t *testing.T, path string, size int) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, make([]byte, size), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestObsoleteXPTrialFolderOnlyLaunchersIsRemoved(t *testing.T) {
	root := t.TempDir()
	images := filepath.Join(root, obsoleteXPTrialDirectory, "Images")
	writeTestFile(t, filepath.Join(images, "XP-SP2-UEFI-CSM-PAE.efi"), 57344)
	writeTestFile(t, filepath.Join(images, "XP-SP3-NiKKA-UEFI-CSM-PAE.efi"), 57344)
	writeTestFile(t, filepath.Join(root, "Systems", "Windows", "Windows XP", "Images", "xp.iso"), 10)
	removed, kept, err := removeObsoleteXPTrialFolder(root)
	if err != nil || !removed || kept {
		t.Fatalf("removed=%v kept=%v err=%v", removed, kept, err)
	}
	if _, err := os.Stat(filepath.Join(root, obsoleteXPTrialDirectory)); !os.IsNotExist(err) {
		t.Fatalf("trial folder still present: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "Systems", "Windows", "Windows XP", "Images", "xp.iso")); err != nil {
		t.Fatalf("normal XP folder touched: %v", err)
	}
}

func TestObsoleteXPTrialFolderWithUserFilesIsKept(t *testing.T) {
	for name, extra := range map[string]string{
		"user ISO":        filepath.Join("Images", "my.iso"),
		"driver folder":   filepath.Join("Drivers", "x86", "a.sys"),
		"large .efi":      filepath.Join("Images", "XP-SP3-UEFI-CSM-PAE.efi"),
		"file at the top": "notes.txt",
	} {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			dir := filepath.Join(root, obsoleteXPTrialDirectory)
			writeTestFile(t, filepath.Join(dir, "Images", "XP-SP2-UEFI-CSM-PAE.efi"), 57344)
			size := 10
			if name == "large .efi" {
				size = 2 << 20
			}
			writeTestFile(t, filepath.Join(dir, extra), size)
			removed, kept, err := removeObsoleteXPTrialFolder(root)
			if err != nil || removed || !kept {
				t.Fatalf("removed=%v kept=%v err=%v", removed, kept, err)
			}
			if _, err := os.Stat(filepath.Join(dir, extra)); err != nil {
				t.Fatalf("user file touched: %v", err)
			}
			if _, err := os.Stat(filepath.Join(dir, "Images", "XP-SP2-UEFI-CSM-PAE.efi")); err != nil {
				t.Fatalf("launcher removed although the folder is kept: %v", err)
			}
		})
	}
}

func TestObsoleteXPTrialFolderMissingIsFine(t *testing.T) {
	removed, kept, err := removeObsoleteXPTrialFolder(t.TempDir())
	if err != nil || removed || kept {
		t.Fatalf("removed=%v kept=%v err=%v", removed, kept, err)
	}
}

func TestInstallerNeverCreatesTheTrialFolder(t *testing.T) {
	for _, directory := range requiredDataDirectories {
		if filepath.Clean(directory) == obsoleteXPTrialDirectory || filepath.Dir(filepath.Clean(directory)) == obsoleteXPTrialDirectory {
			t.Fatalf("DATA layout creates the obsolete trial folder: %s", directory)
		}
	}
}
