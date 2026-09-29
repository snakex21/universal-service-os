package components

import (
	"archive/zip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// WinPEZipDir is the donor's folder inside the WinPE zip and on DATA.
const WinPEZipDir = "Programs/USOS/WinPE/"

// XPPackageFiles are the files of EFI\USOS-XP in an XP package.
var XPPackageFiles = []string{"initramfs-xp", "vmlinuz.efi", "manifest.json"}

// XPInstallScript is the installer script shipped in every XP package zip.
const XPInstallScript = "install-xp-package.ps1"

// ExtractWinPEDonor copies the donor ISO of a verified WinPE zip to
// dataRoot\Programs\USOS\WinPE\<name> (through <name>.part, so a cut-off copy
// never looks like a donor) and returns the file name. It refuses to replace
// an existing file.
func ExtractWinPEDonor(zipPath, dataRoot string) (string, error) {
	archive, err := zip.OpenReader(zipPath)
	if err != nil {
		return "", err
	}
	defer archive.Close()
	var donor *zip.File
	for _, entry := range archive.File {
		if strings.HasPrefix(entry.Name, WinPEZipDir) && strings.EqualFold(path.Ext(entry.Name), ".iso") && !strings.Contains(strings.TrimPrefix(entry.Name, WinPEZipDir), "/") {
			if donor != nil {
				return "", errors.New("the WinPE zip holds more than one ISO")
			}
			donor = entry
		}
	}
	if donor == nil {
		return "", errors.New("the WinPE zip holds no " + WinPEZipDir + "*.iso")
	}
	name := path.Base(donor.Name)
	folder := filepath.Join(dataRoot, filepath.FromSlash(strings.TrimSuffix(WinPEZipDir, "/")))
	if err := os.MkdirAll(folder, 0o755); err != nil {
		return "", err
	}
	target := filepath.Join(folder, name)
	if _, err := os.Stat(target); err == nil {
		return "", fmt.Errorf("%s already exists", target)
	}
	if err := extractEntry(donor, target+".part"); err != nil {
		_ = os.Remove(target + ".part")
		return "", err
	}
	if err := os.Rename(target+".part", target); err != nil {
		_ = os.Remove(target + ".part")
		return "", err
	}
	return name, nil
}

// ExtractAll unpacks a verified zip into dir (entries must stay inside dir).
func ExtractAll(zipPath, dir string) error {
	archive, err := zip.OpenReader(zipPath)
	if err != nil {
		return err
	}
	defer archive.Close()
	for _, entry := range archive.File {
		clean := path.Clean(entry.Name)
		if clean == "." || strings.HasPrefix(clean, "../") || clean == ".." || path.IsAbs(clean) || strings.Contains(clean, ":") || strings.Contains(clean, `\`) {
			return fmt.Errorf("unsafe zip entry %q", entry.Name)
		}
		target := filepath.Join(dir, filepath.FromSlash(clean))
		if entry.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		if err := extractEntry(entry, target); err != nil {
			return err
		}
	}
	return nil
}

// extractEntry writes one entry; archive/zip checks the CRC-32 at the end.
func extractEntry(entry *zip.File, target string) error {
	src, err := entry.Open()
	if err != nil {
		return err
	}
	defer src.Close()
	dst, err := os.Create(target)
	if err != nil {
		return err
	}
	if _, err := io.Copy(dst, src); err != nil {
		dst.Close()
		return fmt.Errorf("unpack %s: %w", entry.Name, err)
	}
	if err := dst.Sync(); err != nil {
		dst.Close()
		return err
	}
	return dst.Close()
}

// XPManifest is the part of EFI\USOS-XP\manifest.json the installer reads.
type XPManifest struct {
	Release             bool              `json:"release"`
	ReleaseLang         string            `json:"release_lang"`
	BaseInitramfsSHA256 string            `json:"base_initramfs_sha256"`
	SHA256              map[string]string `json:"sha256"`
}

// ReadXPManifest reads a manifest.json.
func ReadXPManifest(file string) (XPManifest, error) {
	var m XPManifest
	data, err := os.ReadFile(file)
	if err != nil {
		return m, err
	}
	err = json.Unmarshal(data, &m)
	return m, err
}
