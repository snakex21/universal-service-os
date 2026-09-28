package repair

import (
	"errors"
	"strings"
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
	"github.com/snakex21/universal-service-os/installer/internal/legacyboot"
	"github.com/snakex21/universal-service-os/installer/internal/obsolete"
)

type fakeBackend struct {
	calls     []string
	donorLine string
	donorErr  error
}

func (b *fakeBackend) RevalidateInstalledUSOS(expected installed.Target) (installed.Target, error) {
	b.calls = append(b.calls, "revalidate")
	return expected, nil
}

func (b *fakeBackend) CopyESPPayload(install.MediaLayout, func(done, total uint64)) error {
	b.calls = append(b.calls, "copy-esp")
	return nil
}

func (b *fakeBackend) RemoveObsoleteESPFiles(install.MediaLayout) ([]obsolete.Result, error) {
	b.calls = append(b.calls, "obsolete")
	return nil, nil
}

func (b *fakeBackend) RecordWinpeDonor(install.MediaLayout) (string, error) {
	b.calls = append(b.calls, "winpe-donor")
	return b.donorLine, b.donorErr
}

func (b *fakeBackend) RestoreLegacyBoot(installed.Target) (legacyboot.Audit, error) {
	b.calls = append(b.calls, "legacy")
	return legacyboot.Audit{}, nil
}

func (b *fakeBackend) VerifyRepair(install.MediaLayout, install.DeviceINI) (install.VerificationReport, error) {
	b.calls = append(b.calls, "verify")
	return install.VerificationReport{Items: []install.VerificationItem{{Name: "esp", Match: true}}}, nil
}

type memLogger struct{ lines []string }

func (l *memLogger) WriteLine(message string) error {
	l.lines = append(l.lines, message)
	return nil
}

func runRepair(t *testing.T, backend *fakeBackend) (*memLogger, error) {
	t.Helper()
	logger := &memLogger{}
	engine, err := NewEngine(backend, logger)
	if err != nil {
		t.Fatal(err)
	}
	var final error
	for event := range engine.RunAsync(installed.Target{}) {
		if event.Kind == EventFinished {
			final = event.Err
		}
	}
	return logger, final
}

// Repair used to rewrite only the ESP payload, so a PE10 donor copied to
// DATA\Programs\USOS\WinPE was never recorded in winpe-donor.ini by Repair
// (only by Install and Update), although the DATA guide says to run Repair.
func TestRepairRecordsWinpeDonorAfterESPCopy(t *testing.T) {
	backend := &fakeBackend{donorLine: "PE10_x64_19041_USOS.iso SHA-256 ab recorded in EFI/USOS/winpe-donor.ini"}
	logger, err := runRepair(t, backend)
	if err != nil {
		t.Fatalf("repair failed: %v", err)
	}
	want := "revalidate,copy-esp,obsolete,winpe-donor,legacy,verify"
	if got := strings.Join(backend.calls, ","); got != want {
		t.Fatalf("repair steps = %s, want %s", got, want)
	}
	if !strings.Contains(strings.Join(logger.lines, "\n"), "WINPE_DONOR PE10_x64_19041_USOS.iso") {
		t.Fatalf("donor state not logged: %v", logger.lines)
	}
}

func TestRepairFailsWhenDonorCannotBeRecorded(t *testing.T) {
	backend := &fakeBackend{donorErr: errors.New("ESP is read-only")}
	_, err := runRepair(t, backend)
	if err == nil || !strings.Contains(err.Error(), "WinPE donor") {
		t.Fatalf("expected a WinPE donor error, got %v", err)
	}
	for _, call := range backend.calls {
		if call == "legacy" || call == "verify" {
			t.Fatalf("repair continued after the donor error: %v", backend.calls)
		}
	}
}
