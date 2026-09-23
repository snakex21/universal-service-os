// Package workboot keeps the UEFI removable-media path
// \EFI\BOOT\BOOT{X64,IA32,AA64,ARM}.EFI off every USOS partition except the ESP.
//
// Firmware such as AMI Aptio lists each partition that carries
// \EFI\BOOT\BOOTX64.EFI as a separate "UEFI: <disk>, Partition N" boot option.
// WORK therefore keeps its prepared boot chain under \EFI\USOS-WORK\; USOS
// chainloads it from there and falls back to \EFI\BOOT for one release.
// Preparation in micro-Linux uses tools/work_boot_relocate.sh; this package is
// the same policy for the Windows update/repair path, which migrates WORK
// volumes prepared by older builds.
package workboot

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// Dir is the WORK boot chain directory below \EFI.
const Dir = "USOS-WORK"

// Action describes what Migrate did.
type Action string

const (
	ActionNone   Action = "none"   // no \EFI\BOOT removable entry on the volume
	ActionRename Action = "rename" // \EFI\BOOT renamed to \EFI\USOS-WORK
	ActionMerge  Action = "merge"  // \EFI\BOOT merged into an existing \EFI\USOS-WORK, then removed
	ActionSplit  Action = "split"  // copied to \EFI\USOS-WORK; only entry binaries removed from \EFI\BOOT
)

type Migration struct {
	Action Action
	From   string
	To     string
}

func (m Migration) String() string {
	if m.Action == ActionNone {
		return "action=none"
	}
	return fmt.Sprintf("action=%s from=%s to=%s", m.Action, m.From, m.To)
}

// IsEntryName reports whether name is a UEFI removable-media entry binary.
func IsEntryName(name string) bool {
	switch strings.ToLower(name) {
	case "bootx64.efi", "bootia32.efi", "bootaa64.efi", "bootarm.efi":
		return true
	}
	return false
}

func childCI(dir, name string, wantDir bool) (string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", nil
		}
		return "", err
	}
	for _, entry := range entries {
		if entry.IsDir() == wantDir && strings.EqualFold(entry.Name(), name) {
			return filepath.Join(dir, entry.Name()), nil
		}
	}
	return "", nil
}

func entriesIn(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var found []string
	for _, entry := range entries {
		if !entry.IsDir() && IsEntryName(entry.Name()) {
			found = append(found, filepath.Join(dir, entry.Name()))
		}
	}
	return found, nil
}

// RemovableEntries lists \EFI\BOOT\BOOT*.EFI entry binaries on root (any case).
func RemovableEntries(root string) ([]string, error) {
	efi, err := childCI(root, "efi", true)
	if err != nil || efi == "" {
		return nil, err
	}
	boot, err := childCI(efi, "boot", true)
	if err != nil || boot == "" {
		return nil, err
	}
	return entriesIn(boot)
}

// wholeMove: only files, and either all are entry binaries (Windows media) or
// the directory is the USOS Windows 7 chain (win7.original.efi).
func wholeMove(dir string) (bool, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false, err
	}
	allEntries := true
	chain := false
	for _, entry := range entries {
		if entry.IsDir() {
			return false, nil
		}
		if strings.EqualFold(entry.Name(), "win7.original.efi") {
			chain = true
		}
		if !IsEntryName(entry.Name()) {
			allEntries = false
		}
	}
	return chain || allEntries, nil
}

// Migrate moves a WORK \EFI\BOOT chain to \EFI\USOS-WORK (same rules as
// tools/work_boot_relocate.sh). It is idempotent and never deletes a file
// before its copy has been verified.
func Migrate(root string) (Migration, error) {
	efi, err := childCI(root, "efi", true)
	if err != nil {
		return Migration{}, fmt.Errorf("read WORK root: %w", err)
	}
	if efi == "" {
		return Migration{Action: ActionNone}, nil
	}
	boot, err := childCI(efi, "boot", true)
	if err != nil {
		return Migration{}, fmt.Errorf("read WORK EFI directory: %w", err)
	}
	if boot == "" {
		return Migration{Action: ActionNone}, nil
	}
	entries, err := entriesIn(boot)
	if err != nil {
		return Migration{}, fmt.Errorf("read WORK EFI/BOOT: %w", err)
	}
	if len(entries) == 0 {
		return Migration{Action: ActionNone}, nil
	}
	whole, err := wholeMove(boot)
	if err != nil {
		return Migration{}, err
	}
	target, err := childCI(efi, Dir, true)
	if err != nil {
		return Migration{}, err
	}
	if whole && target == "" {
		target = filepath.Join(efi, Dir)
		if err := os.Rename(boot, target); err != nil {
			return Migration{}, fmt.Errorf("rename %s to %s: %w", boot, target, err)
		}
		return Migration{Action: ActionRename, From: boot, To: target}, nil
	}
	if target == "" {
		target = filepath.Join(efi, Dir)
		if err := os.Mkdir(target, 0o755); err != nil {
			return Migration{}, fmt.Errorf("create %s: %w", target, err)
		}
	}
	if err := copyTreeNoClobber(boot, target); err != nil {
		return Migration{}, err
	}
	if whole {
		if err := os.RemoveAll(boot); err != nil {
			return Migration{}, fmt.Errorf("remove %s after merge: %w", boot, err)
		}
		return Migration{Action: ActionMerge, From: boot, To: target}, nil
	}
	for _, entry := range entries {
		copyPath, err := childCI(target, filepath.Base(entry), false)
		if err != nil {
			return Migration{}, err
		}
		if copyPath == "" {
			return Migration{}, fmt.Errorf("%s has no copy in %s", entry, target)
		}
		if info, err := os.Stat(copyPath); err != nil || info.Size() == 0 {
			return Migration{}, fmt.Errorf("copy of %s is missing or empty: %v", entry, err)
		}
		if err := os.Remove(entry); err != nil {
			return Migration{}, fmt.Errorf("remove %s: %w", entry, err)
		}
	}
	return Migration{Action: ActionSplit, From: boot, To: target}, nil
}

func copyTreeNoClobber(src, dst string) error {
	return filepath.WalkDir(src, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if entry.IsDir() {
			if err := os.MkdirAll(target, 0o755); err != nil {
				return fmt.Errorf("create %s: %w", target, err)
			}
			return nil
		}
		if _, err := os.Stat(target); err == nil {
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return copyFileVerified(path, target)
	})
}

func copyFileVerified(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return fmt.Errorf("read %s: %w", src, err)
	}
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return fmt.Errorf("create %s: %w", dst, err)
	}
	if _, err := out.Write(data); err != nil {
		out.Close()
		return fmt.Errorf("write %s: %w", dst, err)
	}
	if err := out.Sync(); err != nil {
		out.Close()
		return fmt.Errorf("flush %s: %w", dst, err)
	}
	if err := out.Close(); err != nil {
		return fmt.Errorf("close %s: %w", dst, err)
	}
	in, err := os.Open(dst)
	if err != nil {
		return err
	}
	defer in.Close()
	readBack, err := io.ReadAll(in)
	if err != nil {
		return fmt.Errorf("read back %s: %w", dst, err)
	}
	if string(readBack) != string(data) {
		return fmt.Errorf("read-back mismatch for %s", dst)
	}
	return nil
}
