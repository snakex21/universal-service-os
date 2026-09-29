package components

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
)

// The all-in-one installer carries the component zips as an overlay appended
// to the PE image (Windows ignores data after the last section):
//
//	[installer.exe][zip 1][zip 2]...[index JSON][trailer]
//	trailer = "USOSCMP1" | index offset (u64 LE) | index length (u64 LE)
//
// The index only locates the zips; trust comes from the hash list compiled
// into the installer (Release.Pinned), which every extracted zip must match.

var bundleMagic = []byte("USOSCMP1")

const bundleTrailerSize = 8 + 8 + 8

// BundleEntry is one component zip inside the overlay.
type BundleEntry struct {
	Name   string `json:"name"`
	Offset int64  `json:"offset"`
	Size   int64  `json:"size"`
}

type bundleIndex struct {
	Version int           `json:"version"`
	Files   []BundleEntry `json:"files"`
}

// Bundle is the component overlay of an installer executable.
type Bundle struct {
	Path    string
	Entries map[string]BundleEntry
}

// Has reports whether the bundle carries asset.
func (b *Bundle) Has(asset string) bool {
	if b == nil || asset == "" {
		return false
	}
	_, ok := b.Entries[asset]
	return ok
}

// ErrNoBundle: the executable has no component overlay (the online build).
var ErrNoBundle = errors.New("no embedded components")

// OpenBundle reads the overlay index of an executable.
func OpenBundle(path string) (*Bundle, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if info.Size() < bundleTrailerSize {
		return nil, ErrNoBundle
	}
	trailer := make([]byte, bundleTrailerSize)
	if _, err := f.ReadAt(trailer, info.Size()-bundleTrailerSize); err != nil {
		return nil, err
	}
	if !bytes.Equal(trailer[:8], bundleMagic) {
		return nil, ErrNoBundle
	}
	indexOffset := int64(binary.LittleEndian.Uint64(trailer[8:16]))
	indexSize := int64(binary.LittleEndian.Uint64(trailer[16:24]))
	if indexOffset < 0 || indexSize <= 0 || indexSize > 1<<20 || indexOffset+indexSize != info.Size()-bundleTrailerSize {
		return nil, fmt.Errorf("%s: damaged component index", path)
	}
	raw := make([]byte, indexSize)
	if _, err := f.ReadAt(raw, indexOffset); err != nil {
		return nil, err
	}
	var index bundleIndex
	if err := json.Unmarshal(raw, &index); err != nil || index.Version != 1 {
		return nil, fmt.Errorf("%s: unreadable component index", path)
	}
	b := &Bundle{Path: path, Entries: map[string]BundleEntry{}}
	for _, e := range index.Files {
		if e.Name == "" || filepath.Base(e.Name) != e.Name || e.Offset < 0 || e.Size <= 0 || e.Offset+e.Size > indexOffset {
			return nil, fmt.Errorf("%s: bad component entry %q", path, e.Name)
		}
		b.Entries[e.Name] = e
	}
	return b, nil
}

var (
	embeddedOnce   sync.Once
	embeddedBundle *Bundle
)

// EmbeddedBundle is the overlay of the running installer, nil for the
// online build (or when it cannot be read).
func EmbeddedBundle() *Bundle {
	embeddedOnce.Do(func() {
		exe, err := os.Executable()
		if err != nil {
			return
		}
		if b, err := OpenBundle(exe); err == nil {
			embeddedBundle = b
		}
	})
	return embeddedBundle
}

// Extract copies asset out of the bundle to dir/asset, verifying it against
// the compiled hash list on the way (a mismatch deletes the copy).
func (b *Bundle) Extract(asset, dir string, pinned map[string]string) (string, error) {
	entry, ok := b.Entries[asset]
	if !ok {
		return "", fmt.Errorf("%s: %w", asset, ErrNoBundle)
	}
	if len(pinned) == 0 {
		return "", fmt.Errorf("%s: this installer has no compiled hash list: %w", asset, ErrUnverifiable)
	}
	src, err := os.Open(b.Path)
	if err != nil {
		return "", err
	}
	defer src.Close()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	target := filepath.Join(dir, asset)
	part := target + ".part"
	dst, err := os.Create(part)
	if err != nil {
		return "", err
	}
	h := sha256.New()
	_, copyErr := io.Copy(io.MultiWriter(dst, h), io.NewSectionReader(src, entry.Offset, entry.Size))
	closeErr := dst.Close()
	if err := errors.Join(copyErr, closeErr); err != nil {
		os.Remove(part)
		return "", err
	}
	if err := Check(asset, hex.EncodeToString(h.Sum(nil)), pinned, nil); err != nil {
		os.Remove(part)
		return "", err
	}
	if err := os.Rename(part, target); err != nil {
		os.Remove(part)
		return "", err
	}
	return target, nil
}

// WriteBundle writes exe followed by the component zips as an overlay
// (make_release.ps1 through cmd/usos-component-bundle).
func WriteBundle(out, exe string, zips []string) error {
	dst, err := os.Create(out)
	if err != nil {
		return err
	}
	ok := false
	defer func() {
		dst.Close()
		if !ok {
			os.Remove(out)
		}
	}()
	appendFile := func(path string) (int64, error) {
		src, err := os.Open(path)
		if err != nil {
			return 0, err
		}
		defer src.Close()
		return io.Copy(dst, src)
	}
	offset, err := appendFile(exe)
	if err != nil {
		return err
	}
	index := bundleIndex{Version: 1}
	for _, z := range zips {
		n, err := appendFile(z)
		if err != nil {
			return err
		}
		index.Files = append(index.Files, BundleEntry{Name: filepath.Base(z), Offset: offset, Size: n})
		offset += n
	}
	raw, err := json.Marshal(index)
	if err != nil {
		return err
	}
	trailer := make([]byte, bundleTrailerSize)
	copy(trailer, bundleMagic)
	binary.LittleEndian.PutUint64(trailer[8:16], uint64(offset))
	binary.LittleEndian.PutUint64(trailer[16:24], uint64(len(raw)))
	if _, err := dst.Write(append(raw, trailer...)); err != nil {
		return err
	}
	if err := dst.Sync(); err != nil {
		return err
	}
	ok = true
	return nil
}
