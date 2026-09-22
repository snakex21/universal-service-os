package winhost

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/install"
)

func TestCatalogProfilesCoverFixedOperatingSystems(t *testing.T) {
	profiles := catalogProfiles()
	want := map[string]string{
		"windows-11":       filepath.Join("Systems", "Windows"),
		"ubuntu":           filepath.Join("Systems", "Linux"),
		"windows-whistler": filepath.Join("Systems", "Betas"),
		"ms-dos":           filepath.Join("Systems", "DOS"),
	}
	for id, root := range want {
		found := false
		for _, profile := range profiles {
			if profile.profile.id == id && profile.root == root {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("catalog profiles do not contain id=%q root=%q", id, root)
		}
	}
}

func TestMirrorEspExecutableImagesSkipsCatalogMarkersAndCopiesEFIExecutables(t *testing.T) {
	source := filepath.Join(t.TempDir(), "source")
	destination := filepath.Join(t.TempDir(), "destination")
	if err := os.MkdirAll(source, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(destination, 0o755); err != nil {
		t.Fatal(err)
	}
	files := map[string][]byte{
		"Windows.iso": []byte("large image placeholder for test"),
		"Tool.EFI":    []byte("efi test"),
		"notes.txt":   []byte("ignore"),
	}
	for name, data := range files {
		if err := os.WriteFile(filepath.Join(source, name), data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := mirrorEspExecutableImages(source, destination); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(destination, "Windows.iso")); !os.IsNotExist(err) {
		t.Fatalf("ISO marker must not exist on ESP: %v", err)
	}
	efiData, err := os.ReadFile(filepath.Join(destination, "Tool.EFI"))
	if err != nil {
		t.Fatal(err)
	}
	if string(efiData) != "efi test" {
		t.Fatalf("EFI mirror=%q, want source bytes", string(efiData))
	}
	if _, err := os.Stat(filepath.Join(destination, "notes.txt")); !os.IsNotExist(err) {
		t.Fatalf("unsupported notes.txt was mirrored: %v", err)
	}
}

func TestMirrorUnattendedCopiesXmlContent(t *testing.T) {
	source := filepath.Join(t.TempDir(), "source")
	destination := filepath.Join(t.TempDir(), "destination")
	if err := os.MkdirAll(source, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(destination, 0o755); err != nil {
		t.Fatal(err)
	}
	want := []byte("<unattend>test</unattend>")
	if err := os.WriteFile(filepath.Join(source, "answer.XML"), want, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := mirrorUnattended(source, destination); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(destination, "answer.XML"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(want) {
		t.Fatalf("mirrored unattended=%q, want %q", string(got), string(want))
	}
}

func TestKnownProfileCatalogKeepsImagesOnDataAndMirrorsUnattendedAndIcon(t *testing.T) {
	dataRoot := t.TempDir()
	espRoot := t.TempDir()
	profile := catalogProfile{root: filepath.Join("Systems", "Windows"), profile: dataProfile{id: "windows-11", name: "Windows 11", unattended: true}}
	profileRoot := filepath.Join(dataRoot, profile.root, profile.profile.name)
	if err := os.MkdirAll(filepath.Join(profileRoot, "Images"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(profileRoot, "Unattended"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(profileRoot, "Images", "Win11.iso"), []byte("iso bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(profileRoot, "Unattended", "answer.xml"), []byte("<answer/>"), 0o644); err != nil {
		t.Fatal(err)
	}
	icon := append(append([]byte(nil), pngSignature...), []byte{1, 2, 3, 4}...)
	if err := os.WriteFile(filepath.Join(profileRoot, "icon.png"), icon, 0o644); err != nil {
		t.Fatal(err)
	}
	media := install.MediaLayout{DATA: install.PartitionRef{VolumePath: dataRoot}, ESP: install.PartitionRef{VolumePath: espRoot}}
	if err := syncCatalogProfile(media, profile); err != nil {
		t.Fatal(err)
	}
	if err := verifyCatalogProfileMatches(media, profile); err != nil {
		t.Fatalf("mirrored known profile did not verify: %v", err)
	}
	if _, err := os.Stat(filepath.Join(espRoot, profile.root, profile.profile.name, "Images", "Win11.iso")); !os.IsNotExist(err) {
		t.Fatalf("known profile ISO marker must not exist on ESP: %v", err)
	}
}

func TestKnownProfileCatalogRemovesLegacyImageMarkers(t *testing.T) {
	dataRoot := t.TempDir()
	espRoot := t.TempDir()
	profile := catalogProfile{root: filepath.Join("Systems", "Windows"), profile: dataProfile{id: "windows-xp", name: "Windows XP", unattended: true}}
	dataImages := filepath.Join(dataRoot, profile.root, profile.profile.name, "Images")
	if err := os.MkdirAll(dataImages, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dataImages, "XP.iso"), []byte("real image stays on DATA"), 0o644); err != nil {
		t.Fatal(err)
	}
	legacyMarker := filepath.Join(espRoot, profile.root, profile.profile.name, "Images", "XP.iso")
	if err := os.MkdirAll(filepath.Dir(legacyMarker), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(legacyMarker, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	media := install.MediaLayout{DATA: install.PartitionRef{VolumePath: dataRoot}, ESP: install.PartitionRef{VolumePath: espRoot}}
	if err := syncCatalogProfile(media, profile); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(legacyMarker); !os.IsNotExist(err) {
		t.Fatalf("legacy zero-byte image marker survived ESP projection rebuild: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dataImages, "XP.iso")); err != nil {
		t.Fatalf("DATA image was modified while removing legacy ESP marker: %v", err)
	}
}

func TestDynamicUtilitiesCatalogMirrorsFolderImageAndIcon(t *testing.T) {
	dataRoot := t.TempDir()
	espRoot := t.TempDir()
	utility := filepath.Join(dataRoot, "Utilities", "MemTest86")
	if err := os.MkdirAll(filepath.Join(utility, "Images"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(utility, "Images", "memtest86.efi"), []byte("efi payload"), 0o644); err != nil {
		t.Fatal(err)
	}
	icon := append(append([]byte(nil), pngSignature...), []byte{1, 2, 3, 4}...)
	if err := os.WriteFile(filepath.Join(utility, "icon.png"), icon, 0o644); err != nil {
		t.Fatal(err)
	}
	media := install.MediaLayout{
		DATA: install.PartitionRef{VolumePath: dataRoot},
		ESP:  install.PartitionRef{VolumePath: espRoot},
	}
	if err := syncDynamicUtilitiesCatalog(media); err != nil {
		t.Fatal(err)
	}
	catalogImage := filepath.Join(espRoot, "Utilities", "MemTest86", "Images", "memtest86.efi")
	info, err := os.Stat(catalogImage)
	if err != nil {
		t.Fatal(err)
	}
	if info.Size() != int64(len("efi payload")) {
		t.Fatalf("utility EFI mirror size=%d, want %d", info.Size(), len("efi payload"))
	}
	mirroredEFI, err := os.ReadFile(catalogImage)
	if err != nil {
		t.Fatal(err)
	}
	if string(mirroredEFI) != "efi payload" {
		t.Fatalf("utility EFI mirror=%q, want source payload", string(mirroredEFI))
	}
	if err := verifyDynamicUtilitiesCatalogMatches(media); err != nil {
		t.Fatalf("mirrored utility catalog did not verify: %v", err)
	}
}

func TestDynamicUtilitiesCatalogRemovesStaleMetadata(t *testing.T) {
	dataRoot := t.TempDir()
	espRoot := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dataRoot, "Utilities"), 0o755); err != nil {
		t.Fatal(err)
	}
	stale := filepath.Join(espRoot, "Utilities", "Old Tool", "Images")
	if err := os.MkdirAll(stale, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stale, "old.efi"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	media := install.MediaLayout{
		DATA: install.PartitionRef{VolumePath: dataRoot},
		ESP:  install.PartitionRef{VolumePath: espRoot},
	}
	if err := syncDynamicUtilitiesCatalog(media); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(espRoot, "Utilities", "Old Tool")); !os.IsNotExist(err) {
		t.Fatalf("stale utility metadata was not removed: %v", err)
	}
}

func TestRestoreLegacyImageMarkersRecreatesZeroLengthCatalogWithoutTouchingData(t *testing.T) {
	dataRoot := t.TempDir()
	espRoot := t.TempDir()
	profile := catalogProfile{root: filepath.Join("Systems", "Windows"), profile: dataProfile{id: "windows-xp", name: "Windows XP", unattended: true}}
	images := filepath.Join(dataRoot, profile.root, profile.profile.name, "Images")
	if err := os.MkdirAll(images, 0o755); err != nil { t.Fatal(err) }
	isoPath := filepath.Join(images, "XP.iso")
	isoBytes := []byte("real iso bytes must stay on DATA")
	if err := os.WriteFile(isoPath, isoBytes, 0o644); err != nil { t.Fatal(err) }
	media := install.MediaLayout{DATA: install.PartitionRef{VolumePath: dataRoot}, ESP: install.PartitionRef{VolumePath: espRoot}}
	if err := RestoreLegacyImageMarkers(media); err != nil { t.Fatal(err) }
	marker := filepath.Join(espRoot, profile.root, profile.profile.name, "Images", "XP.iso")
	info, err := os.Stat(marker)
	if err != nil { t.Fatal(err) }
	if info.Size() != 0 { t.Fatalf("rollback marker size=%d, want 0", info.Size()) }
	got, err := os.ReadFile(isoPath)
	if err != nil { t.Fatal(err) }
	if string(got) != string(isoBytes) { t.Fatalf("DATA ISO changed: %q", string(got)) }
}

func TestVerifyPNGSignature(t *testing.T) {
	path := filepath.Join(t.TempDir(), "icon.png")
	data := append(append([]byte(nil), pngSignature...), []byte{0, 1, 2, 3}...)
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := verifyPNGSignature(path); err != nil {
		t.Fatalf("valid PNG signature rejected: %v", err)
	}
}

func TestVerifyPNGSignatureRejectsRenamedNonPNG(t *testing.T) {
	path := filepath.Join(t.TempDir(), "icon.png")
	if err := os.WriteFile(path, []byte("not a png"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := verifyPNGSignature(path); err == nil {
		t.Fatal("renamed non-PNG file was accepted")
	}
}
