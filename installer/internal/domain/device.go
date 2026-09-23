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
	// BusType is STORAGE_DEVICE_DESCRIPTOR.BusType (informational only; it
	// plays no part in eligibility).
	BusType         uint32
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

// Storage bus types reported by IOCTL_STORAGE_QUERY_PROPERTY.
const (
	BusUSB  = 7
	BusNVMe = 17
)

var busNames = map[uint32]string{
	1: "SCSI", 2: "ATAPI", 3: "ATA", 4: "IEEE 1394", 5: "SSA", 6: "Fibre Channel",
	7: "USB", 8: "RAID", 9: "iSCSI", 10: "SAS", 11: "SATA", 12: "SD", 13: "MMC",
	14: "Virtual", 15: "File-backed virtual", 16: "Storage Spaces", 17: "NVMe",
	18: "SCM", 19: "UFS",
}

// BusName returns the bus name, or "" when the bus type is unknown.
func (d Disk) BusName() string { return busNames[d.BusType] }
