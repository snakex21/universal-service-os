//go:build windows

package winhost

import (
	"strings"
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/layout"
	"golang.org/x/sys/windows"
)

func firmwareHiddenFixture(t *testing.T) ([]byte, parsedLayout, install.MediaLayout) {
	t.Helper()
	plan, err := layout.Build(64 * layout.GiB)
	if err != nil {
		t.Fatal(err)
	}
	ids := gptIDs{Disk: windows.GUID{Data1: 41}, ESP: windows.GUID{Data1: 42}, DATA: windows.GUID{Data1: 43}, WORK: windows.GUID{Data1: 44}}
	header := gptHeader{DiskID: ids.Disk, StartingUsableOffset: plan.ESP.StartBytes, UsableLength: plan.WORK.StartBytes + plan.WORK.SizeBytes - plan.ESP.StartBytes, MaxPartitionCount: 128}
	raw, err := buildDriveLayoutBuffer(plan, header, ids)
	if err != nil {
		t.Fatal(err)
	}
	created, err := parseDriveLayout(append([]byte(nil), raw...))
	if err != nil {
		t.Fatal(err)
	}
	media, err := verifyReadBack(plan, ids, created)
	if err != nil {
		t.Fatal(err)
	}
	return raw, created, media
}

// The option is a single switch: on = bit 1, off = 0; the bit is always one
// a verifier of either setting accepts.
func TestFirmwareHiddenOptionIsConsistent(t *testing.T) {
	if gptAttributeNoBlockIOProtocol != 2 {
		t.Fatalf("EFI_PART_ATTR_NO_BLOCK_IO_PROTOCOL = 0x%X, want bit 1", gptAttributeNoBlockIOProtocol)
	}
	clear, set := installedDataWorkAttributeChange()
	if clear&gptBasicDataAttributeNoDriveLetter == 0 {
		t.Fatal("installed DATA/WORK change must clear NoDriveLetter")
	}
	if hideDataWorkFromFirmwareMenu {
		if set != gptAttributeNoBlockIOProtocol || installedDataWorkAttributes() != gptAttributeNoBlockIOProtocol || clear&gptAttributeNoBlockIOProtocol != 0 {
			t.Fatalf("hide on: clear=0x%X set=0x%X installed=0x%X", clear, set, installedDataWorkAttributes())
		}
	} else if set != 0 || installedDataWorkAttributes() != 0 || clear&gptAttributeNoBlockIOProtocol == 0 {
		t.Fatalf("hide off: clear=0x%X set=0x%X installed=0x%X", clear, set, installedDataWorkAttributes())
	}
	if installedDataWorkAttributes()&^optionalInstalledDataWorkAttributes != 0 {
		t.Fatal("installed DATA/WORK attributes are not covered by the installed-medium verifier")
	}
}

// Fresh install stage 6 (ExposeFormattedVolumes) with the installed-medium
// change: NoDriveLetter cleared, bit 1 per option, nothing else; the later
// post-format and final checks accept the result.
func TestExposeAppliesFirmwareHiddenAttributes(t *testing.T) {
	raw, created, media := firmwareHiddenFixture(t)
	clear, set := installedDataWorkAttributeChange()
	changed, old, err := applyAttributesInLayout(raw, []install.PartitionRef{media.DATA, media.WORK}, clear, set)
	if err != nil || !changed {
		t.Fatalf("expose changed=%v err=%v", changed, err)
	}
	exposed, err := parseDriveLayout(raw)
	if err != nil {
		t.Fatal(err)
	}
	if err := verifyOnlyAttributesChanged(created, exposed, old, clear, set); err != nil {
		t.Fatalf("expose changed more than the DATA/WORK attributes: %v", err)
	}
	if exposed.Partitions[0].Attributes != 0 {
		t.Fatalf("ESP attributes=0x%016X, want 0", exposed.Partitions[0].Attributes)
	}
	for _, i := range []int{1, 2} {
		if exposed.Partitions[i].Attributes != installedDataWorkAttributes() {
			t.Fatalf("partition %d attributes=0x%016X, want 0x%016X", i+1, exposed.Partitions[i].Attributes, installedDataWorkAttributes())
		}
	}
	for _, phase := range []layoutPhase{verifyLayoutUnchangedLayoutPhase, verifyLegacyBootLayoutPhase} {
		if _, err := verifyMediaLayoutPhase(media, exposed, phase); err != nil {
			t.Fatalf("phase %d rejected the exposed layout: %v", phase, err)
		}
	}
	// The pre-format check still wants exactly NoDriveLetter.
	if _, err := verifyMediaLayoutPhase(media, exposed, writeLegacyBootLayoutPhase); err == nil {
		t.Fatal("pre-format check accepted an exposed layout")
	}
	// Applying the change again is a no-op (update of a current medium).
	changed, _, err = applyAttributesInLayout(raw, []install.PartitionRef{media.DATA, media.WORK}, clear, set)
	if err != nil || changed {
		t.Fatalf("second apply changed=%v err=%v, want no change", changed, err)
	}
}

// Installed media of either setting (DATA/WORK 0 or bit 1) pass the
// update/repair/clear/uninstall checks; anything else is still refused.
func TestInstalledMediumVerifierAcceptsOnlyOptionalBit1(t *testing.T) {
	_, created, media := firmwareHiddenFixture(t)
	set := func(esp, data, work uint64) parsedLayout {
		l := created
		l.Partitions = append([]parsedPartition(nil), created.Partitions...)
		l.Partitions[0].Attributes = esp
		l.Partitions[1].Attributes = data
		l.Partitions[2].Attributes = work
		return l
	}
	for _, ok := range [][2]uint64{{0, 0}, {2, 2}, {2, 0}, {0, 2}} {
		if _, err := verifyMediaLayout(media, set(0, ok[0], ok[1])); err != nil {
			t.Fatalf("DATA=0x%X WORK=0x%X rejected: %v", ok[0], ok[1], err)
		}
	}
	bad := []struct {
		esp, data, work uint64
		want            string
	}{
		{2, 0, 0, "ESP GPT attributes changed"},
		{0, 1, 0, "DATA GPT attributes changed"},
		{0, 0, gptBasicDataAttributeNoDriveLetter | 2, "WORK GPT attributes changed"},
		{0, 1 << 62, 0, "DATA GPT attributes changed"},
	}
	for _, c := range bad {
		if _, err := verifyMediaLayout(media, set(c.esp, c.data, c.work)); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Fatalf("ESP=0x%X DATA=0x%X WORK=0x%X: err=%v, want %q", c.esp, c.data, c.work, err, c.want)
		}
	}
}

// Update (EnsureWORKVisible): a medium from before this option (WORK with
// the old NoDriveLetter policy, DATA 0) is migrated in one GPT write; a
// medium with bit 1 is migrated back when the option is off.
func TestUpdateMigratesDataWorkAttributes(t *testing.T) {
	raw, _, media := firmwareHiddenFixture(t)
	// Old medium: DATA 0, WORK NoDriveLetter.
	if _, _, err := applyAttributesInLayout(raw, []install.PartitionRef{media.DATA}, gptBasicDataAttributeNoDriveLetter, 0); err != nil {
		t.Fatal(err)
	}
	before, err := parseDriveLayout(append([]byte(nil), raw...))
	if err != nil {
		t.Fatal(err)
	}
	clear, set := installedDataWorkAttributeChange()
	changed, old, err := applyAttributesInLayout(raw, []install.PartitionRef{media.DATA, media.WORK}, clear, set)
	if err != nil || !changed {
		t.Fatalf("migration changed=%v err=%v", changed, err)
	}
	after, err := parseDriveLayout(raw)
	if err != nil {
		t.Fatal(err)
	}
	if err := verifyOnlyAttributesChanged(before, after, old, clear, set); err != nil {
		t.Fatal(err)
	}
	if after.Partitions[1].Attributes != installedDataWorkAttributes() || after.Partitions[2].Attributes != installedDataWorkAttributes() {
		t.Fatalf("after migration DATA=0x%X WORK=0x%X", after.Partitions[1].Attributes, after.Partitions[2].Attributes)
	}
	// Option off: bit 1 is cleared from a hidden medium, nothing else.
	offClear := gptBasicDataAttributeNoDriveLetter | gptAttributeNoBlockIOProtocol
	if _, _, err := applyAttributesInLayout(raw, []install.PartitionRef{media.DATA, media.WORK}, 0, gptAttributeNoBlockIOProtocol); err != nil {
		t.Fatal(err)
	}
	hidden, _ := parseDriveLayout(append([]byte(nil), raw...))
	_, oldHidden, err := applyAttributesInLayout(raw, []install.PartitionRef{media.DATA, media.WORK}, offClear, 0)
	if err != nil {
		t.Fatal(err)
	}
	visible, _ := parseDriveLayout(raw)
	if err := verifyOnlyAttributesChanged(hidden, visible, oldHidden, offClear, 0); err != nil {
		t.Fatal(err)
	}
	if visible.Partitions[1].Attributes != 0 || visible.Partitions[2].Attributes != 0 {
		t.Fatalf("option off: DATA=0x%X WORK=0x%X, want 0", visible.Partitions[1].Attributes, visible.Partitions[2].Attributes)
	}
	// A change outside the targets (bit 1 appearing on the ESP) is caught.
	tampered := visible
	tampered.Partitions = append([]parsedPartition(nil), visible.Partitions...)
	tampered.Partitions[0].Attributes = gptAttributeNoBlockIOProtocol
	if err := verifyOnlyAttributesChanged(hidden, tampered, oldHidden, offClear, 0); err == nil {
		t.Fatal("verifier accepted bit 1 appearing on the ESP")
	}
}
