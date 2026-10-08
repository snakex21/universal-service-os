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
	// A fresh layout carries NoDriveLetter; the first clear changes it.
	if changed, _, err := clearWorkNoDriveLetterInLayout(raw, media); err != nil || !changed {
		t.Fatalf("first clear changed=%v err=%v, want true/nil", changed, err)
	}
	changed, oldAttributes, err := clearWorkNoDriveLetterInLayout(raw, media)
	if err != nil {
		t.Fatal(err)
	}
	if changed || oldAttributes != 0 {
		t.Fatalf("changed=%v oldAttributes=0x%016X, want false/0", changed, oldAttributes)
	}
}

func TestFreshLayoutHidesDataAndWorkUntilExposed(t *testing.T) {
	plan, err := layout.Build(64 * layout.GiB)
	if err != nil {
		t.Fatal(err)
	}
	ids := gptIDs{Disk: windows.GUID{Data1: 21}, ESP: windows.GUID{Data1: 22}, DATA: windows.GUID{Data1: 23}, WORK: windows.GUID{Data1: 24}}
	header := gptHeader{DiskID: ids.Disk, StartingUsableOffset: plan.ESP.StartBytes, UsableLength: plan.WORK.StartBytes + plan.WORK.SizeBytes - plan.ESP.StartBytes, MaxPartitionCount: 128}
	raw, err := buildDriveLayoutBuffer(plan, header, ids)
	if err != nil {
		t.Fatal(err)
	}
	before, err := parseDriveLayout(append([]byte(nil), raw...))
	if err != nil {
		t.Fatal(err)
	}
	if before.Partitions[1].Attributes != gptBasicDataAttributeNoDriveLetter || before.Partitions[2].Attributes != gptBasicDataAttributeNoDriveLetter {
		t.Fatalf("fresh DATA/WORK attributes = 0x%016X/0x%016X, want NoDriveLetter", before.Partitions[1].Attributes, before.Partitions[2].Attributes)
	}
	if _, err := verifyReadBack(plan, ids, before); err != nil {
		t.Fatalf("read-back of the fresh hidden layout: %v", err)
	}
	data := install.PartitionRef{StartBytes: plan.DATA.StartBytes, SizeBytes: plan.DATA.SizeBytes, PartUUID: guidString(ids.DATA)}
	work := install.PartitionRef{StartBytes: plan.WORK.StartBytes, SizeBytes: plan.WORK.SizeBytes, PartUUID: guidString(ids.WORK)}
	changed, old, err := clearNoDriveLetterInLayout(raw, []install.PartitionRef{data, work})
	if err != nil || !changed {
		t.Fatalf("clear changed=%v err=%v", changed, err)
	}
	after, err := parseDriveLayout(raw)
	if err != nil {
		t.Fatal(err)
	}
	for i, p := range after.Partitions {
		if p.Attributes != 0 {
			t.Fatalf("partition %d attributes=0x%016X after expose, want 0", i+1, p.Attributes)
		}
	}
	if err := verifyOnlyNoDriveLetterCleared(before, after, old); err != nil {
		t.Fatal(err)
	}
	media := install.MediaLayout{DiskPTUUID: guidString(ids.Disk), ESP: install.PartitionRef{StartBytes: plan.ESP.StartBytes, SizeBytes: plan.ESP.SizeBytes, PartUUID: guidString(ids.ESP)}, DATA: data, WORK: work}
	if _, err := verifyMediaLayout(media, after); err != nil {
		t.Fatalf("post-format read-back after expose: %v", err)
	}
	// Only WORK cleared: the verifier must notice DATA was expected cleared.
	if err := verifyOnlyNoDriveLetterCleared(before, before, old); err == nil {
		t.Fatal("verifier accepted a layout whose NoDriveLetter bits were not cleared")
	}
	// The ESP is not a basic data partition and must never be targeted.
	esp := install.PartitionRef{StartBytes: plan.ESP.StartBytes, SizeBytes: plan.ESP.SizeBytes, PartUUID: guidString(ids.ESP)}
	if _, _, err := clearNoDriveLetterInLayout(raw, []install.PartitionRef{esp}); err == nil {
		t.Fatal("clearing NoDriveLetter on the ESP was accepted")
	}
}
