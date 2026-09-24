// Package obsolete removes files that earlier USOS experiments left on the
// ESP and that nothing uses any more. Only the exact files on the explicit
// allow-list below are removed: a file is deleted when its path AND its
// SHA-256 match an entry. Anything else (an unknown file, or a known path
// with different content) is left untouched and reported.
package obsolete

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// File is one known obsolete file, relative to the volume root.
type File struct {
	Path   string // slash-separated, e.g. "EFI/BOOT/csmwrap.ini"
	SHA256 string // lowercase hex of the exact known content
	Reason string
}

// ESPFiles are the leftovers of the CSMWrap trial (docs/csmwrap-trial-2026-09-20.md,
// tools/deploy_csmwrap_trial.ps1). Since the Secure Boot layout, EFI\BOOT holds
// shim/grubx64/mmx64 only; the XP UEFI-CSM path uses the firmware's CSM and never
// CSMWrap, and no USOS component, loader entry or XP package references these.
var ESPFiles = []File{
	{
		Path:   "EFI/BOOT/USOS-original.efi",
		SHA256: "3008d265b13343fc694bd6fff3985b1d67884a79c684472be39a767f8f2a5b5d",
		Reason: "pre-CSMWrap-trial USOS backup (2026-09-20)",
	},
	{
		Path:   "EFI/BOOT/csmwrap.ini",
		SHA256: "2dbd22de86e527ad535ce4536f7e369a35896876e12ebdd29a4dcea75f0f6605",
		Reason: "CSMWrap trial configuration beside BOOTX64.EFI (2026-09-20)",
	},
}

type Action string

const (
	ActionRemoved Action = "removed"
	ActionAbsent  Action = "absent"
	// ActionKept: the path exists but its content is not the known obsolete
	// file (or it is not a regular file), so it is never removed.
	ActionKept Action = "kept-unknown-content"
)

type Result struct {
	Path   string
	Action Action
	SHA256 string
	Reason string
}

func (r Result) String() string {
	if r.Action == ActionAbsent {
		return fmt.Sprintf("OBSOLETE_ESP %s path=%s", r.Action, r.Path)
	}
	return fmt.Sprintf("OBSOLETE_ESP %s path=%s sha256=%s reason=%q", r.Action, r.Path, r.SHA256, r.Reason)
}

// RemoveKnown removes the files of `files` found under root whose content
// matches exactly. It returns one result per entry; an error stops at the
// first file that could not be read or removed.
func RemoveKnown(root string, files []File) ([]Result, error) {
	if strings.TrimSpace(root) == "" {
		return nil, fmt.Errorf("volume root is empty")
	}
	results := make([]Result, 0, len(files))
	for _, file := range files {
		if file.Path == "" || strings.Contains(file.Path, "..") || strings.HasPrefix(file.Path, "/") || len(file.SHA256) != 64 {
			return results, fmt.Errorf("invalid obsolete-file entry %q", file.Path)
		}
		path := filepath.Join(root, filepath.FromSlash(file.Path))
		info, err := os.Lstat(path)
		if os.IsNotExist(err) {
			results = append(results, Result{Path: file.Path, Action: ActionAbsent, Reason: file.Reason})
			continue
		}
		if err != nil {
			return results, fmt.Errorf("stat %s: %w", file.Path, err)
		}
		if !info.Mode().IsRegular() {
			results = append(results, Result{Path: file.Path, Action: ActionKept, SHA256: "not-a-regular-file", Reason: file.Reason})
			continue
		}
		actual, err := hashFile(path)
		if err != nil {
			return results, fmt.Errorf("hash %s: %w", file.Path, err)
		}
		if actual != strings.ToLower(file.SHA256) {
			results = append(results, Result{Path: file.Path, Action: ActionKept, SHA256: actual, Reason: file.Reason})
			continue
		}
		if err := os.Remove(path); err != nil {
			return results, fmt.Errorf("remove %s: %w", file.Path, err)
		}
		if _, err := os.Lstat(path); !os.IsNotExist(err) {
			return results, fmt.Errorf("%s still present after removal", file.Path)
		}
		results = append(results, Result{Path: file.Path, Action: ActionRemoved, SHA256: actual, Reason: file.Reason})
	}
	return results, nil
}

func hashFile(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}
