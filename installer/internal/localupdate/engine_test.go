package localupdate

import (
	"errors"
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
)

type testLogger struct{}

func (testLogger) WriteLine(string) error { return nil }

type testBackend struct {
	calls     []string
	copyErr   error
	verify    install.VerificationReport
	verifyErr error
}

func (b *testBackend) RevalidateInstalledUSOS(expected installed.Target) (installed.Target, error) {
	b.calls = append(b.calls, "revalidate")
	return expected, nil
}

func (b *testBackend) EnsureWORKHidden(install.MediaLayout) error {
	b.calls = append(b.calls, "hide-work")
	return nil
}

func (b *testBackend) CopyInstallPayload(install.MediaLayout, func(uint64, uint64)) error {
	b.calls = append(b.calls, "copy")
	return b.copyErr
}

func (b *testBackend) Verify(install.MediaLayout, install.DeviceINI) (install.VerificationReport, error) {
	b.calls = append(b.calls, "verify")
	return b.verify, b.verifyErr
}

func TestLocalUpdateSuccessRunsOnlyNonDestructiveStages(t *testing.T) {
	backend := &testBackend{verify: install.VerificationReport{Items: []install.VerificationItem{{Name: "payload", Expected: "ok", Actual: "ok", Match: true}}}}
	engine, err := NewEngine(backend, testLogger{})
	if err != nil {
		t.Fatal(err)
	}
	var finished []Event
	for event := range engine.RunAsync(testTarget()) {
		if event.Kind == EventFinished {
			finished = append(finished, event)
		}
	}
	if len(finished) != 1 || finished[0].Err != nil || finished[0].Verification == nil || !finished[0].Verification.OK() {
		t.Fatalf("unexpected finished events: %+v", finished)
	}
	want := []string{"revalidate", "hide-work", "copy", "verify"}
	if len(backend.calls) != len(want) {
		t.Fatalf("calls=%v want=%v", backend.calls, want)
	}
	for i := range want {
		if backend.calls[i] != want[i] {
			t.Fatalf("calls=%v want=%v", backend.calls, want)
		}
	}
}

func TestLocalUpdateStopsBeforeVerifyWhenCopyFails(t *testing.T) {
	backend := &testBackend{copyErr: errors.New("copy failed")}
	engine, err := NewEngine(backend, testLogger{})
	if err != nil {
		t.Fatal(err)
	}
	var finished []Event
	for event := range engine.RunAsync(testTarget()) {
		if event.Kind == EventFinished {
			finished = append(finished, event)
		}
	}
	if len(finished) != 1 || finished[0].Err == nil {
		t.Fatalf("expected one failed finish, got %+v", finished)
	}
	for _, call := range backend.calls {
		if call == "verify" {
			t.Fatal("verify must not run after failed payload copy")
		}
	}
}

func testTarget() installed.Target {
	return installed.Target{
		Disk: domain.Disk{Number: 9, Model: "TEST", Serial: "SERIAL", SizeBytes: 64 << 30, SectorBytes: 512},
		Media: install.MediaLayout{
			DiskNumber: 9,
			DiskPTUUID: "disk",
			ESP:        install.PartitionRef{PartUUID: "esp"},
			DATA:       install.PartitionRef{PartUUID: "data"},
			WORK:       install.PartitionRef{PartUUID: "work"},
		},
		Identity: install.DeviceINI{Nonce: "nonce"},
	}
}
