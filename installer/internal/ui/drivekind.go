package ui

import "github.com/snakex21/universal-service-os/installer/internal/domain"

// driveKind selects the icon of a drive in the lists and details panels.
type driveKind int

const (
	driveFixed     driveKind = iota // internal disk: shell fixed-disk icon
	driveRemovable                  // removable media on another bus (SD/MMC reader): shell removable icon
	driveUSBStick                   // USB flash drive: drawn pendrive glyph
	driveExternal                   // USB-attached HDD/SSD: drawn external-drive glyph
)

// classifyDrive: a USB stick is a USB device that reports RemovableMedia; a
// USB device without it is an external HDD/SSD. Everything else keeps the
// shell's fixed or removable icon.
func classifyDrive(d domain.Disk) driveKind {
	switch {
	case d.BusType == domain.BusUSB && d.Removable:
		return driveUSBStick
	case d.BusType == domain.BusUSB:
		return driveExternal
	case d.Removable:
		return driveRemovable
	default:
		return driveFixed
	}
}
