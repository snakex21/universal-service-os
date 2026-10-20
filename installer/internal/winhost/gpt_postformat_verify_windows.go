//go:build windows

package winhost

import (
	"fmt"

	"github.com/snakex21/universal-service-os/installer/internal/install"
)

// layoutPhase says which GPT attributes DATA and WORK must carry when a
// destructive-session check reads the layout back. A fresh install creates
// DATA and WORK with NoDriveLetter (raw volumes stay unmounted) and clears
// the bit only after formatting, in ExposeFormattedVolumes.
type layoutPhase int

const (
	// layoutBeforeFormat: between CreateGPTAndPartitions and
	// ExposeFormattedVolumes (Legacy boot write, formatting).
	layoutBeforeFormat layoutPhase = iota
	// layoutExposed: after ExposeFormattedVolumes, and for every installed
	// medium (update, repair, clear, uninstall): all attributes 0.
	layoutExposed
)

// GPT checks of the fresh-install stage sequence. The session methods use
// these, so the stage-order regression test exercises the same phases.
const (
	writeLegacyBootLayoutPhase       = layoutBeforeFormat
	verifyLayoutUnchangedLayoutPhase = layoutExposed
	verifyLegacyBootLayoutPhase      = layoutExposed
)

func (p layoutPhase) dataWorkAttributes() uint64 {
	if p == layoutBeforeFormat {
		return freshDataWorkAttributes
	}
	return 0
}

// verifyMediaLayout checks an installed (exposed) medium: all attributes 0.
func verifyMediaLayout(expected install.MediaLayout, actual parsedLayout) (install.MediaLayout, error) {
	return verifyMediaLayoutPhase(expected, actual, layoutExposed)
}

func verifyMediaLayoutPhase(expected install.MediaLayout, actual parsedLayout, phase layoutPhase) (install.MediaLayout, error) {
	dataWorkAttributes := phase.dataWorkAttributes()
	if !equalGUIDText(guidString(actual.Header.DiskID), expected.DiskPTUUID) {
		return install.MediaLayout{}, fmt.Errorf("disk GUID changed: got %s want %s", guidString(actual.Header.DiskID), expected.DiskPTUUID)
	}
	if len(actual.Partitions) != 3 {
		return install.MediaLayout{}, fmt.Errorf("partition count changed: got %d want 3", len(actual.Partitions))
	}

	refs := []struct {
		name       string
		expected   install.PartitionRef
		typeID     string
		attributes uint64
	}{
		{"ESP", expected.ESP, guidString(efiSystemPartitionType), 0},
		{"DATA", expected.DATA, guidString(basicDataPartitionType), dataWorkAttributes},
		{"WORK", expected.WORK, guidString(basicDataPartitionType), dataWorkAttributes},
	}

	result := install.MediaLayout{DiskNumber: expected.DiskNumber, DiskPTUUID: expected.DiskPTUUID}
	seen := make(map[string]struct{}, 3)
	for _, want := range refs {
		var got *parsedPartition
		for i := range actual.Partitions {
			candidate := &actual.Partitions[i]
			if equalGUIDText(guidString(candidate.PartitionID), want.expected.PartUUID) {
				if got != nil {
					return install.MediaLayout{}, fmt.Errorf("duplicate %s PARTUUID %s", want.name, want.expected.PartUUID)
				}
				got = candidate
			}
		}
		if got == nil {
			return install.MediaLayout{}, fmt.Errorf("missing %s PARTUUID %s", want.name, want.expected.PartUUID)
		}
		if !equalGUIDText(guidString(got.PartitionType), want.typeID) {
			return install.MediaLayout{}, fmt.Errorf("%s GPT type changed: got %s want %s", want.name, guidString(got.PartitionType), want.typeID)
		}
		if got.StartBytes != want.expected.StartBytes {
			return install.MediaLayout{}, fmt.Errorf("%s offset changed: got %d want %d", want.name, got.StartBytes, want.expected.StartBytes)
		}
		if got.SizeBytes != want.expected.SizeBytes {
			return install.MediaLayout{}, fmt.Errorf("%s size changed: got %d want %d", want.name, got.SizeBytes, want.expected.SizeBytes)
		}
		if got.Attributes != want.attributes {
			return install.MediaLayout{}, fmt.Errorf("%s GPT attributes changed: got 0x%016X want 0x%016X", want.name, got.Attributes, want.attributes)
		}
		seen[guidTextKey(want.expected.PartUUID)] = struct{}{}
		ref := install.PartitionRef{
			Number:     got.Number,
			StartBytes: got.StartBytes,
			SizeBytes:  got.SizeBytes,
			PartUUID:   guidString(got.PartitionID),
		}
		switch want.name {
		case "ESP":
			result.ESP = ref
		case "DATA":
			result.DATA = ref
		case "WORK":
			result.WORK = ref
		}
	}
	for _, partition := range actual.Partitions {
		if _, ok := seen[guidTextKey(guidString(partition.PartitionID))]; !ok {
			return install.MediaLayout{}, fmt.Errorf("unexpected PARTUUID after format: %s", guidString(partition.PartitionID))
		}
	}
	return result, nil
}
