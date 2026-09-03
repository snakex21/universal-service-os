//go:build windows

package winhost

import (
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/layout"
	"golang.org/x/sys/windows"
)

func TestSetWorkNoDriveLetterPatchesOnlyWorkAttributes(t *testing.T) {
	plan, err := layout.Build(64 * layout.GiB)
	if err != nil {
		t.Fatal(err)
	}
	ids := gptIDs{
		Disk: windows.GUID{Data1: 1},
		ESP:  windows.GUID{Data1: 2},
		DATA: windows.GUID{Data1: 3},
		WORK: windows.GUID{Data1: 4},
	}
	header := gptHeader{DiskID: ids.Disk, StartingUsableOffset: plan.ESP.StartBytes, UsableLength: plan.WORK.StartBytes + plan.WORK.SizeBytes - plan.ESP.StartBytes, MaxPartitionCount: 128}
	raw, err := buildDriveLayoutBuffer(plan, header, ids)
	if err != nil {
		t.Fatal(err)
	}
	before, err := parseDriveLayout(append([]byte(nil), raw...))
	if err != nil {
		t.Fatal(err)
	}
	// Simulate an older USOS medium created before the NoDriveLetter attribute
	// was enforced.
	workOffset := driveLayoutHeaderSize + 2*partitionEntrySize + gptInfoOffset + 32
	for i := 0; i < 8; i++ {
		raw[workOffset+i] = 0
	}
	before, err = parseDriveLayout(append([]byte(nil), raw...))
	if err != nil {
		t.Fatal(err)
	}
	media := install.MediaLayout{
		DiskNumber: 7,
		DiskPTUUID: guidString(ids.Disk),
		WORK: install.PartitionRef{
			StartBytes: plan.WORK.StartBytes,
			SizeBytes:  plan.WORK.SizeBytes,
			PartUUID:   guidString(ids.WORK),
		},
	}
	changed, oldAttributes, err := setWorkNoDriveLetterInLayout(raw, media)
	if err != nil {
		t.Fatal(err)
	}
	if !changed || oldAttributes != 0 {
		t.Fatalf("changed=%v oldAttributes=0x%016X, want changed=true old=0", changed, oldAttributes)
	}
	after, err := parseDriveLayout(raw)
	if err != nil {
		t.Fatal(err)
	}
	if err := verifyOnlyWorkNoDriveLetterChanged(before, after, media.WORK.PartUUID, oldAttributes); err != nil {
		t.Fatal(err)
	}
	if after.Partitions[2].Attributes != gptBasicDataAttributeNoDriveLetter {
		t.Fatalf("WORK attributes=0x%016X want 0x%016X", after.Partitions[2].Attributes, gptBasicDataAttributeNoDriveLetter)
	}
}

func TestDriveLetterMountPathRecognition(t *testing.T) {
	for _, path := range []string{`L:\`, `d:\`} {
		if !isDriveLetterMountPath(path) {
			t.Fatalf("expected drive-letter mount path: %q", path)
		}
	}
	for _, path := range []string{`\\?\Volume{abc}\`, `C:\folder\`, ``} {
		if isDriveLetterMountPath(path) {
			t.Fatalf("unexpected drive-letter mount path: %q", path)
		}
	}
}
