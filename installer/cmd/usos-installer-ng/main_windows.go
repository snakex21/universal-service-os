//go:build windows

// usos-installer-ng is a proof of concept for a lighter installer GUI: a plain
// Win32 window (golang.org/x/sys/windows, no cgo, no OpenGL) drawn in the USOS
// boot-UI style into a DIB and blitted with StretchDIBits. It implements only
// the language-picker step; the Fyne installer (cmd/usos-installer) stays the
// production UI.
//
//	usos-installer-ng.exe                 run interactively
//	usos-installer-ng.exe -measure FILE   exit after the first frame, write timings
package main

import (
	"flag"
	"fmt"
	"os"
	"runtime"
	"time"
	"unsafe"

	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"golang.org/x/sys/windows"
)

type focusTarget int

const (
	focusList focusTarget = iota
	focusNext
)

type app struct {
	hwnd      windows.HWND
	dpi       uint32
	canvas    *canvas
	fonts     struct{ brand, title, body, small, row windows.Handle }
	languages []i18n.Language
	detected  string
	selected  int
	hover     int // row index, -2 = Next button, -1 = none
	pressed   bool
	focus     focusTarget
	tracking  bool
	confirmed bool
	rows      []rect
	next      rect
	awareness string
	measure   string
	started   time.Time
	painted   bool
}

var state app

func main() {
	runtime.LockOSThread()
	measure := flag.String("measure", "", "write first-frame timings to this file and exit")
	flag.Parse()
	state.measure = *measure
	state.started = processStart()
	state.awareness = enableDPIAwareness()
	state.detected = i18n.SetLanguage(i18n.SystemLanguage())
	state.languages = i18n.Languages()
	for i, language := range state.languages {
		if language.Code == state.detected {
			state.selected = i
		}
	}
	state.hover = -1

	instance, _, _ := procGetModuleHandleW.Call(0)
	cursor, _, _ := procLoadCursorW.Call(0, idcArrow)
	className := utf16Ptr("USOSInstallerNG")
	class := wndClassEx{
		Size:      uint32(unsafe.Sizeof(wndClassEx{})),
		Style:     0x0003, // CS_HREDRAW | CS_VREDRAW
		WndProc:   windows.NewCallback(wndProc),
		Instance:  windows.Handle(instance),
		Cursor:    windows.Handle(cursor),
		ClassName: className,
	}
	if r, _, err := procRegisterClassExW.Call(uintptr(unsafe.Pointer(&class))); r == 0 {
		fail("RegisterClassExW: %v", err)
	}
	hwnd, _, err := procCreateWindowExW.Call(0, uintptr(unsafe.Pointer(className)), uintptr(unsafe.Pointer(utf16Ptr(i18n.T("installer.window.title")))),
		wsOverlappedWindow, cwUseDefault, cwUseDefault, 800, 560, 0, 0, instance, 0)
	if hwnd == 0 {
		fail("CreateWindowExW: %v", err)
	}
	state.hwnd = windows.HWND(hwnd)
	state.setDPI(windowDPI(state.hwnd))
	// Size the client area in device-independent pixels for the current DPI.
	r := rect{0, 0, state.px(760), state.px(540)}
	procAdjustWindowRectEx.Call(uintptr(unsafe.Pointer(&r)), wsOverlappedWindow, 0, 0)
	procSetWindowPos.Call(hwnd, 0, 0, 0, uintptr(r.Right-r.Left), uintptr(r.Bottom-r.Top), swpNoZOrder|swpNoMove|swpNoActivate)
	procShowWindow.Call(hwnd, swShow)

	var m msg
	for {
		r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 {
			break
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		procDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
	}
	if state.confirmed {
		// The PoC stops here; a full port would continue to the mode screen.
		fmt.Println("language=" + i18n.Current())
	}
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}

func (a *app) px(dip int32) int32 { return int32((int64(dip)*int64(a.dpi) + 48) / 96) }

func (a *app) setDPI(dpi uint32) {
	if dpi == 0 {
		dpi = 96
	}
	a.dpi = dpi
	for _, f := range []windows.Handle{a.fonts.brand, a.fonts.title, a.fonts.body, a.fonts.small, a.fonts.row} {
		if f != 0 {
			procDeleteObject.Call(uintptr(f))
		}
	}
	a.fonts.brand = createFont(a.px(13), fwBold)
	a.fonts.title = createFont(a.px(28), fwSemiBold)
	a.fonts.body = createFont(a.px(15), fwNormal)
	a.fonts.small = createFont(a.px(13), fwNormal)
	a.fonts.row = createFont(a.px(17), fwSemiBold)
}

func wndProc(hwnd windows.HWND, message uint32, wParam, lParam uintptr) uintptr {
	a := &state
	switch message {
	case wmEraseBkgnd:
		return 1
	case wmPaint:
		a.paint(hwnd)
		return 0
	case wmSize:
		invalidate(hwnd)
		return 0
	case wmDpiChanged:
		a.setDPI(uint32(hiWord(wParam)))
		suggested := *(**rect)(unsafe.Pointer(&lParam)) // lParam is a RECT* owned by Windows
		procSetWindowPos.Call(uintptr(hwnd), 0, uintptr(suggested.Left), uintptr(suggested.Top),
			uintptr(suggested.Right-suggested.Left), uintptr(suggested.Bottom-suggested.Top), swpNoZOrder|swpNoActivate)
		invalidate(hwnd)
		return 0
	case wmMouseMove:
		if !a.tracking {
			tme := trackMouseEvent{Size: uint32(unsafe.Sizeof(trackMouseEvent{})), Flags: tmeLeave, Track: hwnd}
			procTrackMouseEvent.Call(uintptr(unsafe.Pointer(&tme)))
			a.tracking = true
		}
		if hover := a.hitTest(loWord(lParam), hiWord(lParam)); hover != a.hover {
			a.hover = hover
			invalidate(hwnd)
		}
		return 0
	case wmMouseLeave:
		a.tracking, a.hover, a.pressed = false, -1, false
		invalidate(hwnd)
		return 0
	case wmSetCursor:
		if a.hover != -1 && loWord(lParam) == 1 { // HTCLIENT
			cursor, _, _ := procLoadCursorW.Call(0, idcHand)
			procSetCursor.Call(cursor)
			return 1
		}
	case wmLButtonDown:
		a.pressed = a.hitTest(loWord(lParam), hiWord(lParam)) == -2
		if hit := a.hitTest(loWord(lParam), hiWord(lParam)); hit >= 0 {
			a.focus = focusList
			a.choose(hit)
		}
		invalidate(hwnd)
		return 0
	case wmLButtonUp:
		if a.pressed && a.hitTest(loWord(lParam), hiWord(lParam)) == -2 {
			a.confirm()
		}
		a.pressed = false
		invalidate(hwnd)
		return 0
	case wmKeyDown:
		switch wParam {
		case vkUp:
			a.focus = focusList
			a.choose(max(a.selected-1, 0))
		case vkDown:
			a.focus = focusList
			a.choose(min(a.selected+1, len(a.languages)-1))
		case vkTab:
			if a.focus == focusList {
				a.focus = focusNext
			} else {
				a.focus = focusList
			}
		case vkReturn:
			a.confirm()
		case vkSpace:
			if a.focus == focusNext {
				a.confirm()
			}
		case vkEscape:
			procDestroyWindow.Call(uintptr(hwnd))
		}
		invalidate(hwnd)
		return 0
	case wmClose:
		procDestroyWindow.Call(uintptr(hwnd))
		return 0
	case wmDestroy:
		procPostQuitMessage.Call(0)
		return 0
	}
	r, _, _ := procDefWindowProcW.Call(uintptr(hwnd), uintptr(message), wParam, lParam)
	return r
}

// choose switches the UI language immediately, like the Fyne picker.
func (a *app) choose(index int) {
	if index < 0 || index >= len(a.languages) {
		return
	}
	a.selected = index
	i18n.SetLanguage(a.languages[index].Code)
	procSetWindowTextW.Call(uintptr(a.hwnd), uintptr(unsafe.Pointer(utf16Ptr(i18n.T("installer.window.title")))))
}

func (a *app) confirm() {
	a.confirmed = true
	procDestroyWindow.Call(uintptr(a.hwnd))
}

func (a *app) hitTest(x, y int32) int {
	if a.next.contains(x, y) {
		return -2
	}
	for i, r := range a.rows {
		if r.contains(x, y) {
			return i
		}
	}
	return -1
}

func languageName(code string, languages []i18n.Language) string {
	for _, language := range languages {
		if language.Code == code {
			return language.Name
		}
	}
	return code
}

func (a *app) paint(hwnd windows.HWND) {
	var ps paintStruct
	hdc, _, _ := procBeginPaint.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&ps)))
	client := clientRect(hwnd)
	if a.canvas == nil || a.canvas.width != client.Right || a.canvas.height != client.Bottom {
		a.canvas.release()
		a.canvas = newCanvas(client.Right, client.Bottom)
	}
	a.layoutAndDraw(a.canvas)
	a.canvas.blit(windows.Handle(hdc))
	procEndPaint.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&ps)))
	if !a.painted {
		a.painted = true
		if a.measure != "" {
			a.writeMeasurement()
			procDestroyWindow.Call(uintptr(hwnd))
		}
	}
}

// layoutAndDraw renders the language step in the boot UI's visual language:
// dark background, 5 px accent rule, bordered panels, selected rows in the
// "selected" colour with an accent border.
func (a *app) layoutAndDraw(c *canvas) {
	w, h := c.width, c.height
	margin := a.px(32)
	c.fill(rect{0, 0, w, h}, theme.Background)
	c.fill(rect{0, 0, w, a.px(5)}, theme.Accent)

	y := a.px(24)
	c.text(a.fonts.brand, "UNIVERSAL SERVICE OS", rect{margin, y, w - margin, y + a.px(18)}, theme.Accent, dtLeft|dtSingleLine|dtVCenter)
	y += a.px(24)
	c.text(a.fonts.title, i18n.T("installer.language.title"), rect{margin, y, w - margin, y + a.px(40)}, theme.Text, dtLeft|dtSingleLine|dtVCenter)
	y += a.px(48)
	description := i18n.T("installer.language.description")
	descHeight := c.measure(a.fonts.body, description, w-2*margin)
	c.text(a.fonts.body, description, rect{margin, y, w - margin, y + descHeight}, theme.Muted, dtLeft|dtWordBreak)
	y += descHeight + a.px(10)
	c.text(a.fonts.small, i18n.T("installer.language.detected", languageName(a.detected, a.languages)), rect{margin, y, w - margin, y + a.px(20)}, theme.Accent, dtLeft|dtSingleLine|dtVCenter)
	y += a.px(28)
	c.fill(rect{margin, y, w - margin, y + 1}, theme.Border)
	y += a.px(16)

	rowHeight := a.px(48)
	gap := a.px(8)
	a.rows = a.rows[:0]
	for i, language := range a.languages {
		r := rect{margin, y, w - margin, y + rowHeight}
		a.rows = append(a.rows, r)
		selected := i == a.selected
		background := theme.Panel
		borderColor := theme.Border
		thickness := int32(1)
		if a.hover == i {
			background = theme.PanelAlt
		}
		if selected {
			background, borderColor, thickness = theme.Selected, theme.Accent, a.px(2)
		}
		c.fill(r, background)
		c.border(r, thickness, borderColor)
		// Radio marker: square like the boot UI icon tiles.
		marker := a.px(14)
		mx, my := r.Left+a.px(16), r.Top+(rowHeight-marker)/2
		c.border(rect{mx, my, mx + marker, my + marker}, max(a.px(1), 1), theme.Accent)
		if selected {
			inset := a.px(3)
			c.fill(rect{mx + inset, my + inset, mx + marker - inset, my + marker - inset}, theme.Accent)
		}
		c.text(a.fonts.row, language.Name, rect{mx + marker + a.px(16), r.Top, r.Right - a.px(80), r.Bottom}, theme.Text, dtLeft|dtSingleLine|dtVCenter|dtEndEllipse)
		c.text(a.fonts.small, language.Code, rect{r.Right - a.px(80), r.Top, r.Right - a.px(16), r.Bottom}, theme.Muted, dtRight|dtSingleLine|dtVCenter)
		if selected && a.focus == focusList {
			c.border(rect{r.Left - a.px(3), r.Top - a.px(3), r.Right + a.px(3), r.Bottom + a.px(3)}, 1, theme.Muted)
		}
		y += rowHeight + gap
	}

	buttonWidth, buttonHeight := a.px(150), a.px(42)
	a.next = rect{w - margin - buttonWidth, h - margin - buttonHeight, w - margin, h - margin}
	buttonColor := theme.Accent
	if a.hover == -2 {
		buttonColor = color{0x6c, 0xe4, 0xf0}
	}
	if a.pressed {
		buttonColor = color{0x2f, 0xb4, 0xc4}
	}
	c.fill(a.next, buttonColor)
	if a.focus == focusNext {
		c.border(rect{a.next.Left - a.px(3), a.next.Top - a.px(3), a.next.Right + a.px(3), a.next.Bottom + a.px(3)}, 1, theme.Text)
	}
	c.text(a.fonts.row, i18n.T("installer.common.next"), a.next, theme.Background, dtCenter|dtSingleLine|dtVCenter)
	c.text(a.fonts.small, i18n.T("installer.ng.keys_hint"), rect{margin, a.next.Top, a.next.Left - a.px(16), a.next.Bottom}, theme.Muted, dtLeft|dtSingleLine|dtVCenter|dtEndEllipse)
}

func processStart() time.Time {
	var creation, exit, kernel, user windows.Filetime
	if err := windows.GetProcessTimes(windows.CurrentProcess(), &creation, &exit, &kernel, &user); err != nil {
		return time.Now()
	}
	return time.Unix(0, creation.Nanoseconds())
}

func (a *app) writeMeasurement() {
	var counters processMemoryCounters
	counters.Size = uint32(unsafe.Sizeof(counters))
	procK32GetProcessMemoryInfo.Call(uintptr(windows.CurrentProcess()), uintptr(unsafe.Pointer(&counters)), uintptr(counters.Size))
	report := fmt.Sprintf("first_frame_ms=%d\nworking_set_kb=%d\nprivate_kb=%d\ndpi=%d\nawareness=%s\nlanguage=%s\n",
		time.Since(a.started).Milliseconds(), counters.WorkingSetSize/1024, counters.PagefileUsage/1024, a.dpi, a.awareness, i18n.Current())
	_ = os.WriteFile(a.measure, []byte(report), 0o644)
}
