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

	"github.com/snakex21/universal-service-os/installer/internal/components"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"golang.org/x/sys/windows"
)

// The PE10 donors are USOS-managed helper images, not systems to install, so
// they live in DATA\Programs\USOS\WinPE (never listed in the menu) instead of
// Systems\Windows\Windows 10\Images, where the x64 one used to sit:
//
//   - x64 (e.g. PE10_x64_19041_USOS.iso, a Windows 10 2004..21H2 x64 WinPE
//     with Setup) boots Vista and original Windows 7 in UEFI mode
//     (src/windows7_iso.zig resolveDonor);
//   - x86 (PE10_x86_19041_USOS.iso, shipped since 2026-10-20) boots 32-bit
//     Windows 7 / Vista / 2008 on UEFI without CSM through CSMWrap
//     (resolveX86Donor; a user's own Windows 10 x86 ISO in Windows 10\Images
//     stays the fallback there).
//
// One donor per architecture; the file name tells them apart
// (components.IsX86DonorName), the UEFI menu checks the boot.wim metadata.
//
// Install/update/repair, for each architecture:
//   - move a donor found in the legacy folder into the managed one (a rename
//     on the same NTFS volume; SHA-256 checked before and after);
//   - record name, size and SHA-256 in ESP\EFI\USOS\winpe-donor.ini
//     (x64: name=/size=/sha256=, as before; x86: x86_name=/x86_size=/
//     x86_sha256=, which older readers ignore); the UEFI menu checks the
//     donor against it before use;
//   - mark the folder Hidden+System and the ISO Hidden+System+Read-only, so
//     Explorer hides them and warns before deleting. No ACL deny rules.
var (
	winpeDonorDir       = filepath.Join("Programs", "USOS", "WinPE")
	legacyWinpeDonorDir = filepath.Join("Systems", "Windows", "Windows 10", "Images")
	winpeDonorName      = regexp.MustCompile(`(?i)^PE10_.*_USOS\.iso$`)
)

const winpeDonorRecord = "EFI/USOS/winpe-donor.ini"

// donorArch is "x64" or "x86".
type donorArch string

const (
	archX64 donorArch = "x64"
	archX86 donorArch = "x86"
)

func (a donorArch) owns(name string) bool { return components.IsX86DonorName(name) == (a == archX86) }

// keyPrefix of the arch's lines in winpe-donor.ini.
func (a donorArch) keyPrefix() string {
	if a == archX86 {
		return "x86_"
	}
	return ""
}

// winpeDonorSlot is what install/update/repair found and did for one donor.
type winpeDonorSlot struct {
	Name      string // donor file name, empty when there is none
	Size      int64
	SHA256    string
	MovedFrom string // legacy path the donor was moved from (this run)
	Recorded  string // SHA-256 in winpe-donor.ini before this run
	Corrupt   bool   // file differs from the recorded SHA-256
	Ambiguous bool   // more than one ISO of this architecture in the managed folder
}

// winpeDonorState: the x64 donor (embedded, as before the x86 donor) and the
// x86 donor.
type winpeDonorState struct {
	winpeDonorSlot
	X86        winpeDonorSlot
	RecordPath string
}

func (s *winpeDonorState) slot(a donorArch) *winpeDonorSlot {
	if a == archX86 {
		return &s.X86
	}
	return &s.winpeDonorSlot
}

type winpeRecord struct {
	name   string
	size   int64
	sha256 string
}

func (r winpeRecord) valid() bool { return r.name != "" && r.size > 0 && len(r.sha256) == 64 }

// winpeRecords is the whole winpe-donor.ini.
type winpeRecords map[donorArch]winpeRecord

func readWinpeRecords(path string) winpeRecords {
	records := winpeRecords{}
	data, err := os.ReadFile(path)
	if err != nil {
		return records
	}
	for _, arch := range []donorArch{archX64, archX86} {
		var record winpeRecord
		for _, line := range strings.Split(strings.ReplaceAll(string(data), "\r", ""), "\n") {
			key, value, ok := strings.Cut(line, "=")
			if !ok {
				continue
			}
			value = strings.TrimSpace(value)
			switch strings.ToLower(strings.TrimSpace(key)) {
			case arch.keyPrefix() + "name":
				record.name = value
			case arch.keyPrefix() + "size":
				record.size, _ = strconv.ParseInt(value, 10, 64)
			case arch.keyPrefix() + "sha256":
				record.sha256 = strings.ToLower(value)
			}
		}
		if record.valid() {
			records[arch] = record
		}
	}
	return records
}

// readWinpeRecord is the x64 record.
func readWinpeRecord(path string) (winpeRecord, bool) {
	record, ok := readWinpeRecords(path)[archX64]
	return record, ok
}

func winpeRecordsText(records winpeRecords) []byte {
	var b strings.Builder
	b.WriteString("; USOS-managed PE10 donors (DATA\\Programs\\USOS\\WinPE): x64 for Vista / Windows 7, x86_ for 32-bit Windows 7 / Vista / 2008 without CSM. Do not edit.\r\n")
	for _, arch := range []donorArch{archX64, archX86} {
		if record, ok := records[arch]; ok {
			p := arch.keyPrefix()
			fmt.Fprintf(&b, "%sname=%s\r\n%ssize=%d\r\n%ssha256=%s\r\n", p, record.name, p, record.size, p, strings.ToLower(record.sha256))
		}
	}
	return []byte(b.String())
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

// archFiles: the ISOs of one architecture in dir.
func archFiles(dir string, arch donorArch) []os.DirEntry {
	var result []os.DirEntry
	for _, entry := range isoFiles(dir) {
		if arch.owns(entry.Name()) {
			result = append(result, entry)
		}
	}
	return result
}

// pickDonor is the managed donor of one architecture. x64 must be the only
// x64 ISO (the menu refuses two valid x64 donors). x86 tolerates other x86
// ISOs (the menu prefers the recorded one) when exactly one carries the
// shipped PE10_x86_*_USOS.iso name.
func pickDonor(files []os.DirEntry, arch donorArch) (os.DirEntry, bool) {
	if len(files) == 1 {
		return files[0], true
	}
	if arch == archX86 {
		var shipped []os.DirEntry
		for _, entry := range files {
			if winpeDonorName.MatchString(entry.Name()) {
				shipped = append(shipped, entry)
			}
		}
		if len(shipped) == 1 {
			return shipped[0], true
		}
	}
	return nil, false
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
	records := readWinpeRecords(state.RecordPath)
	wanted := winpeRecords{}
	for arch, record := range records {
		wanted[arch] = record
	}
	for _, arch := range []donorArch{archX64, archX86} {
		if err := ensureWinpeDonorArch(dataRoot, managed, arch, records, wanted, state.slot(arch)); err != nil {
			return state, err
		}
	}
	if string(winpeRecordsText(wanted)) != string(winpeRecordsText(records)) {
		if err := writeFileSync(state.RecordPath, winpeRecordsText(wanted)); err != nil {
			return state, fmt.Errorf("write %s: %w", winpeDonorRecord, err)
		}
	}
	if err := setManagedAttributes(managed, false); err != nil {
		return state, fmt.Errorf("mark %s: %w", winpeDonorDir, err)
	}
	return state, nil
}

func ensureWinpeDonorArch(dataRoot, managed string, arch donorArch, records, wanted winpeRecords, slot *winpeDonorSlot) error {
	record, haveRecord := records[arch]
	if haveRecord {
		slot.Recorded = record.sha256
	}
	files := archFiles(managed, arch)
	if len(files) == 0 {
		legacy := filepath.Join(dataRoot, legacyWinpeDonorDir)
		var candidates []os.DirEntry
		for _, entry := range archFiles(legacy, arch) {
			if winpeDonorName.MatchString(entry.Name()) {
				candidates = append(candidates, entry)
			}
		}
		if len(candidates) == 1 {
			source := filepath.Join(legacy, candidates[0].Name())
			destination := filepath.Join(managed, candidates[0].Name())
			before, err := hashFileSHA256(source)
			if err != nil {
				return fmt.Errorf("hash %s donor before move: %w", arch, err)
			}
			if err := clearProtection(source); err != nil {
				return fmt.Errorf("clear %s donor attributes: %w", arch, err)
			}
			// Same NTFS volume: a rename, no data is copied.
			if err := os.Rename(source, destination); err != nil {
				return fmt.Errorf("move %s donor to %s: %w", arch, winpeDonorDir, err)
			}
			after, err := hashFileSHA256(destination)
			if err != nil {
				return fmt.Errorf("hash %s donor after move: %w", arch, err)
			}
			if after != before {
				return fmt.Errorf("%s donor SHA-256 changed during the move: before=%s after=%s", arch, before, after)
			}
			slot.MovedFrom = filepath.Join(legacyWinpeDonorDir, candidates[0].Name())
			fmt.Printf("[DONOR] %s: moved %s -> %s (rename on DATA), SHA-256 %s verified after the move\n", arch, slot.MovedFrom, filepath.Join(winpeDonorDir, candidates[0].Name()), after)
			files = archFiles(managed, arch)
		}
	}
	if len(files) == 0 {
		return nil
	}
	donor, ok := pickDonor(files, arch)
	if !ok {
		slot.Ambiguous = true
		return nil
	}
	path := filepath.Join(managed, donor.Name())
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	sha, err := hashFileSHA256(path)
	if err != nil {
		return fmt.Errorf("hash %s donor: %w", arch, err)
	}
	slot.Name, slot.Size, slot.SHA256 = donor.Name(), info.Size(), sha
	if haveRecord && strings.EqualFold(record.name, slot.Name) && (record.size != slot.Size || record.sha256 != strings.ToLower(sha)) {
		slot.Corrupt = true
		fmt.Printf("[DONOR] %s: %s differs from winpe-donor.ini (recorded %s, file %s); record kept, its systems stay blocked until Repair\n", arch, slot.Name, record.sha256, sha)
	} else if !haveRecord || !strings.EqualFold(record.name, slot.Name) {
		wanted[arch] = winpeRecord{name: slot.Name, size: slot.Size, sha256: strings.ToLower(sha)}
		fmt.Printf("[DONOR] %s: recorded %s size=%d sha256=%s\n", arch, slot.Name, slot.Size, sha)
	}
	if err := setManagedAttributes(path, true); err != nil {
		return fmt.Errorf("mark %s donor: %w", arch, err)
	}
	return nil
}

// verifyWinpeDonor is the installer's verification of both donors against
// their records. No donor and no record is fine (only Vista/7 need the x64
// one, only 32-bit 7/Vista/2008 without CSM the x86 one).
func verifyWinpeDonor(dataRoot, espRoot string) (string, bool) {
	records := readWinpeRecords(filepath.Join(espRoot, filepath.FromSlash(winpeDonorRecord)))
	x64, ok64 := verifyWinpeDonorArch(dataRoot, records, archX64)
	x86, ok86 := verifyWinpeDonorArch(dataRoot, records, archX86)
	return "x64: " + x64 + "; x86: " + x86, ok64 && ok86
}

func verifyWinpeDonorArch(dataRoot string, records winpeRecords, arch donorArch) (string, bool) {
	record, haveRecord := records[arch]
	files := archFiles(filepath.Join(dataRoot, winpeDonorDir), arch)
	if len(files) == 0 {
		if haveRecord {
			return "brak " + record.name + " w Programs\\USOS\\WinPE (zapisany w winpe-donor.ini); " + arch.needs() + " potrzebują go", false
		}
		return "brak (potrzebny tylko dla: " + arch.needs() + ")", true
	}
	donor, ok := pickDonor(files, arch)
	if !ok {
		return "więcej niż jeden plik ISO " + string(arch) + " w Programs\\USOS\\WinPE", false
	}
	path := filepath.Join(dataRoot, winpeDonorDir, donor.Name())
	sha, err := hashFileSHA256(path)
	if err != nil {
		return err.Error(), false
	}
	if !haveRecord {
		return donor.Name() + " (bez zapisu winpe-donor.ini)", false
	}
	if !strings.EqualFold(record.name, donor.Name()) || record.sha256 != strings.ToLower(sha) {
		return donor.Name() + " SHA-256 " + sha + " różni się od zapisanego " + record.sha256, false
	}
	return donor.Name() + " SHA-256 " + sha, true
}

// needs: the systems that need the donor (verification text, Polish like the
// rest of the report).
func (a donorArch) needs() string {
	if a == archX86 {
		return "32-bitowe Windows 7/Vista/2008 w UEFI bez CSM"
	}
	return "Vista/Windows 7 w UEFI"
}

// RecordWinpeDonor is the repair step for the PE10 donors: the same
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

// logLine describes both donors for the operation log.
func (s winpeDonorState) logLine() string {
	return s.winpeDonorSlot.logLine(archX64) + "; x86: " + s.X86.logLine(archX86)
}

func (s winpeDonorSlot) logLine(arch donorArch) string {
	switch {
	case s.Ambiguous:
		return "ambiguous: more than one " + string(arch) + " ISO in " + winpeDonorDir
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
