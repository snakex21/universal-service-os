//go:build windows

package winhost

import (
	"os"
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
)

func TestEnumeratorCurrentHost(t *testing.T) {
	if os.Getenv("USOS_HOST_INTEGRATION") != "1" {
		t.Skip("set USOS_HOST_INTEGRATION=1 to run read-only Windows host enumeration")
	}

	disks, err := (Enumerator{}).ListDisks()
	if err != nil {
		t.Fatalf("ListDisks: %v", err)
	}
	if len(disks) == 0 {
		t.Fatal("ListDisks returned no physical disks")
	}
	for _, disk := range disks {
		row := domain.BuildDeviceRow(disk)
		t.Logf("disk=%d model=%q serial=%q capacity=%q size=%d sector=%d removable=%v system=%v eligible=%v reason=%q letters=%q labels=%q filesystems=%q used=%q roots=%q", disk.Number, row.Model, disk.Serial, row.Capacity, disk.SizeBytes, disk.SectorBytes, disk.Removable, disk.SystemDisk, disk.Eligible, disk.Reason, row.Letters, row.Labels, row.FileSystems, row.Used, row.RootContents)
	}
}
