package main

import (
	"path/filepath"
	"strings"
	"testing"
)

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

func TestPayloadNeverCarriesSigningKey(t *testing.T) {
	for _, path := range []string{
		`EFI/USOS/usos-secure-boot.key`, `data/signing/usos-secure-boot.cer`,
		`EFI/USOS/signing/x.cer`, `UI/key.pfx`, `EFI/x.p12`, `usos-secure-boot.key`,
	} {
		if shouldBundleMediaFile(path) {
			t.Fatalf("private key material accepted into payload: %s", path)
		}
	}
	for _, item := range append(append([]payloadFile{}, payloadFiles...), payloadDirectories...) {
		src := strings.ToLower(filepath.ToSlash(item.Source))
		if strings.HasPrefix(src, "installer/") || strings.Contains(src, "data/") || strings.Contains(src, "signing") || isPrivateKeyMaterial(item.Target) {
			t.Fatalf("payload source may carry installer state or the signing key: %+v", item)
		}
	}
}
