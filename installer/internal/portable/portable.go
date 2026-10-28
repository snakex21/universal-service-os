// Package portable keeps all installer state in data\ beside the EXE:
// preferences, the AutoPlay restore journal, per-computer "key enrolled"
// markers, temporary work (data\tmp, removed on exit) and, for usos-efisign,
// the Secure Boot signing key (data\signing).
//
// There is no fallback to a user-profile directory: when the EXE folder is
// not writable, Init returns ErrNotWritable and the program must tell the
// user to move the folder. State left by older versions in %APPDATA%\USOS is
// only read (legacy.go) and copied once; it is never changed or deleted.
package portable

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// SigningDirName is the key folder inside data\ (and inside the legacy
// %APPDATA%\USOS). The generic migration below never touches it; the key
// copy is done by internal/efisign with byte-for-byte verification.
const SigningDirName = "signing"

// TempDirName is the temporary work folder inside data\.
const TempDirName = "tmp"

// ErrNotWritable reports that data\ beside the EXE cannot be written.
var ErrNotWritable = errors.New("portable data folder is not writable")

type state struct {
	dir         string
	err         error
	migrated    []string
	migrateErrs []string
}

var (
	mu       sync.Mutex
	resolved *state
)

// anchorDir is the folder data\ is created in: the EXE's folder, or the
// current directory for a `go run` binary (go-build...\b001\exe\x.exe is
// deleted after the run; every `go run ./cmd/...` call is made from
// installer\, i.e. beside "USOS Installer.exe").
func anchorDir(exe string) string {
	dir := filepath.Dir(exe)
	if isGoRunBinary(exe) {
		if wd, err := os.Getwd(); err == nil {
			return wd
		}
	}
	return dir
}

func isGoRunBinary(exe string) bool {
	parts := strings.Split(filepath.ToSlash(filepath.Clean(exe)), "/")
	if len(parts) < 4 || !strings.EqualFold(parts[len(parts)-2], "exe") {
		return false
	}
	for _, p := range parts[:len(parts)-2] {
		if strings.HasPrefix(strings.ToLower(p), "go-build") {
			return true
		}
	}
	return false
}

// probeWritable creates dir\tmp and checks a file can be created there.
func probeWritable(dir string) error {
	work := filepath.Join(dir, TempDirName)
	if err := os.MkdirAll(work, 0o755); err != nil {
		return err
	}
	probe, err := os.CreateTemp(work, ".write-check-")
	if err != nil {
		return err
	}
	name := probe.Name()
	closeErr := probe.Close()
	removeErr := os.Remove(name)
	if closeErr != nil {
		return closeErr
	}
	return removeErr
}

// resolveIn picks data\ under anchor and copies legacy state once.
func resolveIn(anchor, legacy string) *state {
	dir := filepath.Join(anchor, "data")
	if err := probeWritable(dir); err != nil {
		return &state{dir: dir, err: fmt.Errorf("%w: %s: %v", ErrNotWritable, dir, err)}
	}
	st := &state{dir: dir}
	if legacy != "" {
		st.migrated, st.migrateErrs = migrateLegacy(legacy, dir)
	}
	return st
}

func current() *state {
	mu.Lock()
	defer mu.Unlock()
	if resolved != nil {
		return resolved
	}
	exe, err := os.Executable()
	if err != nil {
		resolved = &state{err: fmt.Errorf("locate application folder: %w", err)}
		return resolved
	}
	resolved = resolveIn(anchorDir(exe), LegacyDir())
	return resolved
}

// DataDir returns data\ beside the EXE, or an error (ErrNotWritable) when it
// cannot be written.
func DataDir() (string, error) {
	st := current()
	return st.dir, st.err
}

// Path returns name inside DataDir.
func Path(name string) (string, error) {
	dir, err := DataDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, name), nil
}

// TempDir returns data\tmp.
func TempDir() (string, error) { return Path(TempDirName) }

// Migrated lists files copied from %APPDATA%\USOS on this start;
// MigrationErrors those that could not be copied.
func Migrated() []string { return append([]string(nil), current().migrated...) }

func MigrationErrors() []string { return append([]string(nil), current().migrateErrs...) }

// Init resolves data\ and redirects TEMP/TMP (os.MkdirTemp("") and child
// processes such as PowerShell and DISM) to data\tmp.
func Init() error {
	st := current()
	if st.err != nil {
		return st.err
	}
	return applyEnv(st.dir)
}

func applyEnv(dir string) error {
	work := filepath.Join(dir, TempDirName)
	for _, name := range []string{"TEMP", "TMP", "TMPDIR"} {
		if err := os.Setenv(name, work); err != nil {
			return err
		}
	}
	return os.Setenv("PSModuleAnalysisCachePath", filepath.Join(dir, "powershell-module-cache"))
}

// Cleanup removes data\tmp (called when the program exits).
func Cleanup() error {
	st := current()
	if st.err != nil {
		return nil
	}
	return os.RemoveAll(filepath.Join(st.dir, TempDirName))
}

// migratable reports whether a top-level entry of %APPDATA%\USOS is
// installer state the generic migration copies into data\.
func migratable(name string) bool {
	lower := strings.ToLower(name)
	return lower == "installer.ini" || strings.HasPrefix(lower, "mok-enrolled-")
}

// migrateLegacy copies installer state from the old per-user directory.
// Old files are only read, files already in data\ are never overwritten,
// and directories (signing among them) are skipped.
func migrateLegacy(legacy, local string) (copied, failed []string) {
	if sameDir(legacy, local) {
		return nil, nil
	}
	entries, err := os.ReadDir(legacy)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			failed = append(failed, legacy+": "+err.Error())
		}
		return nil, failed
	}
	for _, e := range entries {
		if !e.Type().IsRegular() || !migratable(e.Name()) {
			continue
		}
		dst := filepath.Join(local, e.Name())
		if _, err := os.Lstat(dst); err == nil {
			continue
		}
		if err := CopyNew(filepath.Join(legacy, e.Name()), dst, 0o644); err != nil {
			failed = append(failed, e.Name()+": "+err.Error())
			continue
		}
		copied = append(copied, e.Name())
	}
	return copied, failed
}

func sameDir(a, b string) bool {
	ca, errA := filepath.Abs(a)
	cb, errB := filepath.Abs(b)
	return errA == nil && errB == nil && strings.EqualFold(filepath.Clean(ca), filepath.Clean(cb))
}

// CopyNew copies src to a new file dst (never overwriting) and verifies the
// copy byte for byte; a failed or different copy is removed. src is only
// read.
func CopyNew(src, dst string, mode os.FileMode) error {
	want, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	_, writeErr := out.Write(want)
	if writeErr == nil {
		writeErr = out.Sync()
	}
	closeErr := out.Close()
	if writeErr == nil {
		writeErr = closeErr
	}
	if writeErr == nil {
		writeErr = verifySame(dst, want)
	}
	if writeErr != nil {
		_ = os.Remove(dst)
	}
	return writeErr
}

func verifySame(path string, want []byte) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	got, err := io.ReadAll(f)
	if err != nil {
		return err
	}
	if len(got) != len(want) {
		return fmt.Errorf("copy of %s has %d bytes, expected %d", filepath.Base(path), len(got), len(want))
	}
	for i := range got {
		if got[i] != want[i] {
			return fmt.Errorf("copy of %s differs at byte %d", filepath.Base(path), i)
		}
	}
	return nil
}
