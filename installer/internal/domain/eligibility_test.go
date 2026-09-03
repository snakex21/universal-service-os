package domain

import (
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/layout"
)

func testDisk() Disk {
	return Disk{
		Model:       "Test USB Device",
		Serial:      "SERIAL-123",
		Removable:   true,
		SizeBytes:   64 * layout.GiB,
		SectorBytes: 512,
	}
}

func TestEligibility(t *testing.T) {
	tests := []struct {
		name string
		edit func(*Disk)
		want bool
	}{
		{"eligible removable disk", func(*Disk) {}, true},
		{"reject fixed disk", func(d *Disk) { d.Removable = false }, false},
		{"reject system disk", func(d *Disk) { d.SystemDisk = true }, false},
		{"reject undersized disk", func(d *Disk) { d.SizeBytes = 31 * layout.GiB }, false},
		{"reject missing model", func(d *Disk) { d.Model = "" }, false},
		{"reject missing serial", func(d *Disk) { d.Serial = "" }, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			disk := testDisk()
			tt.edit(&disk)
			got := ApplyEligibility(disk)
			if got.Eligible != tt.want {
				t.Fatalf("Eligible=%v reason=%q, want %v", got.Eligible, got.Reason, tt.want)
			}
		})
	}
}
