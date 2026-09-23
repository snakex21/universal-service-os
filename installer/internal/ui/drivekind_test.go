package ui

import (
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
)

func TestClassifyDrive(t *testing.T) {
	cases := []struct {
		name string
		disk domain.Disk
		want driveKind
	}{
		{"USB flash drive", domain.Disk{BusType: domain.BusUSB, Removable: true}, driveUSBStick},
		{"USB-attached SSD", domain.Disk{BusType: domain.BusUSB}, driveExternal},
		{"internal NVMe", domain.Disk{BusType: domain.BusNVMe}, driveFixed},
		{"internal SATA", domain.Disk{BusType: 11}, driveFixed},
		{"SD card reader", domain.Disk{BusType: 12, Removable: true}, driveRemovable},
		{"unknown bus", domain.Disk{}, driveFixed},
	}
	for _, c := range cases {
		if got := classifyDrive(c.disk); got != c.want {
			t.Errorf("%s: got %d want %d", c.name, got, c.want)
		}
	}
}
