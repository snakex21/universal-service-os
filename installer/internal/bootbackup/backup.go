// Package bootbackup persists the bytes an update is about to replace.
package bootbackup

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/legacyboot"
)

type Options struct {
	Directory, Build, Identity string
	SectorBytes                uint32
	CoreOffset                 uint64
	Log                        func(string) error
}

// BeforeUpdate calls update only after all evidence files are flushed, closed,
// read back and recorded. A failed backup or log write leaves the disk untouched.
func BeforeUpdate(disk io.ReaderAt, options Options, update func() error) error {
	if err := Save(disk, options); err != nil {
		return err
	}
	return update()
}

func Save(disk io.ReaderAt, options Options) error {
	if options.SectorBytes != legacyboot.SupportedSectorBytes || options.CoreOffset != legacyboot.CoreLBA*uint64(options.SectorBytes) {
		return fmt.Errorf("unsupported boot backup geometry")
	}
	if options.Directory == "" || options.Build == "" || options.Log == nil {
		return fmt.Errorf("boot backup directory, build and logger are required")
	}
	if info, err := os.Stat(options.Directory); err != nil || !info.IsDir() {
		return fmt.Errorf("boot backup directory is unavailable: %s", options.Directory)
	}
	build := strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_' {
			return r
		}
		return '_'
	}, options.Build)
	if len(build) > 96 {
		return fmt.Errorf("boot backup build name is too long")
	}
	for _, region := range []struct {
		name   string
		offset int64
		size   int
	}{
		{"lba0", 0, int(options.SectorBytes)},
		{"lba1", int64(options.SectorBytes), int(options.SectorBytes)},
		{"core", int64(options.CoreOffset), int(legacyboot.CoreSlotBytes)},
	} {
		data := make([]byte, region.size)
		if n, err := disk.ReadAt(data, region.offset); err != nil || n != len(data) {
			return fmt.Errorf("read pre-deploy %s: bytes=%d/%d error=%v", region.name, n, len(data), err)
		}
		file, err := os.CreateTemp(options.Directory, "USOS-pre-deploy-"+region.name+"-"+build+"-*.bin")
		if err != nil {
			return fmt.Errorf("create pre-deploy %s: %w", region.name, err)
		}
		path := file.Name()
		n, writeErr := file.Write(data)
		if writeErr == nil && n != len(data) {
			writeErr = io.ErrShortWrite
		}
		if writeErr == nil {
			writeErr = file.Sync()
		}
		closeErr := file.Close()
		if writeErr != nil {
			return fmt.Errorf("persist pre-deploy %s (%s): %w", region.name, path, writeErr)
		}
		if closeErr != nil {
			return fmt.Errorf("close pre-deploy %s: %w", region.name, closeErr)
		}
		readback, err := os.ReadFile(path)
		if err != nil || !bytes.Equal(data, readback) {
			return fmt.Errorf("pre-deploy %s readback failed: %v", region.name, err)
		}
		hash := sha256.Sum256(data)
		if err := options.Log(fmt.Sprintf("PRE-DEPLOY BACKUP file=%q offset=%d bytes=%d sha256=%x build=%q target=%q", filepath.Clean(path), region.offset, len(data), hash, options.Build, options.Identity)); err != nil {
			return fmt.Errorf("record pre-deploy %s backup: %w", region.name, err)
		}
	}
	return nil
}
