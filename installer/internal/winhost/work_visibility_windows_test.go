//go:build windows

package winhost

import (
	"encoding/binary"
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/layout"
	"golang.org/x/sys/windows"
)

func TestClearWorkNoDriveLetterPatchesOnlyWorkAttributes(t *testing.T) {
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

	// Simulate a medium created by the previous hidden-WORK policy.
	workOffset := driveLayoutHeaderSize + 2*partitionEntrySize + gptInfoOffset + 32
	binary.LittleEndian.PutUint64(raw[workOffset:workOffset+8], gptBasicDataAttributeNoDriveLetter)
	before, err := parseDriveLayout(append([]byte(nil), raw...))
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
	changed, oldAttributes, err := clearWorkNoDriveLetterInLayout(raw, media)
	if err != nil {
		t.Fatal(err)
	}
	if !changed || oldAttributes != gptBasicDataAttributeNoDriveLetter {
		t.Fatalf("changed=%v oldAttributes=0x%016X, want changed=true old=0x%016X", changed, oldAttributes, gptBasicDataAttributeNoDriveLetter)
	}
	after, err := parseDriveLayout(raw)
	if err != nil {
		t.Fatal(err)
	}
	if err := verifyOnlyWorkNoDriveLetterCleared(before, after, media.WORK.PartUUID, oldAttributes); err != nil {
		t.Fatal(err)
	}
	if after.Partitions[2].Attributes != 0 {
		t.Fatalf("WORK attributes=0x%016X want 0", after.Partitions[2].Attributes)
	}
}

func TestClearWorkNoDriveLetterIsIdempotent(t *testing.T) {
	plan, err := layout.Build(64 * layout.GiB)
	if err != nil {
		t.Fatal(err)
	}
	ids := gptIDs{Disk: windows.GUID{Data1: 11}, ESP: windows.GUID{Data1: 12}, DATA: windows.GUID{Data1: 13}, WORK: windows.GUID{Data1: 14}}
	header := gptHeader{DiskID: ids.Disk, StartingUsableOffset: plan.ESP.StartBytes, UsableLength: plan.WORK.StartBytes + plan.WORK.SizeBytes - plan.ESP.StartBytes, MaxPartitionCount: 128}
	raw, err := buildDriveLayoutBuffer(plan, header, ids)
	if err != nil {
		t.Fatal(err)
	}
	media := install.MediaLayout{DiskNumber: 8, DiskPTUUID: guidString(ids.Disk), WORK: install.PartitionRef{StartBytes: plan.WORK.StartBytes, SizeBytes: plan.WORK.SizeBytes, PartUUID: guidString(ids.WORK)}}
	changed, oldAttributes, err := clearWorkNoDriveLetterInLayout(raw, media)
	if err != nil {
		t.Fatal(err)
	}
	if changed || oldAttributes != 0 {
		t.Fatalf("changed=%v oldAttributes=0x%016X, want false/0", changed, oldAttributes)
	}
}
