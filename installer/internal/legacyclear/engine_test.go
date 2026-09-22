package legacyclear

import (
	"errors"
	"strings"
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
	"github.com/snakex21/universal-service-os/installer/internal/legacyboot"
)

type testLogger struct{ lines []string }

func (l *testLogger) WriteLine(message string) error {
	l.lines = append(l.lines, message)
	return nil
}

type testBackend struct {
	calls     []string
	clearErr  error
	verifyErr error
}

func (b *testBackend) RevalidateInstalledUSOS(expected installed.Target) (installed.Target, error) {
	b.calls = append(b.calls, "revalidate")
	return expected, nil
}

func (b *testBackend) ClearInstalledLegacyBoot(installed.Target) (legacyboot.Audit, error) {
	b.calls = append(b.calls, "clear")
	return legacyboot.Audit{
		Stage1: legacyboot.ComponentAudit{BeforeSHA256: strings.Repeat("1", 64), AfterSHA256: strings.Repeat("0", 64), ExpectedSHA256: strings.Repeat("0", 64), Changed: true},
		Core:   legacyboot.ComponentAudit{BeforeSHA256: strings.Repeat("2", 64), AfterSHA256: strings.Repeat("0", 64), ExpectedSHA256: strings.Repeat("0", 64), Changed: true},
	}, b.clearErr
}

func (b *testBackend) VerifyInstalledLegacyBootCleared(installed.Target) error {
	b.calls = append(b.calls, "verify")
	return b.verifyErr
}

func TestClearSuccess(t *testing.T) {
	backend := &testBackend{}
	logger := &testLogger{}
	engine, err := NewEngine(backend, logger)
	if err != nil {
		t.Fatal(err)
	}
	var finished *Event
	for event := range engine.RunAsync(testTarget()) {
		if event.Kind == EventFinished {
			copy := event
			finished = &copy
		}
	}
	if finished == nil || finished.Err != nil {
		t.Fatalf("unexpected finish: %+v", finished)
	}
	want := []string{"revalidate", "clear", "verify"}
	if strings.Join(backend.calls, ",") != strings.Join(want, ",") {
		t.Fatalf("calls=%v want=%v", backend.calls, want)
	}
	joined := strings.Join(logger.lines, "\n")
	if !strings.Contains(joined, "LEGACY_CLEAR BEFORE component=stage1") || !strings.Contains(joined, "LEGACY_CLEAR AFTER component=core") || !strings.Contains(joined, "LEGACY_CLEAR GPT READBACK PASS") {
		t.Fatalf("missing clear audit: %s", joined)
	}
}

func TestClearFailureStopsBeforeVerify(t *testing.T) {
	backend := &testBackend{clearErr: errors.New("clear failed")}
	engine, err := NewEngine(backend, &testLogger{})
	if err != nil {
		t.Fatal(err)
	}
	var finished *Event
	for event := range engine.RunAsync(testTarget()) {
		if event.Kind == EventFinished {
			copy := event
			finished = &copy
		}
	}
	if finished == nil || finished.Err == nil {
		t.Fatalf("expected failed finish: %+v", finished)
	}
	for _, call := range backend.calls {
		if call == "verify" {
			t.Fatalf("verify ran after clear failure: %v", backend.calls)
		}
	}
}

func testTarget() installed.Target {
	return installed.Target{
		Disk: domain.Disk{Number: 7, Model: "TEST", Serial: "SERIAL", SizeBytes: 64 << 30, SectorBytes: 512},
		Media: install.MediaLayout{
			DiskNumber: 7,
			DiskPTUUID: "disk",
			ESP:        install.PartitionRef{PartUUID: "esp"},
			DATA:       install.PartitionRef{PartUUID: "data"},
			WORK:       install.PartitionRef{PartUUID: "work"},
		},
	}
}
