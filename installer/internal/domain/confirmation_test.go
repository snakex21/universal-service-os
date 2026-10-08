package domain

import (
	"testing"
	"time"
)

func TestConfirmationListsDiskIdentity(t *testing.T) {
	confirmation := BuildConfirmation(Disk{Number: 9, Model: "Kingston DataTraveler 3.0", Serial: "ABC", SizeBytes: 64 * 1024 * 1024 * 1024})
	if confirmation.DiskModel != "Kingston DataTraveler 3.0" || confirmation.DiskNumber != 9 || confirmation.DiskCapacity == "" {
		t.Fatalf("confirmation lost the disk identity: %+v", confirmation)
	}
}

func TestDestructiveGateNeedsTickAndDelay(t *testing.T) {
	shown := time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)
	gate := NewDestructiveGate(shown)
	if gate.Ready(shown) || gate.Ready(shown.Add(10*time.Second)) {
		t.Fatal("gate ready without the checkbox")
	}
	if got := gate.RemainingSeconds(shown); got != 3 {
		t.Fatalf("countdown at display = %d, want 3", got)
	}
	gate.Toggle()
	if !gate.Acknowledged() {
		t.Fatal("toggle did not tick the checkbox")
	}
	for _, at := range []time.Duration{0, time.Second, 2999 * time.Millisecond} {
		if gate.Ready(shown.Add(at)) {
			t.Fatalf("gate ready %v after display, before the 3 s delay", at)
		}
	}
	if got := gate.RemainingSeconds(shown.Add(2001 * time.Millisecond)); got != 1 {
		t.Fatalf("countdown at 2.001 s = %d, want 1", got)
	}
	if !gate.Ready(shown.Add(DestructiveConfirmDelay)) {
		t.Fatal("gate not ready after tick and delay")
	}
	gate.Toggle()
	if gate.Ready(shown.Add(time.Minute)) {
		t.Fatal("unticking must disable the start button again")
	}
	// A clock that goes backwards never shortens the delay below zero wait.
	gate.Toggle()
	if gate.Ready(shown.Add(-time.Second)) {
		t.Fatal("gate ready before it was shown")
	}
	if (DestructiveGate{}).Ready(shown) {
		t.Fatal("zero gate must never be ready")
	}
}
