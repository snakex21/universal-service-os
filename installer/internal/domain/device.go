package domain

import (
	"fmt"
	"strings"
	"unicode"
)

type Volume struct {
	GUIDPath      string
	MountPaths    []string
	Label         string
	FileSystem    string
	UsedBytes     uint64
	TotalBytes    uint64
	RootEntries   []string
	RootScanError string
}

type Disk struct {
	Number          uint32
	Model           string
	Vendor          string
	Product         string
	Serial          string
	SizeBytes       uint64
	SectorBytes     uint32
	Removable       bool
	SystemDisk      bool
	SpannedVolume   bool
	Eligible        bool
	Reason          string
	InspectionError string
	Volumes         []Volume
}

type Identity struct {
	Number      uint32
	Model       string
	Serial      string
	SizeBytes   uint64
	SectorBytes uint32
}

func (d Disk) Identity() Identity {
	return Identity{
		Number:      d.Number,
		Model:       strings.TrimSpace(d.Model),
		Serial:      strings.TrimSpace(d.Serial),
		SizeBytes:   d.SizeBytes,
		SectorBytes: d.SectorBytes,
	}
}

func (i Identity) MatchesApprovedHardware(other Identity) bool {
	return i.Model == other.Model &&
		i.Serial == other.Serial &&
		i.SizeBytes == other.SizeBytes
}

func (d Disk) DisplayName() string {
	name := cleanDisplayToken(d.Model)
	if name == "" {
		name = fmt.Sprintf("PhysicalDrive%d", d.Number)
	}
	return name
}

func (d Disk) DisplaySerial() string {
	s := strings.TrimSpace(d.Serial)
	s = strings.Map(func(r rune) rune {
		if r == '\r' || r == '\n' || r == '\t' {
			return -1
		}
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, s)
	s = strings.TrimSpace(s)
	if len([]rune(s)) > 64 {
		s = string([]rune(s)[:64])
		s = strings.TrimSpace(s)
	}
	return s
}

func cleanDisplayToken(s string) string {
	filtered := strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' || r == '\t' {
			return ' '
		}
		if unicode.IsLetter(r) || unicode.IsNumber(r) || r == ' ' || r == '-' || r == '_' || r == '.' || r == '/' || r == '(' || r == ')' {
			return r
		}
		return -1
	}, strings.TrimSpace(s))
	return strings.Join(strings.Fields(filtered), " ")
}

func (d Disk) ConfirmationValue() string {
	return d.DisplayName()
}
