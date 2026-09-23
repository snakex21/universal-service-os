package ui

import (
	"testing"
	"time"
)

func TestTouchTapWithinSlop(t *testing.T) {
	var tr touchTracker
	now := time.Unix(0, 0)
	slop := int32(15) // 10 DIP at 150 %
	tr.down(1, 100, 100, now)
	if dy, started := tr.move(110, 108, slop, now.Add(30*time.Millisecond)); dy != 0 || started {
		t.Fatalf("jitter inside the slop moved the content: dy=%d started=%v", dy, started)
	}
	if tap, _ := tr.up(108, 110, slop, now.Add(80*time.Millisecond)); !tap {
		t.Fatal("a touch that stayed within 15 px must be a tap")
	}
}

func TestTouchDragFollowsFinger(t *testing.T) {
	var tr touchTracker
	now := time.Unix(0, 0)
	slop := int32(15)
	tr.down(1, 100, 100, now)
	dy, started := tr.move(100, 120, slop, now.Add(20*time.Millisecond))
	if !started || dy != 20 {
		t.Fatalf("leaving the slop: dy=%d started=%v, want 20 true (content jumps to the finger)", dy, started)
	}
	if dy, started = tr.move(100, 90, slop, now.Add(40*time.Millisecond)); started || dy != -30 {
		t.Fatalf("drag back up: dy=%d started=%v", dy, started)
	}
	// A drag that returns to the start is still no tap.
	if tap, _ := tr.up(100, 100, slop, now.Add(60*time.Millisecond)); tap {
		t.Fatal("a drag became a tap")
	}
}

func TestTouchReleaseVelocity(t *testing.T) {
	var tr touchTracker
	now := time.Unix(0, 0)
	tr.down(1, 0, 0, now)
	// Slow start, then a quick flick down: 2 px/ms over the last 100 ms.
	tr.move(0, 20, 10, now.Add(200*time.Millisecond))
	for ms := 210; ms <= 300; ms += 10 {
		tr.move(0, int32(20+2*(ms-200)), 10, now.Add(time.Duration(ms)*time.Millisecond))
	}
	_, v := tr.up(0, 220, 10, now.Add(300*time.Millisecond))
	if v < 1.9 || v > 2.1 {
		t.Fatalf("release velocity %v px/ms, want ~2", v)
	}
	// A finger that rests before lifting has no fling.
	tr.down(1, 0, 0, now)
	tr.move(0, 100, 10, now.Add(50*time.Millisecond))
	_, v = tr.up(0, 100, 10, now.Add(400*time.Millisecond))
	if v != 0 {
		t.Fatalf("rested release velocity %v, want 0", v)
	}
}

func TestFlingDecays(t *testing.T) {
	if _, ok := newFling(0.1, 0.25, 0.02); ok {
		t.Fatal("a slow release must not fling")
	}
	f, ok := newFling(-2, 0.25, 0.02)
	if !ok {
		t.Fatal("a fast release must fling")
	}
	total, frames := int32(0), 0
	for {
		px, done := f.step(16)
		total += px
		frames++
		if done || frames > 1000 {
			break
		}
	}
	if frames > 200 || total >= 0 {
		t.Fatalf("fling ran %d frames, moved %d px", frames, total)
	}
	// Geometric series: 2 px/ms * 16 ms / (1 - 0.95) = 640 px at most.
	if total < -640 || total > -500 {
		t.Fatalf("fling distance %d px, want about -600", total)
	}
}
