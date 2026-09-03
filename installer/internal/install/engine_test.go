package install

import (
	"errors"
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/layout"
)

type engineTestLogger struct{}

func (engineTestLogger) WriteLine(string) error { return nil }

type engineTestSession struct {
	media MediaLayout
}

func (s *engineTestSession) CleanPartitionTable() error { return nil }
func (s *engineTestSession) CreateGPTAndPartitions(layout.Plan) (MediaLayout, error) {
	return s.media, nil
}
func (s *engineTestSession) VerifyLayoutUnchanged(MediaLayout) (MediaLayout, error) {
	return s.media, nil
}
func (s *engineTestSession) Close() error { return nil }

type engineTestBackend struct {
	session      *engineTestSession
	failFormat   error
	verifyReport VerificationReport
	verifyErr    error
}

func (b *engineTestBackend) BeginDestructive(domain.Disk) (DestructiveSession, domain.Disk, error) {
	return b.session, engineTestDisk(), nil
}
func (*engineTestBackend) FormatESP(MediaLayout) error { return nil }
func (b *engineTestBackend) FormatDATA(MediaLayout) error {
	return b.failFormat
}
func (*engineTestBackend) FormatWORK(MediaLayout) error       { return nil }
func (*engineTestBackend) EnsureWORKHidden(MediaLayout) error { return nil }
func (*engineTestBackend) CopyInstallPayload(MediaLayout, func(uint64, uint64)) error {
	return nil
}
func (*engineTestBackend) WriteIdentity(MediaLayout, uint64) (DeviceINI, error) {
	return DeviceINI{Nonce: "test"}, nil
}
func (b *engineTestBackend) Verify(MediaLayout, DeviceINI) (VerificationReport, error) {
	return b.verifyReport, b.verifyErr
}

func TestEngineSuccessEmitsExactlyOneFinished(t *testing.T) {
	report := VerificationReport{Items: []VerificationItem{{Name: "test", Expected: "ok", Actual: "ok", Match: true}}}
	events := runEngineTest(t, &engineTestBackend{session: engineTestSessionWithMedia(), verifyReport: report})
	finished := finishedEvents(events)
	if len(finished) != 1 {
		t.Fatalf("EventFinished count=%d, want 1", len(finished))
	}
	if finished[0].Err != nil || finished[0].Verification == nil || !finished[0].Verification.OK() {
		t.Fatalf("unexpected success event: %+v", finished[0])
	}
}

func TestEngineOrdinaryStageFailureEmitsExactlyOneFinished(t *testing.T) {
	events := runEngineTest(t, &engineTestBackend{session: engineTestSessionWithMedia(), failFormat: errors.New("format failed")})
	finished := finishedEvents(events)
	if len(finished) != 1 {
		t.Fatalf("EventFinished count=%d, want 1", len(finished))
	}
	if finished[0].Err == nil {
		t.Fatal("ordinary stage failure must include an error")
	}
}

func TestEngineVerifyMismatchEmitsExactlyOneFinishedWithReport(t *testing.T) {
	report := VerificationReport{Items: []VerificationItem{{Name: "WORK hidden", Expected: "no letter", Actual: "has letter", Match: false}}}
	events := runEngineTest(t, &engineTestBackend{session: engineTestSessionWithMedia(), verifyReport: report})
	finished := finishedEvents(events)
	if len(finished) != 1 {
		t.Fatalf("EventFinished count=%d, want 1", len(finished))
	}
	if finished[0].Err == nil {
		t.Fatal("verification mismatch must include an error")
	}
	if finished[0].Verification == nil || len(finished[0].Verification.Items) != 1 {
		t.Fatalf("verification mismatch lost its report: %+v", finished[0])
	}
	if finished[0].Verification.Items[0].Match {
		t.Fatal("verification mismatch report was unexpectedly successful")
	}
}

func runEngineTest(t *testing.T, backend Backend) []Event {
	t.Helper()
	engine, err := NewEngine(backend, engineTestLogger{})
	if err != nil {
		t.Fatal(err)
	}
	var events []Event
	for event := range engine.RunAsync(engineTestDisk()) {
		events = append(events, event)
	}
	return events
}

func finishedEvents(events []Event) []Event {
	var result []Event
	for _, event := range events {
		if event.Kind == EventFinished {
			result = append(result, event)
		}
	}
	return result
}

func engineTestDisk() domain.Disk {
	return domain.Disk{Number: 7, Model: "QEMU", Serial: "TEST", SizeBytes: 40 * layout.GiB, SectorBytes: 512}
}

func engineTestSessionWithMedia() *engineTestSession {
	return &engineTestSession{media: MediaLayout{
		DiskNumber: 7,
		DiskPTUUID: "disk",
		ESP:        PartitionRef{PartUUID: "esp"},
		DATA:       PartitionRef{PartUUID: "data"},
		WORK:       PartitionRef{PartUUID: "work"},
	}}
}
