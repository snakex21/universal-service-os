//go:build windows

package winhost

import (
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/layout"
)

func validReadBackFixture(t *testing.T) (layout.Plan, gptIDs, parsedLayout) {
	t.Helper()
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
	parsed, err := parseDriveLayout(buffer)
	if err != nil {
		t.Fatal(err)
	}
	return plan, ids, parsed
}

func TestVerifyReadBackAcceptsExactLayout(t *testing.T) {
	plan, ids, actual := validReadBackFixture(t)
	media, err := verifyReadBack(plan, ids, actual)
	if err != nil {
		t.Fatal(err)
	}
	if media.ESP.PartUUID != guidString(ids.ESP) || media.DATA.PartUUID != guidString(ids.DATA) || media.WORK.PartUUID != guidString(ids.WORK) {
		t.Fatal("media layout did not preserve read-back PARTUUIDs")
	}
}

func TestVerifyReadBackRejectsAnyPartitionMismatch(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*parsedLayout)
	}{
		{"partuuid", func(p *parsedLayout) { p.Partitions[0].PartitionID = p.Partitions[1].PartitionID }},
		{"type", func(p *parsedLayout) { p.Partitions[0].PartitionType = basicDataPartitionType }},
		{"offset", func(p *parsedLayout) { p.Partitions[1].StartBytes += layout.MiB }},
		{"size", func(p *parsedLayout) { p.Partitions[2].SizeBytes -= layout.MiB }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			plan, ids, actual := validReadBackFixture(t)
			tt.mutate(&actual)
			if _, err := verifyReadBack(plan, ids, actual); err == nil {
				t.Fatal("mismatched read-back was accepted")
			}
		})
	}
}

func TestVerifyReadBackRejectsExtraPartition(t *testing.T) {
	plan, ids, actual := validReadBackFixture(t)
	actual.Partitions = append(actual.Partitions, actual.Partitions[0])
	if _, err := verifyReadBack(plan, ids, actual); err == nil {
		t.Fatal("read-back with extra partition was accepted")
	}
}
