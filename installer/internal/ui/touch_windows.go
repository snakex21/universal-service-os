//go:build windows

package ui

import (
	"time"
	"unsafe"
)

// Touch and pen input (WM_POINTER*, Windows 8+). Mouse input stays on the
// classic WM_MOUSE* messages: EnableMouseInPointer is never called, and a
// PT_MOUSE pointer message goes to DefWindowProc. Touch and pen are handled
// here and the message is consumed, so Windows synthesizes no mouse
// messages and nothing fires twice. A tap is a click; a drag pans the
// scrolling area under the finger (the content follows the finger) and a
// quick release flings it. Touches on the native EDITs go to those child
// windows, which handle them themselves (the touch keyboard included).
// On Windows 7 no WM_POINTER arrives and touch keeps working through the
// system's mouse emulation.

const flingTimerID = 3

var procGetPointerType = user32.NewProc("GetPointerType")

type touchState struct {
	tracker touchTracker
	region  string // scroll region the finger pans, "" none
	thumb   bool   // the finger grabbed a scrollbar thumb: behave like a mouse drag
	fling   fling
	flingID string
	flingAt time.Time
}

// pointerType returns PT_TOUCH, PT_PEN, PT_MOUSE, ... or 0 when unknown.
func pointerType(wParam uintptr) uint32 {
	if procGetPointerType.Find() != nil {
		return 0
	}
	var t uint32
	if r, _, _ := procGetPointerType.Call(wParam&0xffff, uintptr(unsafe.Pointer(&t))); r == 0 {
		return 0
	}
	return t
}

// pointer handles a WM_POINTER* message; false hands it to DefWindowProc.
func (w *win) pointer(message uint32, wParam, lParam uintptr) bool {
	if t := pointerType(wParam); t != ptTouch && t != ptPen {
		return false
	}
	if w.scripted {
		return true // a scripted tour ignores real input
	}
	id := uint32(wParam & 0xffff)
	pt := point{loWord(lParam), hiWord(lParam)}
	procScreenToClient.Call(uintptr(w.hwnd), uintptr(unsafe.Pointer(&pt)))
	ts := &w.touch
	now := time.Now()
	slop := w.px(touchSlopDIP)
	switch message {
	case wmPointerDown:
		if ts.tracker.active {
			return true // one finger at a time; later fingers are ignored
		}
		w.stopFling()
		w.setPadActive(false)
		w.cues = false
		ts.tracker.down(id, pt.X, pt.Y, now)
		ts.region, ts.thumb = "", false
		hit := w.hitTest(pt.X, pt.Y)
		if wd := w.findLast(hit); wd != nil && wd.drag != nil && !wd.disabled {
			ts.thumb = true
			w.mouseDown(pt.X, pt.Y)
			return true
		}
		ts.region = w.scrollableAt(pt.X, pt.Y)
		// Pressed feedback while the finger is down; hover is never shown
		// for touch.
		if wd := w.findLast(hit); wd != nil && !wd.disabled && wd.onClick != nil {
			w.hot, w.pressed = hit, hit
		}
		w.invalidate()
	case wmPointerUpdate:
		if !ts.tracker.active || id != ts.tracker.id {
			return true
		}
		if ts.thumb {
			w.mouseMove(pt.X, pt.Y)
			return true
		}
		dy, started := ts.tracker.move(pt.X, pt.Y, slop, now)
		if started {
			w.hot, w.pressed = "", "" // a drag is not a tap
			w.invalidate()
		}
		if s := w.scrolls[ts.region]; s != nil && dy != 0 {
			s.offset -= dy
			s.clamp()
			w.invalidate()
		}
	case wmPointerUp:
		if !ts.tracker.active || id != ts.tracker.id {
			return true
		}
		if ts.thumb {
			ts.tracker.cancel()
			w.mouseUp(pt.X, pt.Y)
			w.hot = ""
			return true
		}
		tap, v := ts.tracker.up(pt.X, pt.Y, slop, now)
		w.hot, w.pressed = "", ""
		if tap {
			// The same path as a mouse click: focus, capture, onClick. The
			// mouse position is restored so the tapped widget is not left
			// looking hovered.
			mouse := w.mouse
			w.mouseDown(pt.X, pt.Y)
			w.mouseUp(pt.X, pt.Y)
			w.mouse, w.hot = mouse, ""
		} else if ts.region != "" {
			scale := float64(w.dpi) / 96
			if f, ok := newFling(v, flingStartDIP*scale, flingStopDIP*scale); ok {
				ts.fling, ts.flingID, ts.flingAt = f, ts.region, now
				procSetTimer.Call(uintptr(w.hwnd), flingTimerID, 16, 0)
			}
		}
		w.invalidate()
	case wmPointerCaptureChange:
		ts.tracker.cancel()
		if ts.thumb {
			w.dragging = nil
		}
		w.hot, w.pressed = "", ""
		w.invalidate()
	}
	return true
}

// scrollableAt returns the innermost scroll region under (x, y) whose
// content overflows, or "".
func (w *win) scrollableAt(x, y int32) string {
	if !w.overlay.empty() && !w.overlay.contains(x, y) {
		return ""
	}
	for i := len(w.lastRegs) - 1; i >= 0; i-- {
		region := w.lastRegs[i]
		if !region.r.contains(x, y) {
			continue
		}
		if s := w.scrolls[region.id]; s != nil && s.content > s.view {
			return region.id
		}
		return ""
	}
	return ""
}

func (w *win) flingTick() {
	ts := &w.touch
	s := w.scrolls[ts.flingID]
	now := time.Now()
	dt := float64(now.Sub(ts.flingAt)) / float64(time.Millisecond)
	ts.flingAt = now
	if s == nil {
		w.stopFling()
		return
	}
	px, done := ts.fling.step(dt)
	before := s.offset
	s.offset -= px
	s.clamp()
	w.invalidate()
	if done || (px != 0 && s.offset == before) { // ran out or hit an end
		w.stopFling()
	}
}

func (w *win) stopFling() {
	if w.touch.flingID != "" {
		procKillTimer.Call(uintptr(w.hwnd), flingTimerID)
		w.touch.flingID = ""
	}
}
