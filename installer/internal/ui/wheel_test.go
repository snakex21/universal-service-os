package ui

import "testing"

func TestWheelAccumWholeNotches(t *testing.T) {
	var a wheelAccum
	if got := a.add("list", 120, 48); got != 48 {
		t.Fatalf("one notch = %d, want 48", got)
	}
	if got := a.add("list", -240, 48); got != -96 {
		t.Fatalf("two notches back = %d, want -96", got)
	}
}

// Small deltas (precision touchpad, hi-res wheel) must add up exactly to what
// one notch gives, without losing the fractions in between.
func TestWheelAccumCarriesRemainder(t *testing.T) {
	var a wheelAccum
	total := int32(0)
	for i := 0; i < 120; i++ {
		total += a.add("list", 1, 72) // 150 %: 48 DIP = 72 px per notch
	}
	if total != 72 {
		t.Fatalf("120 x delta 1 scrolled %d px, want 72", total)
	}
	a.reset()
	total = 0
	for i := 0; i < 40; i++ {
		total += a.add("list", -3, 48)
	}
	if total != -48 {
		t.Fatalf("40 x delta -3 scrolled %d px, want -48", total)
	}
}

func TestWheelAccumResetsOnDirectionAndTarget(t *testing.T) {
	var a wheelAccum
	if got := a.add("list", 60, 1); got != 0 {
		t.Fatalf("half a notch gave %d rows", got)
	}
	// Reversing drops the pending half notch instead of cancelling it out.
	if got := a.add("list", -120, 1); got != -1 {
		t.Fatalf("reversal gave %d rows, want -1", got)
	}
	a.add("list", 60, 1)
	if got := a.add("details", 60, 1); got != 0 {
		t.Fatalf("remainder leaked into another target: %d", got)
	}
	if got := a.add("details", 60, 1); got != 1 {
		t.Fatalf("second half notch on details gave %d, want 1", got)
	}
}

func TestWheelAccumIgnoresZero(t *testing.T) {
	var a wheelAccum
	if a.add("x", 0, 48) != 0 || a.add("x", 120, 0) != 0 {
		t.Fatal("zero delta or zero step must not scroll")
	}
}

func TestWheelStep(t *testing.T) {
	if got := wheelStep(3, 24, 400); got != 72 {
		t.Fatalf("3 lines = %d", got)
	}
	if got := wheelStep(0, 24, 400); got != 0 {
		t.Fatalf("scrolling disabled = %d", got)
	}
	if got := wheelStep(wheelPageScroll, 24, 400); got != 376 {
		t.Fatalf("page scroll = %d, want view minus one line", got)
	}
	if got := wheelStep(wheelPageScroll, 24, 10); got != 24 {
		t.Fatalf("page scroll on a tiny view = %d", got)
	}
}
