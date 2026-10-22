//go:build windows

package winhost

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io/fs"
	"os"
	"path/filepath"
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/components"
)

// snapshot records every file under root with its size and SHA-256, so a test
// can prove that a run wrote nothing (the default, report-only mode).
func snapshot(t *testing.T, root string) map[string]string {
	t.Helper()
	files := map[string]string{}
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		if entry.IsDir() {
			files[rel] = "dir"
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		sum := sha256.Sum256(data)
		files[rel] = hex.EncodeToString(sum[:])
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return files
}

func sameTree(t *testing.T, before, after map[string]string) {
	t.Helper()
	if len(before) != len(after) {
		t.Fatalf("tree changed: %d entries before, %d after\nbefore=%v\nafter=%v", len(before), len(after), before, after)
	}
	for name, sum := range before {
		if after[name] != sum {
			t.Fatalf("%s changed: %q -> %q", name, sum, after[name])
		}
	}
}

// componentBundle writes the component zips into an installer-shaped overlay
// (the all-in-one installer) and returns the opened bundle plus the release
// whose compiled hash list pins them.
func componentBundle(t *testing.T, zips ...string) (*components.Bundle, components.Release) {
	t.Helper()
	exe := filepath.Join(t.TempDir(), "installer.exe")
	if err := os.WriteFile(exe, []byte("MZ"), 0o644); err != nil {
		t.Fatal(err)
	}
	allInOne := filepath.Join(t.TempDir(), "USOS-Installer-9.9.9.exe")
	if err := components.WriteBundle(allInOne, exe, zips); err != nil {
		t.Fatal(err)
	}
	bundle, err := components.OpenBundle(allInOne)
	if err != nil {
		t.Fatal(err)
	}
	pins := ""
	for _, z := range zips {
		sum, err := components.HashFile(z)
		if err != nil {
			t.Fatal(err)
		}
		pins += filepath.Base(z) + "=" + sum + ";"
	}
	release := components.Release{Version: "9.9.9", Tag: "v9.9.9-rc2", BaseURL: "http://127.0.0.1:1", Pinned: components.ParsePinned(pins)}
	return bundle, release
}

func winpePackageZip(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), components.AssetName(components.WinPE, "9.9.9"))
	writeZip(t, path, map[string][]byte{
		"Programs/USOS/WinPE/PE10_x64_19041_USOS.iso": []byte("donor"),
		"README.txt": []byte("r"),
	})
	return path
}

// The report is read-only and names every optional component as missing,
// current or outdated (present but built for another USOS build / damaged).
func TestReportComponentsStatesOnFakeStick(t *testing.T) {
	base := []byte("micro-linux of this build")
	esp, data := fakeESP(t, base), t.TempDir()
	unprotect(t, data)

	report := ReportComponents(esp, data)
	for _, name := range []string{"xp", "winpe", "winpe-x86"} {
		item, ok := report.Item(name)
		if !ok || item.State != ComponentMissing {
			t.Fatalf("%s on an empty stick: %+v %v", name, item, ok)
		}
	}

	// XP installed by the installer's Components step -> current.
	xp, release := componentBundle(t, xpPackageZip(t, "pl", base))
	results := InstallComponents(context.Background(), esp, data, []components.ID{components.XPPL},
		ComponentInstallOptions{Bundle: xp, Release: release})
	if results[components.XPPL] != nil {
		t.Fatalf("install XP: %v", results[components.XPPL])
	}
	report = ReportComponents(esp, data)
	item, _ := report.Item("xp")
	if item.State != ComponentCurrent || item.ID != components.XPPL {
		t.Fatalf("installed XP: %+v", item)
	}

	// A damaged payload file makes it outdated (manifest SHA-256 check).
	initramfs := filepath.Join(esp, "EFI", "USOS-XP", "initramfs-xp")
	if err := os.WriteFile(initramfs, []byte("damaged"), 0o644); err != nil {
		t.Fatal(err)
	}
	item, _ = ReportComponents(esp, data).Item("xp")
	if item.State != ComponentOutdated {
		t.Fatalf("damaged XP payload: %+v", item)
	}

	// A WinPE donor without its winpe-donor.ini record is outdated too.
	writeZip(t, filepath.Join(t.TempDir(), "donor.zip"), map[string][]byte{
		"Programs/USOS/WinPE/PE10_x64_19041_USOS.iso": []byte("donor"),
	})
	donor := filepath.Join(data, "Programs", "USOS", "WinPE", "PE10_x64_19041_USOS.iso")
	os.MkdirAll(filepath.Dir(donor), 0o755)
	if err := os.WriteFile(donor, []byte("donor"), 0o644); err != nil {
		t.Fatal(err)
	}
	item, _ = ReportComponents(esp, data).Item("winpe")
	if item.State != ComponentOutdated {
		t.Fatalf("unrecorded donor: %+v", item)
	}

	// ensureWinpeDonor (the install/update/repair code) records it -> current.
	if _, err := ensureWinpeDonor(data, esp); err != nil {
		t.Fatal(err)
	}
	item, _ = ReportComponents(esp, data).Item("winpe")
	if item.State != ComponentCurrent {
		t.Fatalf("recorded donor: %+v", item)
	}
}

// -components xp installs only the XP package: the WinPE zip is in the bundle
// but was not selected, so DATA stays untouched.
func TestInstallComponentsXPOnly(t *testing.T) {
	base := []byte("micro-linux of this build")
	esp, data := fakeESP(t, base), t.TempDir()
	unprotect(t, data)
	bundle, release := componentBundle(t, xpPackageZip(t, "pl", base), winpePackageZip(t))

	results := InstallComponents(context.Background(), esp, data, []components.ID{components.XPPL},
		ComponentInstallOptions{Bundle: bundle, Release: release})
	if results[components.XPPL] != nil {
		t.Fatalf("install XP: %v", results[components.XPPL])
	}
	for _, name := range []string{"initramfs-xp", "vmlinuz.efi", "manifest.json"} {
		if _, err := os.Stat(filepath.Join(esp, "EFI", "USOS-XP", name)); err != nil {
			t.Fatalf("%s not installed: %v", name, err)
		}
	}
	if _, err := os.Stat(filepath.Join(data, "Programs", "USOS", "WinPE")); !os.IsNotExist(err) {
		t.Fatalf("WinPE donor installed although only XP was selected (err=%v)", err)
	}
	if item, _ := ReportComponents(esp, data).Item("winpe"); item.State != ComponentMissing {
		t.Fatalf("WinPE report after XP-only install: %+v", item)
	}
}

// Without -components the install path must not write anything: the default
// run of usos-physical-update is the read-only report.
func TestInstallComponentsDefaultWritesNothing(t *testing.T) {
	base := []byte("micro-linux of this build")
	esp, data := fakeESP(t, base), t.TempDir()
	unprotect(t, data)
	bundle, release := componentBundle(t, xpPackageZip(t, "pl", base), winpePackageZip(t))

	beforeESP, beforeDATA := snapshot(t, esp), snapshot(t, data)
	results := InstallComponents(context.Background(), esp, data, nil,
		ComponentInstallOptions{Bundle: bundle, Release: release})
	for id, err := range results {
		t.Fatalf("no selection returned %s: %v", id, err)
	}
	sameTree(t, beforeESP, snapshot(t, esp))
	sameTree(t, beforeDATA, snapshot(t, data))
}
