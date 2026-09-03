package payload

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

//go:embed assets/payload.zip assets/README.md
var embedded embed.FS

type File struct {
	Path   string
	Size   uint64
	SHA256 string
}

type Bundle struct {
	data []byte
}

func README() ([]byte, error) {
	data, err := embedded.ReadFile("assets/README.md")
	if err != nil {
		return nil, fmt.Errorf("read embedded DATA README: %w", err)
	}
	if len(data) == 0 {
		return nil, fmt.Errorf("embedded DATA README is empty")
	}
	return append([]byte(nil), data...), nil
}

func Embedded() (Bundle, error) {
	data, err := embedded.ReadFile("assets/payload.zip")
	if err != nil {
		return Bundle{}, fmt.Errorf("read embedded payload: %w", err)
	}
	if len(data) == 0 {
		return Bundle{}, fmt.Errorf("embedded payload is empty")
	}
	bundle := Bundle{data: data}
	if _, err := bundle.Manifest(); err != nil {
		return Bundle{}, err
	}
	return bundle, nil
}

func (b Bundle) Manifest() ([]File, error) {
	reader, err := zip.NewReader(bytes.NewReader(b.data), int64(len(b.data)))
	if err != nil {
		return nil, fmt.Errorf("open embedded payload ZIP: %w", err)
	}
	if len(reader.File) == 0 {
		return nil, fmt.Errorf("embedded payload ZIP has no files")
	}
	files := make([]File, 0, len(reader.File))
	for _, entry := range reader.File {
		clean, err := safeRelativePath(entry.Name)
		if err != nil {
			return nil, err
		}
		if entry.FileInfo().IsDir() {
			continue
		}
		rc, err := entry.Open()
		if err != nil {
			return nil, fmt.Errorf("open embedded payload entry %s: %w", clean, err)
		}
		hash := sha256.New()
		written, copyErr := io.Copy(hash, rc)
		closeErr := rc.Close()
		if copyErr != nil {
			return nil, fmt.Errorf("hash embedded payload entry %s: %w", clean, copyErr)
		}
		if closeErr != nil {
			return nil, fmt.Errorf("close embedded payload entry %s: %w", clean, closeErr)
		}
		if uint64(written) != entry.UncompressedSize64 {
			return nil, fmt.Errorf("embedded payload entry %s size mismatch: read %d want %d", clean, written, entry.UncompressedSize64)
		}
		files = append(files, File{Path: clean, Size: uint64(written), SHA256: hex.EncodeToString(hash.Sum(nil))})
	}
	return files, nil
}

func (b Bundle) TotalBytes() (uint64, error) {
	manifest, err := b.Manifest()
	if err != nil {
		return 0, err
	}
	var total uint64
	for _, file := range manifest {
		total += file.Size
	}
	return total, nil
}

func (b Bundle) Verify(root string) error {
	manifest, err := b.Manifest()
	if err != nil {
		return err
	}
	for _, expected := range manifest {
		path := filepath.Join(root, filepath.FromSlash(expected.Path))
		input, err := os.Open(path)
		if err != nil {
			return fmt.Errorf("open extracted payload %s: %w", path, err)
		}
		hash := sha256.New()
		written, copyErr := io.Copy(hash, input)
		closeErr := input.Close()
		if copyErr != nil {
			return fmt.Errorf("hash extracted payload %s: %w", path, copyErr)
		}
		if closeErr != nil {
			return fmt.Errorf("close extracted payload %s: %w", path, closeErr)
		}
		if uint64(written) != expected.Size {
			return fmt.Errorf("extracted payload size mismatch for %s: got %d want %d", expected.Path, written, expected.Size)
		}
		actualHash := hex.EncodeToString(hash.Sum(nil))
		if actualHash != expected.SHA256 {
			return fmt.Errorf("extracted payload SHA-256 mismatch for %s: got %s want %s", expected.Path, actualHash, expected.SHA256)
		}
	}
	return nil
}

func (b Bundle) Extract(root string, progress func(done, total uint64)) error {
	reader, err := zip.NewReader(bytes.NewReader(b.data), int64(len(b.data)))
	if err != nil {
		return fmt.Errorf("open embedded payload ZIP: %w", err)
	}
	var total uint64
	for _, entry := range reader.File {
		if !entry.FileInfo().IsDir() {
			total += entry.UncompressedSize64
		}
	}
	var done uint64
	if progress != nil {
		progress(0, total)
	}
	for _, entry := range reader.File {
		clean, err := safeRelativePath(entry.Name)
		if err != nil {
			return err
		}
		target := filepath.Join(root, filepath.FromSlash(clean))
		if entry.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0o755); err != nil {
				return fmt.Errorf("create payload directory %s: %w", target, err)
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return fmt.Errorf("create payload parent for %s: %w", target, err)
		}
		rc, err := entry.Open()
		if err != nil {
			return fmt.Errorf("open payload entry %s: %w", clean, err)
		}
		out, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
		if err != nil {
			_ = rc.Close()
			return fmt.Errorf("create payload file %s: %w", target, err)
		}
		buffer := make([]byte, 1024*1024)
		for {
			n, readErr := rc.Read(buffer)
			if n > 0 {
				written, writeErr := out.Write(buffer[:n])
				if writeErr != nil {
					_ = out.Close()
					_ = rc.Close()
					return fmt.Errorf("write payload file %s: %w", target, writeErr)
				}
				if written != n {
					_ = out.Close()
					_ = rc.Close()
					return fmt.Errorf("short write payload file %s: wrote %d of %d", target, written, n)
				}
				done += uint64(written)
				if progress != nil {
					progress(done, total)
				}
			}
			if readErr == io.EOF {
				break
			}
			if readErr != nil {
				_ = out.Close()
				_ = rc.Close()
				return fmt.Errorf("read payload entry %s: %w", clean, readErr)
			}
		}
		if err := out.Sync(); err != nil {
			_ = out.Close()
			_ = rc.Close()
			return fmt.Errorf("flush payload file %s: %w", target, err)
		}
		if err := out.Close(); err != nil {
			_ = rc.Close()
			return fmt.Errorf("close payload file %s: %w", target, err)
		}
		if err := rc.Close(); err != nil {
			return fmt.Errorf("close payload entry %s: %w", clean, err)
		}
	}
	return nil
}

func safeRelativePath(name string) (string, error) {
	clean := filepath.ToSlash(filepath.Clean(filepath.FromSlash(name)))
	if clean == "." || clean == "" || strings.HasPrefix(clean, "../") || strings.HasPrefix(clean, "/") || filepath.IsAbs(filepath.FromSlash(name)) {
		return "", fmt.Errorf("unsafe embedded payload path %q", name)
	}
	return clean, nil
}
