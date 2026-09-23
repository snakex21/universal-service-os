//go:build windows

package ui

import (
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// XInput gamepad support (Xbox-compatible pads, the ROG Ally's built-in
// controller in gamepad mode). xinput1_4.dll ships with Windows 8+,
// xinput9_1_0.dll with Vista/7; without either the pad is simply ignored.
//
// Mapping: D-pad / left stick move the focus (hold repeats), A activates
// like Enter, B goes back like Esc, LB/RB jump between the page, its action
// bar and the header, Start presses the screen's main button and the right
// stick scrolls. Start never commits an operation: on a confirmation screen
// it only moves the focus to the confirm button, which then needs A (and,
// for installs and uninstalls, the typed model name as always).

const (
	padTimerID       = 2
	padFastPoll      = 16   // ms while a pad is connected
	padSlowPoll      = 1000 // ms while looking for one
	errNotConnected  = 1167 // ERROR_DEVICE_NOT_CONNECTED
	padScrollDIPTick = 18   // right stick fully deflected, per fast poll
)

type xinputState struct {
	PacketNumber uint32
	Buttons      uint16
	LeftTrigger  uint8
	RightTrigger uint8
	ThumbLX      int16
	ThumbLY      int16
	ThumbRX      int16
	ThumbRY      int16
}

type gamepad struct {
	probed   bool
	getState *windows.LazyProc // nil: no XInput on this system
	index    int               // connected user index, -1 none
	nav      padNav
	interval uint32 // current timer period, 0 = stopped
	active   bool   // the last input came from the pad: show hints
	scrollAt float64
}

func (p *gamepad) load() {
	if p.probed {
		return
	}
	p.probed, p.index = true, -1
	for _, name := range []string{"xinput1_4.dll", "xinput9_1_0.dll"} {
		dll := windows.NewLazySystemDLL(name)
		if dll.Load() != nil {
			continue
		}
		if proc := dll.NewProc("XInputGetState"); proc.Find() == nil {
			p.getState = proc
			return
		}
	}
}

func (p *gamepad) read(index int) (padSample, bool) {
	var st xinputState
	r, _, _ := p.getState.Call(uintptr(index), uintptr(unsafe.Pointer(&st)))
	if r != 0 { // ERROR_DEVICE_NOT_CONNECTED or anything else: no pad here
		return padSample{}, false
	}
	return padSample{buttons: st.Buttons, lx: st.ThumbLX, ly: st.ThumbLY, rx: st.ThumbRX, ry: st.ThumbRY}, true
}

// padPolling starts or stops the poll timer; the pad is only read while the
// installer is the foreground window.
func (w *win) padPolling(on bool) {
	if w.scripted {
		on = false // real pad input must not disturb a scripted tour
	}
	p := &w.pad
	if on {
		p.load()
		if p.getState == nil {
			on = false
		}
	}
	if !on {
		if p.interval != 0 {
			procKillTimer.Call(uintptr(w.hwnd), padTimerID)
			p.interval = 0
		}
		p.nav.reset() // buttons held while away must not fire on return
		return
	}
	period := uint32(padSlowPoll)
	if p.index >= 0 {
		period = padFastPoll
	}
	if p.interval != period {
		procSetTimer.Call(uintptr(w.hwnd), padTimerID, uintptr(period), 0)
		p.interval = period
	}
}

func (w *win) padTick() {
	p := &w.pad
	if fg, _, _ := procGetForegroundWindow.Call(); w.scripted || windows.HWND(fg) != w.hwnd {
		w.padPolling(false)
		return
	}
	if p.index < 0 {
		// Probing an empty slot is slow, so the four slots are only scanned
		// on the slow timer.
		for i := 0; i < 4; i++ {
			if _, ok := p.read(i); ok {
				p.index = i
				p.nav.reset()
				break
			}
		}
		w.padPolling(true)
		return
	}
	s, ok := p.read(p.index)
	if !ok {
		p.index = -1
		p.nav.reset()
		w.setPadActive(false)
		w.padPolling(true)
		return
	}
	events, scroll := p.nav.step(s, time.Now())
	for _, e := range events {
		w.padEvent(e)
	}
	if scroll != 0 {
		w.padScroll(scroll)
	} else {
		p.scrollAt = 0
	}
}

// setPadActive shows or hides the controller hints (and with them the
// focus ring the pad relies on).
func (w *win) setPadActive(on bool) {
	if w.pad.active != on {
		w.pad.active = on
		w.invalidate()
	}
}

func (w *win) padEvent(e padEvent) {
	w.setPadActive(true)
	w.cues = true
	defer w.invalidate()
	menu := !w.overlay.empty() // the language menu is open and modal
	switch e.kind {
	case padMove:
		if menu {
			switch e.dir {
			case dirUp:
				w.handleKey(vkUp, false)
			case dirDown:
				w.handleKey(vkDown, false)
			}
			return
		}
		w.padMove(e.dir)
	case padActivate:
		if !menu && w.findFocusable(w.focus) == nil {
			w.focusFirst()
			return
		}
		w.handleKey(vkReturn, false)
	case padCancel:
		w.handleKey(vkEscape, false)
	case padPrevSection, padNextSection:
		if menu {
			return
		}
		dir := 1
		if e.kind == padPrevSection {
			dir = -1
		}
		var ids []string
		for i := range w.last {
			if wd := &w.last[i]; wd.focusable && !wd.disabled {
				ids = append(ids, wd.id)
			}
		}
		if id := sectionTarget(ids, w.focus, dir); id != "" {
			w.setFocusID(id)
		}
	case padPrimary:
		if !menu {
			w.padPrimary()
		}
	}
}

func (w *win) findFocusable(id string) *widget {
	if wd := w.findLast(id); wd != nil && wd.focusable && !wd.disabled {
		return wd
	}
	return nil
}

func (w *win) focusFirst() {
	for i := range w.last {
		if wd := &w.last[i]; wd.focusable && !wd.disabled {
			w.setFocusWidget(wd)
			return
		}
	}
}

// padMove lets the focused widget use the direction first (a drive list
// walks its rows) and otherwise moves the focus to the nearest widget in
// that direction on screen.
func (w *win) padMove(d navDir) {
	cur := w.findFocusable(w.focus)
	if cur == nil {
		w.focusFirst()
		return
	}
	if cur.padStep != nil && cur.padStep(d) {
		return
	}
	var cands []*widget
	var rects []rect
	for i := range w.last {
		wd := &w.last[i]
		if wd.focusable && !wd.disabled && wd.id != cur.id && !wd.r.empty() {
			cands = append(cands, wd)
			rects = append(rects, wd.r)
		}
	}
	if i := spatialPick(cur.r, rects, d); i >= 0 {
		w.setFocusWidget(cands[i])
	}
}

// padPrimary presses the screen's main button (the right-most action), or,
// when that button starts an operation or is destructive, only focuses it.
func (w *win) padPrimary() {
	var primary *widget
	for i := range w.last {
		if w.last[i].primary {
			primary = &w.last[i]
		}
	}
	if primary == nil || primary.disabled {
		return
	}
	if primary.guarded || primary.onClick == nil {
		w.setFocusWidget(primary)
		return
	}
	primary.onClick()
}

// padScroll scrolls with the right stick: the region holding the focus if
// it overflows, else the first region on screen that does.
func (w *win) padScroll(v float64) {
	target := w.padScrollTarget()
	if target == "" {
		return
	}
	s := w.scrolls[target]
	w.pad.scrollAt += v * float64(w.px(padScrollDIPTick))
	px := int32(w.pad.scrollAt)
	if px == 0 {
		return
	}
	w.pad.scrollAt -= float64(px)
	s.offset -= px
	s.clamp()
	w.setPadActive(true)
	w.invalidate()
}

func (w *win) padScrollTarget() string {
	overflows := func(id string) bool {
		s := w.scrolls[id]
		return s != nil && s.content > s.view
	}
	menu := !w.overlay.empty()
	if !menu {
		if wd := w.findLast(w.focus); wd != nil && wd.scrollID != "" && overflows(wd.scrollID) {
			return wd.scrollID
		}
	}
	for _, region := range w.lastRegs {
		if menu != (region.id == "lang.scroll") {
			continue
		}
		if overflows(region.id) {
			return region.id
		}
	}
	return ""
}

var procGetForegroundWindow = user32.NewProc("GetForegroundWindow")
