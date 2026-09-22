//go:build windows

package winhost

import (
	"fmt"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/layout"
	"golang.org/x/sys/windows"
)

type expectedPartition struct {
	name       string
	plan       layout.Partition
	typeID     windows.GUID
	partID     windows.GUID
	attributes uint64
}

func verifyReadBack(plan layout.Plan, ids gptIDs, actual parsedLayout) (install.MediaLayout, error) {
	if !equalGUIDText(guidString(actual.Header.DiskID), guidString(ids.Disk)) {
		return install.MediaLayout{}, fmt.Errorf("read-back disk GUID mismatch: got %s want %s", guidString(actual.Header.DiskID), guidString(ids.Disk))
	}
	if len(actual.Partitions) != 3 {
		return install.MediaLayout{}, fmt.Errorf("read-back partition count=%d, want exactly 3", len(actual.Partitions))
	}

	expected := []expectedPartition{
		{name: "ESP", plan: plan.ESP, typeID: efiSystemPartitionType, partID: ids.ESP, attributes: 0},
		{name: "DATA", plan: plan.DATA, typeID: basicDataPartitionType, partID: ids.DATA, attributes: 0},
		{name: "WORK", plan: plan.WORK, typeID: basicDataPartitionType, partID: ids.WORK, attributes: 0},
	}

	refs := make(map[string]install.PartitionRef, len(expected))
	seen := make(map[string]struct{}, len(expected))
	for _, want := range expected {
		wantID := guidString(want.partID)
		var got *parsedPartition
		for i := range actual.Partitions {
			candidate := &actual.Partitions[i]
			if equalGUIDText(guidString(candidate.PartitionID), wantID) {
				if got != nil {
					return install.MediaLayout{}, fmt.Errorf("read-back contains duplicate PARTUUID %s", wantID)
				}
				got = candidate
			}
		}
		if got == nil {
			return install.MediaLayout{}, fmt.Errorf("read-back missing %s PARTUUID %s", want.name, wantID)
		}
		if !equalGUIDText(guidString(got.PartitionType), guidString(want.typeID)) {
			return install.MediaLayout{}, fmt.Errorf("read-back %s GPT type mismatch: got %s want %s", want.name, guidString(got.PartitionType), guidString(want.typeID))
		}
		if got.StartBytes != want.plan.StartBytes {
			return install.MediaLayout{}, fmt.Errorf("read-back %s offset mismatch: got %d want %d", want.name, got.StartBytes, want.plan.StartBytes)
		}
		if got.SizeBytes != want.plan.SizeBytes {
			return install.MediaLayout{}, fmt.Errorf("read-back %s size mismatch: got %d want %d", want.name, got.SizeBytes, want.plan.SizeBytes)
		}
		if got.Attributes != want.attributes {
			return install.MediaLayout{}, fmt.Errorf("read-back %s GPT attributes mismatch: got 0x%016X want 0x%016X", want.name, got.Attributes, want.attributes)
		}
		seen[guidTextKey(wantID)] = struct{}{}
		refs[want.name] = install.PartitionRef{
			Number:     got.Number,
			StartBytes: got.StartBytes,
			SizeBytes:  got.SizeBytes,
			PartUUID:   wantID,
		}
	}
	for _, got := range actual.Partitions {
		id := guidString(got.PartitionID)
		if _, ok := seen[guidTextKey(id)]; !ok {
			return install.MediaLayout{}, fmt.Errorf("read-back contains unexpected PARTUUID %s", id)
		}
	}

	return install.MediaLayout{
		DiskPTUUID: guidString(ids.Disk),
		ESP:        refs["ESP"],
		DATA:       refs["DATA"],
		WORK:       refs["WORK"],
	}, nil
}
