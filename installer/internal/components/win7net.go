package components

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// Windows 7 and Server 2008 R2 have no driver for the Intel I211
// (PCI\VEN_8086&DEV_1539); Intel ships e1r62x86/e1r62x64 in the "Intel Ethernet
// Adapter Complete Driver Pack". The maintainer decision of 2026-10-22 keeps
// those files out of the repository and ships them as their own release asset
// (USOS-<version>-NetDrivers-Intel.zip, a copy on archive.org), so the installer
// only ever handles a verified zip the user downloaded from USOS and unpacks it
// into the DATA layout the Windows installer reads (docs/network-win7.md).
const (
	// Win7NetIntelFolder is the package folder below Net on DATA.
	Win7NetIntelFolder = "Intel-I211"
	// win7NetDriversPrefix is the DATA tree of the Windows 7 drivers.
	win7NetDriversPrefix = "Systems/Windows/Windows 7/Drivers"
	// win7NetSources is the info file of the package (Intel version, download
	// URL, SHA-256, licence note). It is copied next to every installed arch.
	win7NetSources = "SOURCES.txt"
)

// NetDriverArches are the per-architecture folders of the package.
var NetDriverArches = []string{"x86", "x64"}

// Win7NetIntelDataDir is DATA\Systems\Windows\Windows 7\Drivers\<arch>\Net\Intel-I211,
// exactly the folder the Win7 installer scans recursively (x86 CSMWrap DISM,
// x64 DriverPaths).
func Win7NetIntelDataDir(arch string) string {
	return filepath.Join("Systems", "Windows", "Windows 7", "Drivers", arch, "Net", Win7NetIntelFolder)
}

// Win7NetIntelArches lists the architectures installed on DATA (a folder with
// at least one .inf counts).
func Win7NetIntelArches(dataRoot string) []string {
	var found []string
	for _, arch := range NetDriverArches {
		entries, err := os.ReadDir(filepath.Join(dataRoot, Win7NetIntelDataDir(arch)))
		if err != nil {
			continue
		}
		for _, entry := range entries {
			if !entry.IsDir() && strings.EqualFold(filepath.Ext(entry.Name()), ".inf") {
				found = append(found, arch)
				break
			}
		}
	}
	return found
}

// Win7NetIntelPresent reports whether a Net driver package is on DATA.
func Win7NetIntelPresent(dataRoot string) bool { return len(Win7NetIntelArches(dataRoot)) > 0 }

// ExtractWin7NetDrivers unpacks a verified NetDrivers-Intel zip onto DATA:
// SOURCES.txt and
// Systems/Windows/Windows 7/Drivers/<x86|x64>/Net/Intel-I211/<files>.
// Every file is written through a .part file and checked by SHA-256, an
// identical file already on DATA is left alone (so a second run neither
// duplicates nor rewrites), and a package without a .inf is refused before
// anything is written. Returns the number of files written.
func ExtractWin7NetDrivers(zipPath, dataRoot string) (int, error) {
	archive, err := zip.OpenReader(zipPath)
	if err != nil {
		return 0, fmt.Errorf("open the Net drivers package: %w", err)
	}
	defer archive.Close()
	type entry struct {
		file *zip.File
		rel  string
	}
	var entries []entry
	sources := map[string]bool{} // arch -> package has an .inf
	var info *zip.File
	for _, file := range archive.File {
		clean := path.Clean(strings.ReplaceAll(file.Name, `\`, "/"))
		if clean == "." || clean == ".." || strings.HasPrefix(clean, "../") || path.IsAbs(clean) || strings.Contains(clean, ":") {
			return 0, fmt.Errorf("unsafe zip entry %q", file.Name)
		}
		if file.FileInfo().IsDir() {
			continue
		}
		if strings.EqualFold(clean, win7NetSources) {
			info = file
			continue
		}
		arch, rest, ok := splitNetDriverEntry(clean)
		if !ok {
			return 0, fmt.Errorf("unexpected zip entry %q: the package holds %s/<x86|x64>/Net/%s/ and %s",
				file.Name, win7NetDriversPrefix, Win7NetIntelFolder, win7NetSources)
		}
		if !strings.Contains(rest, "/") && strings.EqualFold(path.Ext(rest), ".inf") {
			sources[arch] = true
		}
		entries = append(entries, entry{file: file, rel: clean})
	}
	if len(sources) == 0 {
		return 0, fmt.Errorf("no .inf in %s/<x86|x64>/Net/%s: not a Net drivers package",
			win7NetDriversPrefix, Win7NetIntelFolder)
	}
	written := 0
	for _, e := range entries {
		wrote, err := extractIfChanged(e.file, filepath.Join(dataRoot, filepath.FromSlash(e.rel)))
		if err != nil {
			return written, err
		}
		if wrote {
			written++
		}
	}
	if info != nil {
		for _, arch := range NetDriverArches {
			if !sources[arch] {
				continue
			}
			wrote, err := extractIfChanged(info, filepath.Join(dataRoot, Win7NetIntelDataDir(arch), win7NetSources))
			if err != nil {
				return written, err
			}
			if wrote {
				written++
			}
		}
	}
	return written, nil
}

// splitNetDriverEntry splits a zip entry into its architecture and the path
// below Net\Intel-I211. The DATA prefix is matched case-insensitively (zip
// tools on Windows vary the case), the file names are kept as they are.
func splitNetDriverEntry(clean string) (arch, rest string, ok bool) {
	prefix := win7NetDriversPrefix + "/"
	if len(clean) <= len(prefix) || !strings.EqualFold(clean[:len(prefix)], prefix) {
		return "", "", false
	}
	parts := strings.Split(clean[len(prefix):], "/")
	if len(parts) < 4 || !strings.EqualFold(parts[1], "Net") || !strings.EqualFold(parts[2], Win7NetIntelFolder) {
		return "", "", false
	}
	for _, known := range NetDriverArches {
		if strings.EqualFold(parts[0], known) {
			return known, strings.Join(parts[3:], "/"), true
		}
	}
	return "", "", false
}

// extractIfChanged writes one entry to target unless target already has the
// same SHA-256. The copy is hashed while it is written and compared with the
// zip entry (archive/zip also checks the CRC-32), so a damaged entry never
// stays on DATA.
func extractIfChanged(file *zip.File, target string) (bool, error) {
	sum, err := entrySum(file)
	if err != nil {
		return false, err
	}
	if got, err := HashFile(target); err == nil && got == sum {
		return false, nil
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return false, err
	}
	src, err := file.Open()
	if err != nil {
		return false, err
	}
	defer src.Close()
	part := target + ".part"
	dst, err := os.Create(part)
	if err != nil {
		return false, err
	}
	h := sha256.New()
	_, copyErr := io.Copy(io.MultiWriter(dst, h), src)
	syncErr := dst.Sync()
	closeErr := dst.Close()
	if err := errors.Join(copyErr, syncErr, closeErr); err != nil {
		os.Remove(part)
		return false, fmt.Errorf("unpack %s: %w", file.Name, err)
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != sum {
		os.Remove(part)
		return false, fmt.Errorf("%s: %w", file.Name, ErrHashMismatch)
	}
	os.Remove(target)
	if err := os.Rename(part, target); err != nil {
		os.Remove(part)
		return false, err
	}
	return true, nil
}

// entrySum is the SHA-256 of a zip entry's content.
func entrySum(file *zip.File) (string, error) {
	src, err := file.Open()
	if err != nil {
		return "", err
	}
	defer src.Close()
	h := sha256.New()
	if _, err := io.Copy(h, src); err != nil {
		return "", fmt.Errorf("read %s: %w", file.Name, err)
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
