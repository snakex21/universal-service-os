//go:build windows

package winhost

import (
	"strings"
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/layout"
	"golang.org/x/sys/windows"
)

// TestFreshInstallStageSequenceGPTChecks replays the GPT read-back checks of
// a fresh install in engine order (install.Engine.run) on an in-memory
// layout, with no disk:
//
//	2 CreateGPTAndPartitions  -> verifyReadBack (DATA/WORK NoDriveLetter)
//	3 WriteLegacyBoot         -> writeLegacyBootLayoutPhase
//	4-6 format                -> GPT untouched
//	6 ExposeFormattedVolumes  -> clear bit 63, verifyOnlyNoDriveLetterCleared
//	6 VerifyLayoutUnchanged   -> verifyLayoutUnchangedLayoutPhase (all 0)
//	9 VerifyLegacyBoot        -> verifyLegacyBootLayoutPhase (all 0)
//
// Regression: stage 3 used the post-format verifier and failed every fresh
// install with "DATA GPT attributes changed: got 0x8000000000000000 want 0".
func TestFreshInstallStageSequenceGPTChecks(t *testing.T) {
	plan, err := layout.Build(64 * layout.GiB)
	if err != nil {
		t.Fatal(err)
	}
	ids := gptIDs{Disk: windows.GUID{Data1: 31}, ESP: windows.GUID{Data1: 32}, DATA: windows.GUID{Data1: 33}, WORK: windows.GUID{Data1: 34}}
	header := gptHeader{DiskID: ids.Disk, StartingUsableOffset: plan.ESP.StartBytes, UsableLength: plan.WORK.StartBytes + plan.WORK.SizeBytes - plan.ESP.StartBytes, MaxPartitionCount: 128}

	// Stage 2: the exact buffer CreateGPTAndPartitions writes, read back.
	raw, err := buildDriveLayoutBuffer(plan, header, ids)
	if err != nil {
		t.Fatal(err)
	}
	created, err := parseDriveLayout(append([]byte(nil), raw...))
	if err != nil {
		t.Fatal(err)
	}
	for _, i := range []int{1, 2} {
		if created.Partitions[i].Attributes != gptBasicDataAttributeNoDriveLetter {
			t.Fatalf("fresh partition %d attributes=0x%016X, want NoDriveLetter", i+1, created.Partitions[i].Attributes)
		}
	}
	media, err := verifyReadBack(plan, ids, created)
	if err != nil {
		t.Fatalf("stage 2 read-back: %v", err)
	}

	// Stage 3: WriteLegacyBoot checks the layout before writing.
	if _, err := verifyMediaLayoutPhase(media, created, writeLegacyBootLayoutPhase); err != nil {
		t.Fatalf("stage 3 WriteLegacyBoot GPT check rejected the fresh layout: %v", err)
	}
	// The post-format verifier must keep rejecting the unexposed layout:
	// that is what tells the final checks that expose did not run.
	if _, err := verifyMediaLayout(media, created); err == nil || !strings.Contains(err.Error(), "DATA GPT attributes changed") {
		t.Fatalf("post-format verifier on the unexposed layout: err=%v, want DATA attribute mismatch", err)
	}

	// Stages 4-6: formatting does not touch the GPT; then expose clears bit 63.
	changed, old, err := clearNoDriveLetterInLayout(raw, []install.PartitionRef{media.DATA, media.WORK})
	if err != nil || !changed {
		t.Fatalf("expose clear changed=%v err=%v", changed, err)
	}
	exposed, err := parseDriveLayout(raw)
	if err != nil {
		t.Fatal(err)
	}
	if err := verifyOnlyNoDriveLetterCleared(created, exposed, old); err != nil {
		t.Fatalf("expose changed more than bit 63: %v", err)
	}
	for i, p := range exposed.Partitions {
		if p.Attributes != 0 {
			t.Fatalf("partition %d attributes=0x%016X after expose, want 0", i+1, p.Attributes)
		}
	}

	// Stage 6 post-format read-back and stage 9 final checks.
	readBack, err := verifyMediaLayoutPhase(media, exposed, verifyLayoutUnchangedLayoutPhase)
	if err != nil {
		t.Fatalf("stage 6 post-format read-back after expose: %v", err)
	}
	if _, err := verifyMediaLayoutPhase(readBack, exposed, verifyLayoutUnchangedLayoutPhase); err != nil {
		t.Fatalf("stage 9 final GPT read-back: %v", err)
	}
	if _, err := verifyMediaLayoutPhase(readBack, exposed, verifyLegacyBootLayoutPhase); err != nil {
		t.Fatalf("stage 9 VerifyLegacyBoot GPT check: %v", err)
	}

	// If expose had not cleared the bit, the post-format checks must fail.
	if _, err := verifyMediaLayoutPhase(media, created, verifyLayoutUnchangedLayoutPhase); err == nil {
		t.Fatal("post-format read-back accepted DATA/WORK still carrying NoDriveLetter")
	}
	if _, err := verifyMediaLayoutPhase(media, created, verifyLegacyBootLayoutPhase); err == nil {
		t.Fatal("final Legacy boot check accepted DATA/WORK still carrying NoDriveLetter")
	}
	// And the pre-format check must not accept an already exposed layout
	// (the phases are distinct, not a relaxed "either" check).
	if _, err := verifyMediaLayoutPhase(media, exposed, writeLegacyBootLayoutPhase); err == nil {
		t.Fatal("pre-format check accepted a layout without NoDriveLetter")
	}
}

// Only DATA/WORK may carry the creation attributes; the ESP stays 0 in every
// phase.
func TestPreFormatPhaseKeepsESPAttributesZero(t *testing.T) {
	plan, ids, actual := validReadBackFixture(t)
	media, err := verifyReadBack(plan, ids, actual)
	if err != nil {
		t.Fatal(err)
	}
	actual.Partitions[0].Attributes = gptBasicDataAttributeNoDriveLetter
	if _, err := verifyMediaLayoutPhase(media, actual, layoutBeforeFormat); err == nil || !strings.Contains(err.Error(), "ESP GPT attributes changed") {
		t.Fatalf("pre-format check with ESP attributes set: err=%v, want ESP attribute mismatch", err)
	}
}
