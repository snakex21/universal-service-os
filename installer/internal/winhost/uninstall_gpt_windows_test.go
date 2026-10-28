//go:build windows

package winhost

import (
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/layout"
	"github.com/snakex21/universal-service-os/installer/internal/uninstall"
)

func TestSingleDataLayoutStartsWithoutDriveLetter(t *testing.T) {
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
	part := install.PartitionRef{Number: 1, StartBytes: layout.MiB, SizeBytes: 63 * layout.GiB, PartUUID: guidString(ids.DATA)}
	buffer, err := buildSingleDataLayoutBuffer(header, ids.Disk, ids.DATA, part)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := parseDriveLayout(buffer)
	if err != nil {
		t.Fatal(err)
	}
	if len(parsed.Partitions) != 1 || parsed.Partitions[0].Attributes != gptBasicDataAttributeNoDriveLetter {
		t.Fatalf("partitions=%+v, want one with NoDriveLetter", parsed.Partitions)
	}
	media := uninstall.MediaLayout{DiskPTUUID: guidString(ids.Disk), Data: part}
	if _, err := verifySingleDataLayout(media, parsed, gptBasicDataAttributeNoDriveLetter); err != nil {
		t.Fatalf("fresh layout: %v", err)
	}
	if _, err := verifySingleDataLayout(media, parsed, 0); err == nil {
		t.Fatal("exposed-layout check accepted a partition that still has NoDriveLetter")
	}

	raw := append([]byte(nil), buffer...)
	changed, _, err := clearNoDriveLetterInLayout(raw, []install.PartitionRef{part})
	if err != nil || !changed {
		t.Fatalf("clear NoDriveLetter: changed=%v err=%v", changed, err)
	}
	cleared, err := parseDriveLayout(raw)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := verifySingleDataLayout(media, cleared, 0); err != nil {
		t.Fatalf("exposed layout: %v", err)
	}
}
