package bootbackup

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type fakeDisk struct {
	*bytes.Reader
	writes int
}

func (d *fakeDisk) WriteAt(p []byte, off int64) (int, error) { d.writes++; return len(p), nil }
func options(dir string) Options {
	return Options{Directory: dir, Build: "B-test", Identity: "fake image", SectorBytes: 512, CoreOffset: 32768, Log: func(string) error { return nil }}
}
func disk() *fakeDisk {
	data := make([]byte, 32768+262144)
	for i := range data {
		data[i] = byte(i*37 + 11)
	}
	return &fakeDisk{Reader: bytes.NewReader(data)}
}

func TestCompleteEvidenceExistsBeforeFirstWrite(t *testing.T) {
	dir := t.TempDir()
	d := disk()
	opt := options(dir)
	var lines []string
	opt.Log = func(line string) error { lines = append(lines, line); return nil }
	err := BeforeUpdate(d, opt, func() error {
		files, _ := filepath.Glob(filepath.Join(dir, "*.bin"))
		if len(files) != 3 {
			t.Fatalf("before write: %d backups", len(files))
		}
		for _, p := range files {
			raw, err := os.ReadFile(p)
			if err != nil {
				t.Fatal(err)
			}
			offset := int64(0)
			if strings.Contains(p, "-lba1-") {
				offset = 512
			}
			if strings.Contains(p, "-core-") {
				offset = 32768
			}
			want := make([]byte, len(raw))
			d.ReadAt(want, offset)
			if !bytes.Equal(raw, want) {
				t.Fatalf("incomplete backup %s", p)
			}
			h := sha256.Sum256(raw)
			found := false
			for _, line := range lines {
				if strings.Contains(line, fmt.Sprintf("sha256=%x", h)) {
					found = true
				}
			}
			if !found {
				t.Fatal("missing SHA-256 log")
			}
		}
		_, err := d.WriteAt([]byte{1}, 0)
		return err
	})
	if err != nil || d.writes != 1 {
		t.Fatalf("err=%v writes=%d", err, d.writes)
	}
	// Repeated deployments keep distinct evidence; no overwrite of old LBA0.
	if err := Save(d, opt); err != nil {
		t.Fatal(err)
	}
	files, _ := filepath.Glob(filepath.Join(dir, "*.bin"))
	if len(files) != 6 {
		t.Fatalf("evidence overwritten: %d", len(files))
	}
}

func TestBackupFailuresPreventAllDiskWrites(t *testing.T) {
	for _, kind := range []string{"missing directory", "directory is file", "short disk", "log failure", "wrong geometry"} {
		t.Run(kind, func(t *testing.T) {
			d := disk()
			opt := options(t.TempDir())
			switch kind {
			case "missing directory":
				opt.Directory = filepath.Join(opt.Directory, "absent")
			case "directory is file":
				p := filepath.Join(opt.Directory, "file")
				os.WriteFile(p, []byte{0}, 0600)
				opt.Directory = p
			case "short disk":
				d.Reader = bytes.NewReader([]byte{0})
			case "log failure":
				opt.Log = func(string) error { return errors.New("disk full") }
			case "wrong geometry":
				opt.SectorBytes = 4096
			}
			err := BeforeUpdate(d, opt, func() error { _, e := d.WriteAt([]byte{1}, 0); return e })
			if err == nil || d.writes != 0 {
				t.Fatalf("err=%v writes=%d", err, d.writes)
			}
		})
	}
}
