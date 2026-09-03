//go:build windows

package winhost

import (
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/layout"
)

func TestCreateDiskBufferMatchesWinAPILayout(t *testing.T) {
	ids, err := newGPTIDs()
	if err != nil {
		t.Fatal(err)
	}
	buffer, err := buildCreateDiskBuffer(ids.Disk)
	if err != nil {
		t.Fatal(err)
	}
	if len(buffer) != 24 {
		t.Fatalf("CREATE_DISK buffer=%d, want 24", len(buffer))
	}
	readBack, err := readGUID(buffer, 4)
	if err != nil {
		t.Fatal(err)
	}
	if guidString(readBack) != guidString(ids.Disk) {
		t.Fatalf("disk GUID=%s, want %s", guidString(readBack), guidString(ids.Disk))
	}
}

func TestDriveLayoutBufferUsesCurrentPartitionInformationEXOffsets(t *testing.T) {
	plan, err := layout.Build(64 * layout.GiB)
	if err != nil {
		t.Fatal(err)
	}
	ids, err := newGPTIDs()
	if err != nil {
		t.Fatal(err)
	}
	header := gptHeader{
		DiskID:               ids.Disk,
		StartingUsableOffset: 34 * 512,
		UsableLength:         64*layout.GiB - 68*512,
		MaxPartitionCount:    128,
	}
	buffer, err := buildDriveLayoutBuffer(plan, header, ids)
	if err != nil {
		t.Fatal(err)
	}
	if len(buffer) != 48+3*144 {
		t.Fatalf("layout buffer=%d, want %d", len(buffer), 48+3*144)
	}

	parsed, err := parseDriveLayout(buffer)
	if err != nil {
		t.Fatal(err)
	}
	if len(parsed.Partitions) != 3 {
		t.Fatalf("partition count=%d, want 3", len(parsed.Partitions))
	}
	wantNames := []string{"USOS_ESP", "USOS_DATA", "USOS_WORK"}
	wantIDs := []string{guidString(ids.ESP), guidString(ids.DATA), guidString(ids.WORK)}
	wantAttributes := []uint64{0, 0, gptBasicDataAttributeNoDriveLetter}
	for i, partition := range parsed.Partitions {
		if partition.Ordinal != uint16(i+1) {
			t.Fatalf("partition %d ordinal=%d, want %d", i, partition.Ordinal, i+1)
		}
		if partition.Number != uint32(i+1) {
			t.Fatalf("partition %d number=%d, want %d", i, partition.Number, i+1)
		}
		if partition.Name != wantNames[i] {
			t.Fatalf("partition %d name=%q, want %q", i, partition.Name, wantNames[i])
		}
		if guidString(partition.PartitionID) != wantIDs[i] {
			t.Fatalf("partition %d GUID=%s, want %s", i, guidString(partition.PartitionID), wantIDs[i])
		}
		if partition.Attributes != wantAttributes[i] {
			t.Fatalf("partition %d attributes=0x%016X, want 0x%016X", i, partition.Attributes, wantAttributes[i])
		}
	}
}
