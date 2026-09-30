package components

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
)

// LegacyMSDataDir holds the Microsoft redistributables of the Windows
// 95/98/Me/NT 4.0 compatibility pack on DATA (docs/design/legacy-compat-pack.md):
// the release asset USOS-<version>-Legacy-pack-MS.zip unpacked. The pack's
// staging finds its files there by SHA-256.
var LegacyMSDataDir = filepath.Join("Addons", "USOS", "MS")

const legacyMSZipPrefix = "Addons/USOS/MS/"

// LegacyMSIndex is Addons\USOS\MS\legacy-ms.json (tools/addons/legacy_ms_asset.py).
type LegacyMSIndex struct {
	Format   int    `json:"format"`
	Version  string `json:"version"`
	Decision string `json:"decision"`
	Files    []struct {
		Package string `json:"package"`
		Dir     string `json:"dir"`
		File    string `json:"file"`
		SHA256  string `json:"sha256"`
		Size    int64  `json:"size"`
	} `json:"files"`
}

var legacyName83 = regexp.MustCompile(`^[A-Z0-9_\-]{1,8}(\.[A-Z0-9_\-]{1,3})?$`)

// ReadLegacyMSIndex reads the index of an unpacked asset.
func ReadLegacyMSIndex(path string) (LegacyMSIndex, error) {
	var index LegacyMSIndex
	data, err := os.ReadFile(path)
	if err != nil {
		return index, err
	}
	if err := json.Unmarshal(data, &index); err != nil {
		return index, err
	}
	if index.Format != 1 || len(index.Files) == 0 {
		return index, errors.New("legacy-ms.json: unknown format or no files")
	}
	return index, nil
}

// ExtractLegacyMS unpacks a verified Legacy-pack-MS zip onto DATA. Only
// Addons/USOS/MS/<DIR>/<8.3 name> entries listed in its index (and the index
// and README) are written, each checked by SHA-256 before it replaces a file.
func ExtractLegacyMS(zipPath, dataRoot string) (int, error) {
	r, err := zip.OpenReader(zipPath)
	if err != nil {
		return 0, err
	}
	defer r.Close()
	byName := map[string]*zip.File{}
	for _, f := range r.File {
		byName[f.Name] = f
	}
	indexFile := byName[legacyMSZipPrefix+"legacy-ms.json"]
	if indexFile == nil {
		return 0, errors.New("not a legacy pack MS asset (no legacy-ms.json)")
	}
	rc, err := indexFile.Open()
	if err != nil {
		return 0, err
	}
	raw, err := io.ReadAll(io.LimitReader(rc, 1<<20))
	rc.Close()
	if err != nil {
		return 0, err
	}
	var index LegacyMSIndex
	if err := json.Unmarshal(raw, &index); err != nil || index.Format != 1 || len(index.Files) == 0 {
		return 0, errors.New("legacy-ms.json: unknown format or no files")
	}
	root := filepath.Join(dataRoot, LegacyMSDataDir)
	count := 0
	for _, entry := range index.Files {
		if !legacyName83.MatchString(entry.Dir) || strings.Contains(entry.Dir, ".") || !legacyName83.MatchString(entry.File) {
			return count, fmt.Errorf("legacy-ms.json: bad name %s/%s", entry.Dir, entry.File)
		}
		f := byName[path.Join(strings.TrimSuffix(legacyMSZipPrefix, "/"), entry.Dir, entry.File)]
		if f == nil {
			return count, fmt.Errorf("asset lacks %s/%s", entry.Dir, entry.File)
		}
		if err := extractChecked(f, filepath.Join(root, entry.Dir, entry.File), strings.ToLower(entry.SHA256)); err != nil {
			return count, err
		}
		count++
	}
	for _, name := range []string{"README.txt", "legacy-ms.json"} {
		if f := byName[legacyMSZipPrefix+name]; f != nil {
			if err := extractChecked(f, filepath.Join(root, name), ""); err != nil {
				return count, err
			}
		}
	}
	return count, nil
}

// extractChecked writes f to target through a .part file; want (when set)
// is the SHA-256 the content must have.
func extractChecked(f *zip.File, target, want string) error {
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	if want != "" {
		if got, err := HashFile(target); err == nil && got == want {
			return nil // already there
		}
	}
	src, err := f.Open()
	if err != nil {
		return err
	}
	defer src.Close()
	part := target + ".part"
	dst, err := os.Create(part)
	if err != nil {
		return err
	}
	h := sha256.New()
	_, copyErr := io.Copy(io.MultiWriter(dst, h), src)
	syncErr := dst.Sync()
	closeErr := dst.Close()
	if err := errors.Join(copyErr, syncErr, closeErr); err != nil {
		os.Remove(part)
		return err
	}
	if want != "" && hex.EncodeToString(h.Sum(nil)) != want {
		os.Remove(part)
		return fmt.Errorf("%s: %w", f.Name, ErrHashMismatch)
	}
	os.Remove(target)
	return os.Rename(part, target)
}
