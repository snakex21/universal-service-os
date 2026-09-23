package ui

import (
	"math"
	"time"
)

// Touch gesture arithmetic, free of Win32 so it can be unit tested: tap
// versus drag (a movement threshold), content-follows-finger panning and a
// simple fling (velocity decaying on a timer).

const (
	touchSlopDIP   = 10 // movement that turns a tap into a drag, at 96 DPI
	velocityWindow = 100 * time.Millisecond
	flingFrame     = 16.0 // ms the decay factor refers to
	flingDecay     = 0.95 // speed kept per flingFrame
	// Fling thresholds in DIP per millisecond.
	flingStartDIP = 0.25
	flingStopDIP  = 0.02
)

type touchSample struct {
	y int32
	t time.Time
}

// touchTracker follows one finger (the first one down).
type touchTracker struct {
	active   bool
	id       uint32
	startX   int32
	startY   int32
	lastY    int32
	dragging bool
	samples  []touchSample // recent positions for the release velocity
}

func (t *touchTracker) down(id uint32, x, y int32, now time.Time) {
	*t = touchTracker{active: true, id: id, startX: x, startY: y, lastY: y, samples: t.samples[:0]}
	t.record(y, now)
}

// move reports how far the content should follow the finger vertically
// since the last move (positive = finger moved down), and whether this move
// turned the touch into a drag. Nothing moves until the finger has left the
// slop circle; then the content jumps to the finger and tracks it.
func (t *touchTracker) move(x, y, slop int32, now time.Time) (dy int32, started bool) {
	if !t.active {
		return 0, false
	}
	t.record(y, now)
	if !t.dragging {
		dx, ddy := int64(x-t.startX), int64(y-t.startY)
		if dx*dx+ddy*ddy <= int64(slop)*int64(slop) {
			return 0, false
		}
		t.dragging, started = true, true
	}
	dy, t.lastY = y-t.lastY, y
	return dy, started
}

// up ends the touch. tap is true when the finger never left the slop
// circle; velocity is the vertical speed over the last 100 ms in px/ms.
func (t *touchTracker) up(x, y, slop int32, now time.Time) (tap bool, velocity float64) {
	if !t.active {
		return false, 0
	}
	t.move(x, y, slop, now)
	t.active = false
	if !t.dragging {
		return true, 0
	}
	oldest := t.samples[len(t.samples)-1]
	for i := len(t.samples) - 1; i >= 0; i-- {
		if now.Sub(t.samples[i].t) > velocityWindow {
			break
		}
		oldest = t.samples[i]
	}
	if ms := float64(now.Sub(oldest.t)) / float64(time.Millisecond); ms > 0 {
		velocity = float64(y-oldest.y) / ms
	}
	return false, velocity
}

func (t *touchTracker) cancel() { t.active, t.dragging = false, false }

func (t *touchTracker) record(y int32, now time.Time) {
	t.samples = append(t.samples, touchSample{y, now})
	// Keep the list short: only the last velocityWindow matters.
	if len(t.samples) > 64 {
		t.samples = append(t.samples[:0], t.samples[len(t.samples)-32:]...)
	}
}

// fling continues a pan after the finger lifts, slowing down each frame.
type fling struct {
	v    float64 // px/ms, positive = content moves down
	stop float64 // px/ms below which it ends
	rem  float64 // sub-pixel movement not yet applied
}

func newFling(v, start, stop float64) (fling, bool) {
	if math.Abs(v) < start {
		return fling{}, false
	}
	return fling{v: v, stop: stop}, true
}

// step advances the fling by dt milliseconds and returns the whole pixels
// to move now; done means the fling has run out.
func (f *fling) step(dt float64) (px int32, done bool) {
	if dt <= 0 {
		return 0, false
	}
	f.rem += f.v * dt
	px = int32(f.rem)
	f.rem -= float64(px)
	f.v *= math.Pow(flingDecay, dt/flingFrame)
	return px, math.Abs(f.v) < f.stop
}
