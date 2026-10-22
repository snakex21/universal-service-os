package components

import (
	"archive/zip"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// netDriverZip builds the test asset in t.TempDir(): made-up driver files with
// the layout of USOS-<version>-NetDrivers-Intel.zip. Nothing from Intel is
// stored in the repository.
func netDriverZip(t *testing.T, entries map[string]string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "USOS-1.2.3-NetDrivers-Intel.zip")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	w := zip.NewWriter(f)
	for name, body := range entries {
		entry, err := w.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := entry.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}

func netDriverEntries() map[string]string {
	return map[string]string{
		"SOURCES.txt": "Intel Ethernet Adapter Complete Driver Pack\nURL: https://www.intel.com/content/www/us/en/download/15084/intel-ethernet-adapter-complete-driver-pack.html\npliki Intela na licencji Intela\n",
		"Systems/Windows/Windows 7/Drivers/x86/Net/Intel-I211/e1r62x86.inf": "[Version]\nSignature=\"$Windows NT$\"\n",
		"Systems/Windows/Windows 7/Drivers/x86/Net/Intel-I211/e1r62x86.cat": "fake cat x86",
		"Systems/Windows/Windows 7/Drivers/x64/Net/Intel-I211/e1r62x64.inf": "[Version]\nSignature=\"$Windows NT$\"\n",
		"Systems/Windows/Windows 7/Drivers/x64/Net/Intel-I211/e1r62x64.sys": "fake sys x64",
	}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	return string(data)
}

func noPartFiles(t *testing.T, root string) {
	t.Helper()
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() && strings.HasSuffix(info.Name(), ".part") {
			t.Errorf("leftover %s", path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestExtractWin7NetDriversInstallsIntoDataLayout(t *testing.T) {
	zipPath, data := netDriverZip(t, netDriverEntries()), t.TempDir()
	written, err := ExtractWin7NetDrivers(zipPath, data)
	if err != nil {
		t.Fatal(err)
	}
	if written != 6 { // 4 driver files + SOURCES.txt next to each arch's INF
		t.Fatalf("written = %d, want 6", written)
	}
	for arch, inf := range map[string]string{"x86": "e1r62x86.inf", "x64": "e1r62x64.inf"} {
		dir := filepath.Join(data, Win7NetIntelDataDir(arch))
		if got := readFile(t, filepath.Join(dir, inf)); !strings.Contains(got, "[Version]") {
			t.Fatalf("%s: %q", arch, got)
		}
		if _, err := os.Stat(filepath.Join(dir, "SOURCES.txt")); err != nil {
			t.Fatalf("%s: SOURCES.txt not next to the INF: %v", arch, err)
		}
	}
	if got := readFile(t, filepath.Join(data, Win7NetIntelDataDir("x64"), "e1r62x64.sys")); got != "fake sys x64" {
		t.Fatalf("driver file %q", got)
	}
	if !Win7NetIntelPresent(data) {
		t.Fatal("Win7NetIntelPresent = false after the install")
	}
	if arches := Win7NetIntelArches(data); strings.Join(arches, ",") != "x86,x64" {
		t.Fatalf("arches = %v", arches)
	}
	if status := Inspect(t.TempDir(), data); !status.Present(Win7NetIntel) {
		t.Fatal("Inspect does not report the driver")
	}
	noPartFiles(t, data)
}

// A second run must not duplicate or rewrite: the files already have the same
// SHA-256 as the zip entries.
func TestExtractWin7NetDriversIsIdempotent(t *testing.T) {
	zipPath, data := netDriverZip(t, netDriverEntries()), t.TempDir()
	if _, err := ExtractWin7NetDrivers(zipPath, data); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(data, Win7NetIntelDataDir("x64"), "e1r62x64.sys")
	before, err := os.Stat(target)
	if err != nil {
		t.Fatal(err)
	}
	written, err := ExtractWin7NetDrivers(zipPath, data)
	if err != nil {
		t.Fatal(err)
	}
	if written != 0 {
		t.Fatalf("second run wrote %d files, want 0", written)
	}
	after, err := os.Stat(target)
	if err != nil {
		t.Fatal(err)
	}
	if !after.ModTime().Equal(before.ModTime()) {
		t.Fatal("an identical file was rewritten")
	}
	entries, err := os.ReadDir(filepath.Dir(target))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 3 { // .inf, .sys, SOURCES.txt
		t.Fatalf("folder holds %d entries, want 3", len(entries))
	}
	noPartFiles(t, data)
}

func TestExtractWin7NetDriversReplacesStaleFile(t *testing.T) {
	zipPath, data := netDriverZip(t, netDriverEntries()), t.TempDir()
	stale := filepath.Join(data, Win7NetIntelDataDir("x86"), "e1r62x86.cat")
	if err := os.MkdirAll(filepath.Dir(stale), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(stale, []byte("truncated"), 0o644); err != nil {
		t.Fatal(err)
	}
	written, err := ExtractWin7NetDrivers(zipPath, data)
	if err != nil {
		t.Fatal(err)
	}
	if written != 6 { // 4 driver files + SOURCES.txt next to each arch's INF
		t.Fatalf("written = %d, want 6", written)
	}
	if got := readFile(t, stale); got != "fake cat x86" {
		t.Fatalf("stale file not replaced: %q", got)
	}
}

// No .inf means it is not a Net driver package: nothing is written.
func TestExtractWin7NetDriversRefusesPackageWithoutINF(t *testing.T) {
	zipPath := netDriverZip(t, map[string]string{
		"SOURCES.txt": "only the info file\n",
		"Systems/Windows/Windows 7/Drivers/x64/Net/Intel-I211/readme.txt": "no driver here\n",
	})
	data := t.TempDir()
	if _, err := ExtractWin7NetDrivers(zipPath, data); err == nil || !strings.Contains(err.Error(), "no .inf") {
		t.Fatalf("err = %v, want the missing .inf error", err)
	}
	if _, err := os.Stat(filepath.Join(data, "Systems")); !os.IsNotExist(err) {
		t.Fatalf("something was written: %v", err)
	}
}

func TestExtractWin7NetDriversRefusesUnexpectedLayout(t *testing.T) {
	zipPath := netDriverZip(t, map[string]string{
		"Systems/Windows/Windows 7/Drivers/x64/Net/Intel-I211/e1r62x64.inf": "[Version]\n",
		"Systems/Windows/Windows 7/Drivers/x64/Storage/a.inf":               "[Version]\n",
	})
	data := t.TempDir()
	if _, err := ExtractWin7NetDrivers(zipPath, data); err == nil || !strings.Contains(err.Error(), "unexpected zip entry") {
		t.Fatalf("err = %v, want the layout error", err)
	}
	if _, err := os.Stat(filepath.Join(data, "Systems")); !os.IsNotExist(err) {
		t.Fatalf("something was written: %v", err)
	}
}

func TestExtractWin7NetDriversRefusesUnsafeEntry(t *testing.T) {
	zipPath := netDriverZip(t, map[string]string{
		"Systems/Windows/Windows 7/Drivers/x64/Net/Intel-I211/e1r62x64.inf": "[Version]\n",
		"../../evil.inf": "[Version]\n",
	})
	data := t.TempDir()
	if _, err := ExtractWin7NetDrivers(zipPath, data); err == nil || !strings.Contains(err.Error(), "unsafe zip entry") {
		t.Fatalf("err = %v, want the unsafe entry error", err)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(data), "evil.inf")); !os.IsNotExist(err) {
		t.Fatalf("a file escaped DATA: %v", err)
	}
}

func TestParseComponentSelectionNetDrivers(t *testing.T) {
	ids, err := ParseComponentSelection("win7-net-intel,xp", "pl")
	if err != nil {
		t.Fatal(err)
	}
	if len(ids) != 2 || ids[0] != Win7NetIntel || ids[1] != XPPL {
		t.Fatalf("ids = %v", ids)
	}
	if alias, err := ParseComponentSelection("net-intel", "pl"); err != nil || len(alias) != 1 || alias[0] != Win7NetIntel {
		t.Fatalf("alias = %v, %v", alias, err)
	}
	if _, err := ParseComponentSelection("intel-nic", "pl"); err == nil || !strings.Contains(err.Error(), "win7-net-intel") {
		t.Fatalf("unknown token: %v", err)
	}
	if name := AssetName(Win7NetIntel, "1.2.3"); name != "USOS-1.2.3-NetDrivers-Intel.zip" {
		t.Fatalf("asset = %q", name)
	}
}

// recordingInstaller stands in for winhost: it only records what the Runner
// would have installed.
type recordingInstaller struct{ calls []ID }

func (r *recordingInstaller) InstallComponent(id ID, zipPath string, storeOnly bool, log func(string)) error {
	r.calls = append(r.calls, id)
	return nil
}

// A zip whose SHA-256 differs from the compiled/published hash must stop at
// verification: the installer is never called, so DATA is never written.
func TestRunnerRefusesNetDriversWithWrongHash(t *testing.T) {
	zipPath := netDriverZip(t, netDriverEntries())
	release := Release{Version: "1.2.3", Pinned: map[string]string{
		AssetName(Win7NetIntel, "1.2.3"): strings.Repeat("0", 64),
	}}
	installer := &recordingInstaller{}
	runner := &Runner{Release: release, Installer: installer, Dir: t.TempDir()}
	results := runner.Run(context.Background(), []Choice{{ID: Win7NetIntel, Source: SourceLocal, LocalPath: zipPath}}, nil)
	err := results[Win7NetIntel]
	if !errors.Is(err, ErrHashMismatch) {
		t.Fatalf("err = %v, want a SHA-256 mismatch", err)
	}
	if len(installer.calls) != 0 {
		t.Fatalf("installer called for %v", installer.calls)
	}
}

// The same zip with the right hash reaches the installer.
func TestRunnerInstallsNetDriversWithMatchingHash(t *testing.T) {
	zipPath := netDriverZip(t, netDriverEntries())
	sum, err := HashFile(zipPath)
	if err != nil {
		t.Fatal(err)
	}
	release := Release{Version: "1.2.3", Pinned: map[string]string{AssetName(Win7NetIntel, "1.2.3"): sum}}
	installer := &recordingInstaller{}
	runner := &Runner{Release: release, Installer: installer, Dir: t.TempDir()}
	results := runner.Run(context.Background(), []Choice{{ID: Win7NetIntel, Source: SourceLocal, LocalPath: zipPath}}, nil)
	if err := results[Win7NetIntel]; err != nil {
		t.Fatal(err)
	}
	if len(installer.calls) != 1 || installer.calls[0] != Win7NetIntel {
		t.Fatalf("installer calls = %v", installer.calls)
	}
}
