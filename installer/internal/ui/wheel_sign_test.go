package ui

import "testing"

// WM_MOUSEWHEEL: a positive delta is the wheel turned away from the user,
// which must scroll towards the start (positive units = up).
func TestWheelSignAwayIsUp(t *testing.T) {
	var a wheelAccum
	if got := a.add("list", 120, 1); got != 1 {
		t.Fatalf("delta +120 = %d, want +1 (up)", got)
	}
	if got := a.add("list", -120, 1); got != -1 {
		t.Fatalf("delta -120 = %d, want -1 (down)", got)
	}
}
