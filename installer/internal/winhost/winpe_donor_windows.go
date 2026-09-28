//go:build windows

package winhost

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"golang.org/x/sys/windows"
)

// The PE10 donor ISO (a Windows 10 2004..21H2 x64 WinPE with Setup, e.g.
// PE10_x64_19041_USOS.iso) boots Vista and original Windows 7 in UEFI mode
// (src/windows7_iso.zig). It is USOS-managed, not a system to install, so it
// lives in DATA\Programs\USOS\WinPE (never listed in the menu) instead of
// Systems\Windows\Windows 10\Images, where it used to sit.
//
// Install/update/repair:
//   - move a donor found in the legacy folder into the managed one (a rename
//     on the same NTFS volume; SHA-256 checked before and after);
//   - record name, size and SHA-256 in ESP\EFI\USOS\winpe-donor.ini (the
//     UEFI menu checks the donor against it before Vista/7 use it);
//   - mark the folder Hidden+System and the ISO Hidden+System+Read-only, so
//     Explorer hides them and warns before deleting. No ACL deny rules.
var (
	winpeDonorDir       = filepath.Join("Programs", "USOS", "WinPE")
	legacyWinpeDonorDir = filepath.Join("Systems", "Windows", "Windows 10", "Images")
	winpeDonorName      = regexp.MustCompile(`(?i)^PE10_.*_USOS\.iso$`)
)

const winpeDonorRecord = "EFI/USOS/winpe-donor.ini"

// winpeDonorState is what install/update/repair found and did.
type winpeDonorState struct {
	Name       string // donor file name, empty when there is none
	Size       int64
	SHA256     string
	MovedFrom  string // legacy path the donor was moved from (this run)
	Recorded   string // SHA-256 in winpe-donor.ini before this run
	Corrupt    bool   // file differs from the recorded SHA-256
	Ambiguous  bool   // more than one ISO in the managed folder
	RecordPath string
}

type winpeRecord struct {
	name   string
	size   int64
	sha256 string
}

func readWinpeRecord(path string) (winpeRecord, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return winpeRecord{}, false
	}
	var record winpeRecord
	for _, line := range strings.Split(strings.ReplaceAll(string(data), "\r", ""), "\n") {
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch strings.ToLower(strings.TrimSpace(key)) {
		case "name":
			record.name = strings.TrimSpace(value)
		case "size":
			record.size, _ = strconv.ParseInt(strings.TrimSpace(value), 10, 64)
		case "sha256":
			record.sha256 = strings.ToLower(strings.TrimSpace(value))
		}
	}
	if record.name == "" || record.size <= 0 || len(record.sha256) != 64 {
		return winpeRecord{}, false
	}
	return record, true
}

func winpeRecordText(name string, size int64, sha string) []byte {
	return []byte(fmt.Sprintf("; USOS-managed PE10 donor for Vista / Windows 7 (DATA\\Programs\\USOS\\WinPE). Do not edit.\r\nname=%s\r\nsize=%d\r\nsha256=%s\r\n", name, size, strings.ToLower(sha)))
}

// setManagedAttributes sets FILE_ATTRIBUTE_HIDDEN|SYSTEM (and READONLY) and
// keeps every other attribute bit.
func setManagedAttributes(path string, readOnly bool) error {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	current, err := windows.GetFileAttributes(name)
	if err != nil {
		return err
	}
	wanted := current | windows.FILE_ATTRIBUTE_HIDDEN | windows.FILE_ATTRIBUTE_SYSTEM
	if readOnly {
		wanted |= windows.FILE_ATTRIBUTE_READONLY
	}
	wanted &^= windows.FILE_ATTRIBUTE_NORMAL
	if wanted == current {
		return nil
	}
	return windows.SetFileAttributes(name, wanted)
}

// clearProtection drops READONLY|HIDDEN|SYSTEM so the file can be renamed.
func clearProtection(path string) error {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	current, err := windows.GetFileAttributes(name)
	if err != nil {
		return err
	}
	cleared := current &^ (windows.FILE_ATTRIBUTE_READONLY | windows.FILE_ATTRIBUTE_HIDDEN | windows.FILE_ATTRIBUTE_SYSTEM)
	if cleared == 0 {
		cleared = windows.FILE_ATTRIBUTE_NORMAL
	}
	if cleared == current {
		return nil
	}
	return windows.SetFileAttributes(name, cleared)
}

func isoFiles(dir string) []os.DirEntry {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var result []os.DirEntry
	for _, entry := range entries {
		if !entry.IsDir() && strings.EqualFold(filepath.Ext(entry.Name()), ".iso") {
			result = append(result, entry)
		}
	}
	return result
}

// ensureWinpeDonor runs on install and update (CopyInstallPayload) and on
// repair (RecordWinpeDonor).
// It never deletes a donor and never overwrites a record that disagrees with
// the file: a corrupt donor stays visible to the menu and to verification.
func ensureWinpeDonor(dataRoot, espRoot string) (winpeDonorState, error) {
	state := winpeDonorState{RecordPath: filepath.Join(espRoot, filepath.FromSlash(winpeDonorRecord))}
	managed := filepath.Join(dataRoot, winpeDonorDir)
	if err := os.MkdirAll(managed, 0o755); err != nil {
		return state, fmt.Errorf("create %s: %w", winpeDonorDir, err)
	}
	record, haveRecord := readWinpeRecord(state.RecordPath)
	if haveRecord {
		state.Recorded = record.sha256
	}
	files := isoFiles(managed)
	if len(files) == 0 {
		legacy := filepath.Join(dataRoot, legacyWinpeDonorDir)
		var candidates []os.DirEntry
		for _, entry := range isoFiles(legacy) {
			if winpeDonorName.MatchString(entry.Name()) {
				candidates = append(candidates, entry)
			}
		}
		if len(candidates) == 1 {
			source := filepath.Join(legacy, candidates[0].Name())
			destination := filepath.Join(managed, candidates[0].Name())
			before, err := hashFileSHA256(source)
			if err != nil {
				return state, fmt.Errorf("hash donor before move: %w", err)
			}
			if err := clearProtection(source); err != nil {
				return state, fmt.Errorf("clear donor attributes: %w", err)
			}
			// Same NTFS volume: a rename, no data is copied.
			if err := os.Rename(source, destination); err != nil {
				return state, fmt.Errorf("move donor to %s: %w", winpeDonorDir, err)
			}
			after, err := hashFileSHA256(destination)
			if err != nil {
				return state, fmt.Errorf("hash donor after move: %w", err)
			}
			if after != before {
				return state, fmt.Errorf("donor SHA-256 changed during the move: before=%s after=%s", before, after)
			}
			state.MovedFrom = filepath.Join(legacyWinpeDonorDir, candidates[0].Name())
			fmt.Printf("[DONOR] moved %s -> %s (rename on DATA), SHA-256 %s verified after the move\n", state.MovedFrom, filepath.Join(winpeDonorDir, candidates[0].Name()), after)
			files = isoFiles(managed)
		}
	}
	if len(files) == 0 {
		if err := setManagedAttributes(managed, false); err != nil {
			return state, fmt.Errorf("mark %s: %w", winpeDonorDir, err)
		}
		return state, nil
	}
	if len(files) > 1 {
		state.Ambiguous = true
		return state, nil
	}
	path := filepath.Join(managed, files[0].Name())
	info, err := os.Stat(path)
	if err != nil {
		return state, err
	}
	sha, err := hashFileSHA256(path)
	if err != nil {
		return state, fmt.Errorf("hash donor: %w", err)
	}
	state.Name, state.Size, state.SHA256 = files[0].Name(), info.Size(), sha
	if haveRecord && strings.EqualFold(record.name, state.Name) && (record.size != state.Size || record.sha256 != strings.ToLower(sha)) {
		state.Corrupt = true
		fmt.Printf("[DONOR] %s differs from winpe-donor.ini (recorded %s, file %s); record kept, Vista/7 stay blocked until Repair\n", state.Name, record.sha256, sha)
	} else if !haveRecord || !strings.EqualFold(record.name, state.Name) {
		if err := writeFileSync(state.RecordPath, winpeRecordText(state.Name, state.Size, sha)); err != nil {
			return state, fmt.Errorf("write %s: %w", winpeDonorRecord, err)
		}
		fmt.Printf("[DONOR] recorded %s size=%d sha256=%s\n", state.Name, state.Size, sha)
	}
	if err := setManagedAttributes(path, true); err != nil {
		return state, fmt.Errorf("mark donor: %w", err)
	}
	if err := setManagedAttributes(managed, false); err != nil {
		return state, fmt.Errorf("mark %s: %w", winpeDonorDir, err)
	}
	return state, nil
}

// verifyWinpeDonor is the installer's verification of the donor against its
// record. No donor and no record is fine (only Vista/7 need one).
func verifyWinpeDonor(dataRoot, espRoot string) (string, bool) {
	record, haveRecord := readWinpeRecord(filepath.Join(espRoot, filepath.FromSlash(winpeDonorRecord)))
	files := isoFiles(filepath.Join(dataRoot, winpeDonorDir))
	if len(files) == 0 {
		if haveRecord {
			return "brak " + record.name + " w Programs\\USOS\\WinPE (zapisany w winpe-donor.ini); Vista/Windows 7 w UEFI potrzebują go", false
		}
		return "brak (potrzebny tylko dla Visty/Windows 7 w UEFI)", true
	}
	if len(files) > 1 {
		return "więcej niż jeden plik ISO w Programs\\USOS\\WinPE", false
	}
	path := filepath.Join(dataRoot, winpeDonorDir, files[0].Name())
	sha, err := hashFileSHA256(path)
	if err != nil {
		return err.Error(), false
	}
	if !haveRecord {
		return files[0].Name() + " (bez zapisu winpe-donor.ini)", false
	}
	if !strings.EqualFold(record.name, files[0].Name()) || record.sha256 != strings.ToLower(sha) {
		return files[0].Name() + " SHA-256 " + sha + " różni się od zapisanego " + record.sha256, false
	}
	return files[0].Name() + " SHA-256 " + sha, true
}

// RecordWinpeDonor is the repair step for the PE10 donor: the same
// ensureWinpeDonor as install and update, so Repair (which rewrites only the
// ESP payload) also records a donor copied to DATA\Programs\USOS\WinPE.
func (b Backend) RecordWinpeDonor(media install.MediaLayout) (string, error) {
	resolved, err := resolveFormattedMedia(media, 10*time.Second)
	if err != nil {
		return "", fmt.Errorf("resolve media for the WinPE donor: %w", err)
	}
	state, err := ensureWinpeDonor(resolved.DATA.VolumePath, resolved.ESP.VolumePath)
	return state.logLine(), err
}

// logLine describes the donor state for the operation log.
func (s winpeDonorState) logLine() string {
	switch {
	case s.Ambiguous:
		return "ambiguous: more than one ISO in " + winpeDonorDir
	case s.Name == "":
		return "none in " + winpeDonorDir
	case s.Corrupt:
		return s.Name + " SHA-256 " + s.SHA256 + " differs from the record " + s.Recorded + " (record kept)"
	}
	line := s.Name + " SHA-256 " + s.SHA256 + " recorded in " + winpeDonorRecord
	if s.MovedFrom != "" {
		line += " (moved from " + s.MovedFrom + ")"
	}
	return line
}
