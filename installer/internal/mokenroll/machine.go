package mokenroll

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// Whether the USOS key is on this computer cannot be read from Windows:
// MokList is boot-services only, and MokListRT exists only on boots that
// went through shim. So the installer combines three sources:
//
//   - MokListRT, when Windows happens to have been started through shim;
//   - the report USOS writes on the drive at every UEFI start,
//     EFI\USOS\Logs\secure-boot-<SMBIOS UUID>.ini (usos_key=saved|missing),
//     matched by this computer's SMBIOS system UUID;
//   - a local marker %APPDATA%\USOS\mok-enrolled-<UUID>, written when one of
//     the above confirmed the key or when the user clicked "Already done".

// ParseSMBIOSUUID returns the SMBIOS type 1 system UUID from the raw table
// GetSystemFirmwareTable('RSMB') returns (an 8-byte RawSMBIOSData header,
// then the structure table), formatted like Win32_ComputerSystemProduct and
// USOS (src/gui/handheld.zig formatUuid): upper case, first three fields
// little-endian. ok is false when there is no type 1 structure or the UUID
// is unset (all 0x00 or all 0xFF).
func ParseSMBIOSUUID(raw []byte) (string, bool) {
	if len(raw) < 8 {
		return "", false
	}
	length := int(binary.LittleEndian.Uint32(raw[4:8]))
	table := raw[8:]
	if length < len(table) {
		table = table[:length]
	}
	for offset, guard := 0, 0; offset+4 <= len(table) && guard < 1024; guard++ {
		kind, size := table[offset], int(table[offset+1])
		if size < 4 || offset+size > len(table) {
			return "", false
		}
		if kind == 1 && size >= 0x18 {
			return FormatSMBIOSUUID(table[offset+8 : offset+24])
		}
		if kind == 127 {
			return "", false
		}
		end := offset + size
		for end+1 < len(table) && !(table[end] == 0 && table[end+1] == 0) {
			end++
		}
		offset = end + 2
	}
	return "", false
}

// FormatSMBIOSUUID formats 16 UUID bytes as stored in SMBIOS 2.6+.
func FormatSMBIOSUUID(b []byte) (string, bool) {
	if len(b) != 16 {
		return "", false
	}
	zero, ones := true, true
	for _, v := range b {
		zero = zero && v == 0
		ones = ones && v == 0xff
	}
	if zero || ones {
		return "", false
	}
	return fmt.Sprintf("%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
		b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]), true
}

// Report is one EFI\USOS\Logs\secure-boot-<UUID>.ini written by USOS.
type Report struct {
	MachineUUID string
	SecureBoot  string // on, off, setup_mode, unsupported
	Key         string // saved, missing, unknown
}

// ReportFileName is the per-machine report name on the drive.
func ReportFileName(machineUUID string) string {
	return "secure-boot-" + strings.ToUpper(machineUUID) + ".ini"
}

// ParseReport reads key=value lines (";" comments).
func ParseReport(r io.Reader) (Report, error) {
	var rep Report
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, ";") || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch strings.ToLower(strings.TrimSpace(key)) {
		case "machine_uuid":
			rep.MachineUUID = strings.ToUpper(strings.TrimSpace(value))
		case "secure_boot":
			rep.SecureBoot = strings.TrimSpace(value)
		case "usos_key":
			rep.Key = strings.TrimSpace(value)
		}
	}
	return rep, scanner.Err()
}

// ReadReport reads the report for machineUUID from a USOS ESP root (a
// drive letter or \\?\Volume{...}\ path). ok is false when there is none.
func ReadReport(espRoot, machineUUID string) (Report, bool) {
	if machineUUID == "" || espRoot == "" {
		return Report{}, false
	}
	f, err := os.Open(filepath.Join(espRoot, "EFI", "USOS", "Logs", ReportFileName(machineUUID)))
	if err != nil {
		return Report{}, false
	}
	defer f.Close()
	rep, err := ParseReport(f)
	if err != nil || !strings.EqualFold(rep.MachineUUID, machineUUID) {
		return Report{}, false
	}
	return rep, true
}

// MarkerPath is %APPDATA%\USOS\mok-enrolled-<UUID> under dir (the USOS
// application data directory).
func MarkerPath(dir, machineUUID string) string {
	return filepath.Join(dir, "mok-enrolled-"+strings.ToUpper(machineUUID))
}

// HasMarker reports whether the enrolled marker exists.
func HasMarker(dir, machineUUID string) bool {
	if dir == "" || machineUUID == "" {
		return false
	}
	_, err := os.Stat(MarkerPath(dir, machineUUID))
	return err == nil
}

// WriteMarker records that the USOS key is on this computer; source says
// how it was confirmed ("MokListRT", "drive report", "user").
func WriteMarker(dir, machineUUID, source string) error {
	if dir == "" || machineUUID == "" {
		return fmt.Errorf("no application data directory or machine UUID")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	return os.WriteFile(MarkerPath(dir, machineUUID), []byte("confirmed_by="+source+"\r\n"), 0o644)
}

// Card is what the installer shows about Secure Boot on this computer.
type Card int

const (
	// CardNone: nothing to do (legacy BIOS, Secure Boot off or unknown,
	// or the key is known to be here).
	CardNone Card = iota
	// CardNeeded: Secure Boot is on and the key is not known to be here.
	CardNeeded
	// CardPrepared: like CardNeeded, but MokTimeout is already set.
	CardPrepared
)

// Assessment combines the firmware state with the other sources.
type Assessment struct {
	Card Card
	// Enrolled is true when a source confirmed the key on this computer.
	Enrolled bool
	// ConfirmedBy names the source that confirmed it.
	ConfirmedBy string
}

// Assess decides the home-screen card. reports are the drive reports
// already matched to this computer's UUID.
func Assess(st Status, waitPending, marker bool, reports []Report) Assessment {
	var a Assessment
	switch {
	case st.Enrolled == Yes:
		a.Enrolled, a.ConfirmedBy = true, "MokListRT"
	case marker:
		a.Enrolled, a.ConfirmedBy = true, "marker"
	default:
		for _, r := range reports {
			if r.Key == "saved" {
				a.Enrolled, a.ConfirmedBy = true, "drive report"
				break
			}
		}
	}
	if !st.UEFI || st.SecureBoot != Yes || a.Enrolled {
		return a
	}
	a.Card = CardNeeded
	if waitPending {
		a.Card = CardPrepared
	}
	return a
}
