package ui

import (
	"math"
	"strings"
	"time"
)

// Gamepad navigation logic (XInput semantics), free of Win32 so it can be
// unit tested: radial stick deadzone with hysteresis, hold-to-repeat, button
// edge detection, spatial focus movement and section switching. The polling
// and the mapping onto the window live in gamepad_windows.go.

type navDir int8

const (
	dirNone navDir = iota
	dirUp
	dirDown
	dirLeft
	dirRight
)

// XINPUT_GAMEPAD button bits and the documented thumbstick deadzones.
const (
	padDpadUp    = 0x0001
	padDpadDown  = 0x0002
	padDpadLeft  = 0x0004
	padDpadRight = 0x0008
	padStart     = 0x0010
	padView      = 0x0020
	padLB        = 0x0100
	padRB        = 0x0200
	padA         = 0x1000
	padB         = 0x2000

	leftThumbDeadzone  = 7849 // XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE
	rightThumbDeadzone = 8689 // XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE
	thumbMax           = 32767
)

const (
	padRepeatDelay    = 400 * time.Millisecond
	padRepeatInterval = 90 * time.Millisecond
	// stickRelease is the fraction of the deadzone the stick may fall back
	// to before a held direction is released (hysteresis against jitter).
	stickRelease = 0.75
	// stickKeepCos keeps a held direction while the stick stays within 60
	// degrees of it, so a slightly curved push does not flip to a
	// perpendicular direction.
	stickKeepCos = 0.5
)

// stickDir converts a thumbstick position to a direction. The deadzone is
// radial (the vector length, not each axis), so diagonals are not favoured;
// prev is the direction reported last time, for hysteresis.
func stickDir(x, y int16, deadzone int32, prev navDir) navDir {
	fx, fy := float64(x), float64(y)
	mag := math.Hypot(fx, fy)
	if prev == dirNone {
		if mag < float64(deadzone) {
			return dirNone
		}
	} else {
		if mag < float64(deadzone)*stickRelease {
			return dirNone
		}
		if along(prev, fx, fy) >= mag*stickKeepCos {
			return prev
		}
	}
	// XInput Y grows upwards.
	if math.Abs(fx) > math.Abs(fy) {
		if fx > 0 {
			return dirRight
		}
		return dirLeft
	}
	if fy > 0 {
		return dirUp
	}
	return dirDown
}

// along is the component of (x, y) in direction d.
func along(d navDir, x, y float64) float64 {
	switch d {
	case dirUp:
		return y
	case dirDown:
		return -y
	case dirLeft:
		return -x
	case dirRight:
		return x
	}
	return 0
}

// stickAxis maps one axis to -1..1 outside its deadzone, squared for fine
// control near the centre (used for right-stick scrolling).
func stickAxis(v int16, deadzone int32) float64 {
	f := float64(v)
	a := math.Abs(f)
	if a <= float64(deadzone) {
		return 0
	}
	n := math.Min(1, (a-float64(deadzone))/float64(thumbMax-deadzone))
	return math.Copysign(n*n, f)
}

// dpadDir reads the D-pad; a vertical press wins over a horizontal one.
func dpadDir(buttons uint16) navDir {
	switch {
	case buttons&padDpadUp != 0 && buttons&padDpadDown == 0:
		return dirUp
	case buttons&padDpadDown != 0 && buttons&padDpadUp == 0:
		return dirDown
	case buttons&padDpadLeft != 0 && buttons&padDpadRight == 0:
		return dirLeft
	case buttons&padDpadRight != 0 && buttons&padDpadLeft == 0:
		return dirRight
	}
	return dirNone
}

// repeater fires once when a direction starts, then after padRepeatDelay
// every padRepeatInterval while it is held.
type repeater struct {
	dir  navDir
	next time.Time
}

func (r *repeater) update(d navDir, now time.Time) bool {
	if d == dirNone {
		r.dir = dirNone
		return false
	}
	if d != r.dir {
		r.dir, r.next = d, now.Add(padRepeatDelay)
		return true
	}
	if now.Before(r.next) {
		return false
	}
	r.next = r.next.Add(padRepeatInterval)
	if r.next.Before(now) { // the poll stalled: no burst of catch-up repeats
		r.next = now.Add(padRepeatInterval)
	}
	return true
}

type padKind int8

const (
	padMove padKind = iota + 1
	padActivate
	padCancel
	padPrevSection
	padNextSection
	padPrimary
)

type padEvent struct {
	kind padKind
	dir  navDir // padMove only
}

type padSample struct {
	buttons        uint16
	lx, ly, rx, ry int16
}

// padNav turns successive XInput samples into navigation events.
type padNav struct {
	primed  bool // the first sample only records the held buttons
	buttons uint16
	stick   navDir
	rep     repeater
}

func (p *padNav) reset() { *p = padNav{} }

// step consumes one sample. It returns the events in the order to apply
// them and the right-stick scroll speed (-1..1, positive = towards the top).
func (p *padNav) step(s padSample, now time.Time) ([]padEvent, float64) {
	scroll := stickAxis(s.ry, rightThumbDeadzone)
	p.stick = stickDir(s.lx, s.ly, leftThumbDeadzone, p.stick)
	if !p.primed {
		// Buttons already down when the pad (re)connects or the window gets
		// the foreground must not fire; neither does a held direction.
		p.primed, p.buttons = true, s.buttons
		p.rep.dir = p.direction(s.buttons)
		p.rep.next = now.Add(padRepeatDelay)
		return nil, scroll
	}
	pressed := s.buttons &^ p.buttons
	p.buttons = s.buttons
	var events []padEvent
	if d := p.direction(s.buttons); p.rep.update(d, now) {
		events = append(events, padEvent{kind: padMove, dir: d})
	}
	for _, m := range []struct {
		bit  uint16
		kind padKind
	}{
		{padA, padActivate}, {padB, padCancel}, {padLB, padPrevSection}, {padRB, padNextSection}, {padStart, padPrimary},
	} {
		if pressed&m.bit != 0 {
			events = append(events, padEvent{kind: m.kind})
		}
	}
	return events, scroll
}

// direction: the D-pad wins over the stick.
func (p *padNav) direction(buttons uint16) navDir {
	if d := dpadDir(buttons); d != dirNone {
		return d
	}
	return p.stick
}

// spatialPick returns the index of the candidate nearest to from in
// direction d, or -1. A candidate qualifies when its centre lies beyond
// from's centre in d; the score is the gap along d plus the offset across
// it (0 when the two overlap on that axis), so aligned neighbours win.
func spatialPick(from rect, candidates []rect, d navDir) int {
	fx, fy := from.Left+from.w()/2, from.Top+from.h()/2
	best, bestScore := -1, int64(math.MaxInt64)
	for i, c := range candidates {
		cx, cy := c.Left+c.w()/2, c.Top+c.h()/2
		var major, minor int32
		switch d {
		case dirUp:
			if cy >= fy {
				continue
			}
			major, minor = from.Top-c.Bottom, gap(from.Left, from.Right, c.Left, c.Right)
		case dirDown:
			if cy <= fy {
				continue
			}
			major, minor = c.Top-from.Bottom, gap(from.Left, from.Right, c.Left, c.Right)
		case dirLeft:
			if cx >= fx {
				continue
			}
			major, minor = from.Left-c.Right, gap(from.Top, from.Bottom, c.Top, c.Bottom)
		case dirRight:
			if cx <= fx {
				continue
			}
			major, minor = c.Left-from.Right, gap(from.Top, from.Bottom, c.Top, c.Bottom)
		default:
			return -1
		}
		score := int64(max(major, 0)) + int64(minor)
		if score < bestScore {
			best, bestScore = i, score
		}
	}
	return best
}

// gap is the distance between two intervals, 0 when they overlap.
func gap(a0, a1, b0, b1 int32) int32 {
	switch {
	case b1 <= a0:
		return a0 - b1
	case b0 >= a1:
		return b0 - a1
	}
	return 0
}

// Sections that LB/RB cycle through, in RB order.
const (
	sectionBody = iota
	sectionActions
	sectionHeader
	sectionCount
)

// padSection classifies a focusable widget id.
func padSection(id string) int {
	switch {
	case strings.HasPrefix(id, "header."):
		return sectionHeader
	case strings.HasPrefix(id, "action.") || id == "confirm.go" || id == "startup.close":
		return sectionActions
	}
	return sectionBody
}

// sectionTarget returns the first id (in focus order) of the next non-empty
// section in direction dir (+1 RB, -1 LB) from the section of focus, or ""
// when there is no other section.
func sectionTarget(ids []string, focus string, dir int) string {
	present := [sectionCount]string{}
	for _, id := range ids {
		if s := padSection(id); present[s] == "" {
			present[s] = id
		}
	}
	current := sectionBody
	if focus != "" {
		current = padSection(focus)
	}
	for step := 1; step < sectionCount; step++ {
		s := ((current+dir*step)%sectionCount + sectionCount) % sectionCount
		if present[s] != "" {
			return present[s]
		}
	}
	return ""
}
