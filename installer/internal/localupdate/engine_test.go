package localupdate

import (
	"errors"
	"strings"
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/buildinfo"
	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
	"github.com/snakex21/universal-service-os/installer/internal/legacyboot"
	"github.com/snakex21/universal-service-os/installer/internal/workboot"
)

type testLogger struct{ lines []string }

func (l *testLogger) WriteLine(message string) error {
	l.lines = append(l.lines, message)
	return nil
}

type testBackend struct {
	calls          []string
	restoreErr     error
	copyErr        error
	verify         install.VerificationReport
	verifyErr      error
	statusCalls    int
	beforeStatuses []PayloadFileStatus
	afterStatuses  []PayloadFileStatus
	statusErr      error
}

func (b *testBackend) RevalidateInstalledUSOS(expected installed.Target) (installed.Target, error) {
	b.calls = append(b.calls, "revalidate")
	return expected, nil
}

func (b *testBackend) RestoreLegacyBoot(installed.Target) (legacyboot.Audit, error) {
	b.calls = append(b.calls, "legacy")
	return legacyboot.Audit{
		Stage1:                 legacyboot.ComponentAudit{BeforeSHA256: strings.Repeat("1", 64), AfterSHA256: strings.Repeat("2", 64), ExpectedSHA256: strings.Repeat("2", 64), Changed: true},
		Core:                   legacyboot.ComponentAudit{BeforeSHA256: strings.Repeat("3", 64), AfterSHA256: strings.Repeat("4", 64), ExpectedSHA256: strings.Repeat("4", 64), Changed: true},
		CoreSlotZeroReadbackOK: true,
	}, b.restoreErr
}

func (b *testBackend) MigrateWORKBootPath(install.MediaLayout) (workboot.Migration, error) {
	b.calls = append(b.calls, "migrate-work-boot")
	return workboot.Migration{Action: workboot.ActionRename, From: "EFI/BOOT", To: "EFI/USOS-WORK"}, nil
}

func (b *testBackend) EnsureWORKVisible(install.MediaLayout) error {
	b.calls = append(b.calls, "expose-work")
	return nil
}

func (b *testBackend) PayloadStatus(install.MediaLayout) ([]PayloadFileStatus, error) {
	b.calls = append(b.calls, "payload-status")
	b.statusCalls++
	if b.statusErr != nil {
		return nil, b.statusErr
	}
	if b.statusCalls == 1 {
		return append([]PayloadFileStatus(nil), b.beforeStatuses...), nil
	}
	return append([]PayloadFileStatus(nil), b.afterStatuses...), nil
}

func (b *testBackend) CopyInstallPayload(install.MediaLayout, func(uint64, uint64)) error {
	b.calls = append(b.calls, "copy")
	return b.copyErr
}

func (b *testBackend) Verify(install.MediaLayout, install.DeviceINI) (install.VerificationReport, error) {
	b.calls = append(b.calls, "verify")
	return b.verify, b.verifyErr
}

func TestLocalUpdateSuccessWritesGuardedLegacyBootBeforePayload(t *testing.T) {
	backend := &testBackend{
		beforeStatuses: testPayloadStatuses(
			strings.Repeat("a", 64),
			strings.Repeat("c", 64),
		),
		afterStatuses: testPayloadStatuses(
			strings.Repeat("b", 64),
			strings.Repeat("d", 64),
		),
		verify: install.VerificationReport{Items: []install.VerificationItem{{Name: "payload", Expected: "ok", Actual: "ok", Match: true}}},
	}
	logger := &testLogger{}
	engine, err := NewEngine(backend, logger)
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
	want := []string{"revalidate", "legacy", "migrate-work-boot", "expose-work", "payload-status", "copy", "payload-status", "verify"}
	if len(backend.calls) != len(want) {
		t.Fatalf("calls=%v want=%v", backend.calls, want)
	}
	for i := range want {
		if backend.calls[i] != want[i] {
			t.Fatalf("calls=%v want=%v", backend.calls, want)
		}
	}
	joined := strings.Join(logger.lines, "\n")
	if !strings.Contains(joined, "LEGACY_BOOT BEFORE component=stage1") ||
		!strings.Contains(joined, "LEGACY_BOOT SLOT ZERO READBACK PASS") ||
		!strings.Contains(joined, "LEGACY_BOOT AFTER component=core") ||
		!strings.Contains(joined, "LEGACY_BOOT GPT READBACK PASS") ||
		!strings.Contains(joined, "PAYLOAD BEFORE") ||
		!strings.Contains(joined, "PAYLOAD AFTER") ||
		!strings.Contains(joined, "EFI/USOS/micro-linux/initramfs-usos") ||
		!strings.Contains(joined, "BOOTMANAGER AFTER") ||
		!strings.Contains(joined, "changed=yes") {
		t.Fatalf("full payload SHA-256 audit missing from log: %s", joined)
	}
}

func TestLocalUpdateStopsBeforePayloadWhenLegacyWriteFails(t *testing.T) {
	backend := &testBackend{restoreErr: errors.New("legacy write failed")}
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
	if finished == nil || finished.Err == nil || !strings.Contains(finished.Err.Error(), "legacy write failed") {
		t.Fatalf("expected Legacy stage failure, got %+v", finished)
	}
	for _, call := range backend.calls {
		if call == "migrate-work-boot" || call == "expose-work" || call == "copy" || call == "verify" {
			t.Fatalf("Legacy failure must stop before ordinary update writes: calls=%v", backend.calls)
		}
	}
}

func TestLocalUpdateStopsBeforeVerifyWhenCopyFails(t *testing.T) {
	backend := &testBackend{
		beforeStatuses: testPayloadStatuses(strings.Repeat("a", 64), strings.Repeat("c", 64)),
		copyErr:        errors.New("copy failed"),
	}
	engine, err := NewEngine(backend, &testLogger{})
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

func TestLocalUpdateFailsWhenAnyPayloadHashDoesNotMatchAfterWrite(t *testing.T) {
	backend := &testBackend{
		beforeStatuses: testPayloadStatuses(strings.Repeat("a", 64), strings.Repeat("c", 64)),
		afterStatuses: []PayloadFileStatus{
			{Path: bootManagerPayloadPath, ActualSHA256: strings.Repeat("b", 64), ExpectedSHA256: strings.Repeat("b", 64)},
			{Path: "EFI/USOS/micro-linux/initramfs-usos", ActualSHA256: strings.Repeat("e", 64), ExpectedSHA256: strings.Repeat("d", 64)},
		},
	}
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
	if finished == nil || finished.Err == nil || !strings.Contains(finished.Err.Error(), "initramfs-usos") || !strings.Contains(finished.Err.Error(), "SHA-256 mismatch after write") {
		t.Fatalf("expected post-write payload hash failure, got %+v", finished)
	}
	for _, call := range backend.calls {
		if call == "verify" {
			t.Fatal("verify must not run after payload hash mismatch")
		}
	}
}

func TestLocalUpdateRejectsDowngradeWithoutExplicitConfirmation(t *testing.T) {
	payloadInfo, err := PayloadBuildInfo()
	if err != nil {
		t.Fatal(err)
	}
	backend := &testBackend{}
	logger := &testLogger{}
	engine, err := NewEngine(backend, logger)
	if err != nil {
		t.Fatal(err)
	}
	target := testTarget()
	target.BuildInfo = buildinfo.Info{ID: "BNEWER", Epoch: payloadInfo.Epoch + 1, SourceSHA256: strings.Repeat("f", 64)}
	var finished *Event
	for event := range engine.RunAsync(target) {
		if event.Kind == EventFinished {
			copy := event
			finished = &copy
		}
	}
	if finished == nil || finished.Err == nil || !strings.Contains(finished.Err.Error(), "cofnięcie wymaga wyraźnego potwierdzenia") {
		t.Fatalf("expected downgrade rejection, got %+v", finished)
	}
	for _, call := range backend.calls {
		if call == "legacy" || call == "migrate-work-boot" || call == "expose-work" || call == "copy" || call == "verify" {
			t.Fatalf("downgrade changed media before confirmation: calls=%v", backend.calls)
		}
	}
}

func TestLocalUpdateRunsDowngradeAfterExplicitConfirmation(t *testing.T) {
	payloadInfo, err := PayloadBuildInfo()
	if err != nil {
		t.Fatal(err)
	}
	backend := &testBackend{
		beforeStatuses: testPayloadStatuses(strings.Repeat("a", 64), strings.Repeat("c", 64)),
		afterStatuses:  testPayloadStatuses(strings.Repeat("b", 64), strings.Repeat("d", 64)),
		verify:         install.VerificationReport{Items: []install.VerificationItem{{Name: "payload", Expected: "ok", Actual: "ok", Match: true}}},
	}
	logger := &testLogger{}
	engine, err := NewEngine(backend, logger)
	if err != nil {
		t.Fatal(err)
	}
	target := testTarget()
	target.BuildInfo = buildinfo.Info{ID: "BNEWER", Epoch: payloadInfo.Epoch + 1, SourceSHA256: strings.Repeat("f", 64)}
	var finished *Event
	for event := range engine.RunAsyncConfirmedDowngrade(target) {
		if event.Kind == EventFinished {
			copy := event
			finished = &copy
		}
	}
	if finished == nil || finished.Err != nil {
		t.Fatalf("confirmed downgrade failed: %+v", finished)
	}
	if !strings.Contains(strings.Join(logger.lines, "\n"), "DOWNGRADE CONFIRMED") {
		t.Fatalf("confirmed downgrade was not audited: %v", logger.lines)
	}
}

func testPayloadStatuses(bootActual, initramfsActual string) []PayloadFileStatus {
	return []PayloadFileStatus{
		{Path: bootManagerPayloadPath, ActualSHA256: bootActual, ExpectedSHA256: strings.Repeat("b", 64)},
		{Path: "EFI/USOS/micro-linux/initramfs-usos", ActualSHA256: initramfsActual, ExpectedSHA256: strings.Repeat("d", 64)},
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
