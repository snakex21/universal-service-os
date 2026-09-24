package main

import "testing"

func TestShouldBundleMediaFileKeepsOnlyStaticESPPayload(t *testing.T) {
	accepted := []string{
		`EFI/BOOT/BOOTX64.EFI`,
		`EFI/USOS/ntfs_x64.efi`,
		`UI/index.html`,
		`UI/Icons/Systems/windows-11.png`,
		`USOS-KEY.cer`,
	}
	for _, path := range accepted {
		if !shouldBundleMediaFile(path) {
			t.Fatalf("static ESP payload was excluded: %s", path)
		}
	}
}

func TestShouldBundleMediaFileExcludesDataAndGeneratedCatalog(t *testing.T) {
	rejected := []string{
		`Systems/Windows/Windows 11/Images/Win11.iso`,
		`Systems/Windows/Windows 11/Unattended/unattend.xml`,
		`Systems/README.txt`,
		`Utilities/MemTest86/icon.png`,
		`Programs/README.txt`,
		`OTHER-KEY.cer`,
	}
	for _, path := range rejected {
		if shouldBundleMediaFile(path) {
			t.Fatalf("DATA/catalog file must not be embedded as static ESP payload: %s", path)
		}
	}
}
