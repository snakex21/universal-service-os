//go:build windows

package ui

import (
	"fmt"
	"image"
	"runtime"
	"strings"
	"sync"
	"unsafe"

	"github.com/snakex21/universal-service-os/installer/internal/ui/logo"
	"golang.org/x/sys/windows"
)

// The window is drawn in immediate mode: every WM_PAINT the root view lays
// out and draws the whole client area and registers its interactive widgets
// (id, rect, callbacks). Mouse and keyboard input is resolved against the
// widgets of the last frame, so there is no retained widget tree to keep in
// sync with the flow state. Text input and the selectable log use native
// EDIT controls hosted as child windows.

// Default and minimum client sizes in device-independent pixels. The default
// window (client plus frame) fits a 1366x768 screen with a taskbar at 100 %.
const (
	defaultClientW = 1100
	defaultClientH = 660
	minClientW     = 860
	minClientH     = 560
	animTimerID    = 1
	animInterval   = 40 // ms
)

type rootView interface {
	draw(w *win)
	// key handles a key press. pre is true for the first pass (overlays),
	// false for the second pass after the focused widget declined the key.
	key(w *win, vk uintptr, pre bool) bool
	canClose() bool
	closeBlocked()
	languageChanged()
}

type widget struct {
	id        string
	r         rect // visible (clipped) hit area
	full      rect // unclipped rect, for scrolling into view
	scrollID  string
	focusable bool
	disabled  bool
	onClick   func()
	onKey     func(vk uintptr) bool
	edit      *nativeEdit
	drag      *dragHandler
}

type widgetState struct {
	hot, pressed, focused, ring bool
}

type dragHandler struct {
	begin func()
	move  func(dy int32)
}

type scrollState struct {
	offset  int32
	content int32
	view    int32
}

type scrollRegion struct {
	id string
	r  rect
}

type nativeEdit struct {
	id        string
	hwnd      windows.HWND
	ctrlID    uintptr
	multiline bool
	mono      bool
	placed    rect
	shown     bool
	used      bool
	disabled  bool
	onChange  func(string)
	fontSize  int32
}

type editOptions struct {
	multiline bool
	readonly  bool
	mono      bool
	disabled  bool
	cue       string
	initial   string
	fontSize  int32
	onChange  func(string)
}

type fontKey struct {
	face    string
	size    int32
	weight  int32
	quality uintptr
}

type windowOptions struct {
	forcedDPI uint32 // test harness: lay out as if the monitor had this DPI
	clientW   int32  // DIP; 0 = default
	clientH   int32
}

type win struct {
	hwnd      windows.HWND
	instance  uintptr
	dpi       uint32
	opts      windowOptions
	canvas    *canvas
	fonts     map[fontKey]windows.Handle
	stock     map[[2]int32]windows.Handle
	logos     map[int32]*image.RGBA
	appIcons  [2]windows.Handle
	root      rootView
	destroyed bool

	frame, last       []widget
	regions, lastRegs []scrollRegion
	scrollStack       []string
	hot, pressed      string
	focus             string
	cues              bool
	mouse             point
	mouseIn           bool
	tracking          bool
	dragging          *dragHandler
	dragOrigin        int32

	scrolls    map[string]*scrollState
	edits      map[string]*nativeEdit
	editByCtrl map[uintptr]*nativeEdit
	nextCtrlID uintptr
	fieldBrush windows.Handle
	overlay    rect

	queueMu sync.Mutex
	queue   []func()

	animate bool
	timerOn bool
	painted []func()
	onFrame func() // test harness hook, runs after every frame
	// scripted is set by the screenshot harness: real mouse input is ignored
	// so the operator's cursor cannot disturb a scripted hover state.
	scripted bool
}

var (
	activeWin   *win
	wndProcAddr = windows.NewCallback(func(hwnd windows.HWND, message uint32, wParam, lParam uintptr) uintptr {
		if activeWin != nil {
			return activeWin.wndProc(hwnd, message, wParam, lParam)
		}
		r, _, _ := procDefWindowProcW.Call(uintptr(hwnd), uintptr(message), wParam, lParam)
		return r
	})
)

func newWin(title string, root rootView, opts windowOptions) (*win, error) {
	runtime.LockOSThread()
	enableDPIAwareness()
	initCommonControls()
	w := &win{
		root:       root,
		opts:       opts,
		fonts:      map[fontKey]windows.Handle{},
		stock:      map[[2]int32]windows.Handle{},
		logos:      map[int32]*image.RGBA{},
		scrolls:    map[string]*scrollState{},
		edits:      map[string]*nativeEdit{},
		editByCtrl: map[uintptr]*nativeEdit{},
		nextCtrlID: 100,
		dpi:        96,
	}
	activeWin = w
	w.fieldBrush = func() windows.Handle {
		h, _, _ := procCreateSolidBrush.Call(theme.Field.colorref())
		return windows.Handle(h)
	}()
	w.instance, _, _ = procGetModuleHandleW.Call(0)
	cursor, _, _ := procLoadCursorW.Call(0, idcArrow)
	className := utf16Ptr("USOSInstallerWindow")
	class := wndClassEx{
		Size:      uint32(unsafe.Sizeof(wndClassEx{})),
		Style:     csHRedraw | csVRedraw,
		WndProc:   wndProcAddr,
		Instance:  windows.Handle(w.instance),
		Cursor:    windows.Handle(cursor),
		ClassName: className,
	}
	if r, _, err := procRegisterClassExW.Call(uintptr(unsafe.Pointer(&class))); r == 0 {
		return nil, fmt.Errorf("RegisterClassExW: %w", err)
	}
	hwnd, _, err := procCreateWindowExW.Call(0, uintptr(unsafe.Pointer(className)), uintptr(unsafe.Pointer(utf16Ptr(title))),
		wsOverlappedWindow|wsClipChildren, cwUseDefault, cwUseDefault, 800, 600, 0, 0, w.instance, 0)
	if hwnd == 0 {
		return nil, fmt.Errorf("CreateWindowExW: %w", err)
	}
	w.hwnd = windows.HWND(hwnd)
	useDarkTitleBar(w.hwnd)
	w.setDPI(windowDPI(w.hwnd))
	w.placeInitial()
	return w, nil
}

func (w *win) show() {
	procShowWindow.Call(uintptr(w.hwnd), swShow)
	procUpdateWindow.Call(uintptr(w.hwnd))
	procSetForegroundWindow.Call(uintptr(w.hwnd))
}

// placeInitial sizes the client area in DIPs, shrinks it to the monitor work
// area if needed, and centres the window on that monitor.
func (w *win) placeInitial() {
	cw, ch := int32(defaultClientW), int32(defaultClientH)
	if w.opts.clientW > 0 && w.opts.clientH > 0 {
		cw, ch = w.opts.clientW, w.opts.clientH
	}
	r := rect{0, 0, w.px(cw), w.px(ch)}
	adjustWindowRect(&r, wsOverlappedWindow, w.systemDPI())
	width, height := r.w(), r.h()
	x, y := int32(0), int32(0)
	if work, ok := monitorWorkArea(w.hwnd); ok {
		width, height = min(width, work.w()), min(height, work.h())
		x = work.Left + (work.w()-width)/2
		y = work.Top + (work.h()-height)/2
	}
	procSetWindowPos.Call(uintptr(w.hwnd), 0, uintptr(x), uintptr(y), uintptr(width), uintptr(height), swpNoZOrder|swpNoActivate)
}

// systemDPI is the real DPI of the window's monitor (frame metrics follow
// it even when the layout DPI is forced by the test harness).
func (w *win) systemDPI() uint32 { return windowDPI(w.hwnd) }

func (w *win) setDPI(dpi uint32) {
	if w.opts.forcedDPI != 0 {
		dpi = w.opts.forcedDPI
	}
	if dpi == 0 {
		dpi = 96
	}
	w.dpi = dpi
	for key, font := range w.fonts {
		procDeleteObject.Call(uintptr(font))
		delete(w.fonts, key)
	}
	for key, icon := range w.stock {
		procDestroyIcon.Call(uintptr(icon))
		delete(w.stock, key)
	}
	for key := range w.logos {
		delete(w.logos, key)
	}
	for _, e := range w.edits {
		sendMessage(e.hwnd, wmSetFont, uintptr(w.editFont(e)), 1)
		w.setEditMargins(e)
	}
	w.updateAppIcons()
}

func (w *win) updateAppIcons() {
	sys := w.systemDPI()
	big := systemMetric(smCxIcon, sys)
	small := systemMetric(smCxSmIcon, sys)
	for i, size := range []int32{small, big} {
		if size <= 0 {
			size = []int32{16, 32}[i]
		}
		icon := iconFromImage(logo.Render(int(size)))
		if icon == 0 {
			continue
		}
		which := uintptr(iconSmall)
		if i == 1 {
			which = iconBig
		}
		sendMessage(w.hwnd, wmSetIcon, which, uintptr(icon))
		if w.appIcons[i] != 0 {
			procDestroyIcon.Call(uintptr(w.appIcons[i]))
		}
		w.appIcons[i] = icon
	}
}

// px converts device-independent pixels to device pixels.
func (w *win) px(dip int32) int32 { return int32((int64(dip)*int64(w.dpi) + 48) / 96) }

func (w *win) font(size int32, weight int32) windows.Handle {
	return w.fontFace("Segoe UI", size, weight, clearTypeQuality)
}

func (w *win) mono(size int32) windows.Handle {
	return w.fontFace("Consolas", size, fwNormal, clearTypeQuality)
}

func (w *win) glyphFont(size int32) windows.Handle {
	return w.fontFace("Segoe MDL2 Assets", size, fwNormal, antialiasQuality)
}

func (w *win) fontFace(face string, size int32, weight int32, quality uintptr) windows.Handle {
	key := fontKey{face, size, weight, quality}
	if f, ok := w.fonts[key]; ok {
		return f
	}
	f := createFont(face, w.px(size), weight, quality)
	w.fonts[key] = f
	return f
}

// stockIcon returns a shell stock icon (SHGetStockIconInfo) at an exact pixel
// size, so drive icons come from Windows and nothing is bundled.
func (w *win) stockIcon(siid int32, size int32) windows.Handle {
	key := [2]int32{siid, size}
	if icon, ok := w.stock[key]; ok {
		return icon
	}
	var icon windows.Handle
	if procSHGetStockIconInfo.Find() == nil && procSHDefExtractIconW.Find() == nil {
		info := stockIconInfo{Size: uint32(unsafe.Sizeof(stockIconInfo{}))}
		if hr, _, _ := procSHGetStockIconInfo.Call(uintptr(siid), shgsiIconLocation, uintptr(unsafe.Pointer(&info))); hr == 0 {
			var large windows.Handle
			procSHDefExtractIconW.Call(uintptr(unsafe.Pointer(&info.Path[0])), uintptr(info.IconIndex), 0,
				uintptr(unsafe.Pointer(&large)), 0, uintptr(size)&0xffff)
			icon = large
		}
	}
	w.stock[key] = icon
	return icon
}

func (w *win) logoImage(size int32) *image.RGBA {
	if img, ok := w.logos[size]; ok {
		return img
	}
	img := logo.Render(int(size))
	w.logos[size] = img
	return img
}

// post runs fn on the UI thread (the replacement for fyne.Do): fn is queued
// and a WM_APP message wakes the message loop, which drains the queue in
// order and repaints.
func (w *win) post(fn func()) {
	w.queueMu.Lock()
	w.queue = append(w.queue, fn)
	w.queueMu.Unlock()
	procPostMessageW.Call(uintptr(w.hwnd), wmAppRun, 0, 0)
}

func (w *win) drainQueue() {
	w.queueMu.Lock()
	queue := w.queue
	w.queue = nil
	w.queueMu.Unlock()
	for _, fn := range queue {
		fn()
	}
	if len(queue) > 0 {
		w.invalidate()
	}
}

func (w *win) invalidate() {
	if w.hwnd != 0 && !w.destroyed {
		invalidate(w.hwnd)
	}
}

func (w *win) run() {
	var m msg
	for {
		r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 {
			break
		}
		if w.preTranslate(&m) {
			continue
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		procDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
	}
}

func (w *win) editForHwnd(hwnd windows.HWND) *nativeEdit {
	for _, e := range w.edits {
		if e.hwnd == hwnd {
			return e
		}
	}
	return nil
}

// preTranslate routes Tab/Escape out of native EDIT controls into the
// window's focus handling and swallows the characters that would beep.
func (w *win) preTranslate(m *msg) bool {
	if m.Hwnd == w.hwnd || (m.Message != wmKeyDown && m.Message != wmChar) {
		return false
	}
	e := w.editForHwnd(m.Hwnd)
	if e == nil {
		return false
	}
	if m.Message == wmChar {
		switch m.WParam {
		case '\t', 0x1b, 0x01:
			return true
		case '\r':
			return !e.multiline
		}
		return false
	}
	switch m.WParam {
	case vkTab, vkEscape:
		w.handleKey(m.WParam, true)
		return true
	case vkReturn:
		return !e.multiline
	case 'A':
		if keyDown(vkControl) {
			sendMessage(e.hwnd, emSetSel, 0, ^uintptr(0))
			return true
		}
	}
	return false
}

func (w *win) wndProc(hwnd windows.HWND, message uint32, wParam, lParam uintptr) uintptr {
	switch message {
	case wmEraseBkgnd:
		return 1
	case wmPaint:
		w.paint(hwnd)
		return 0
	case wmSize:
		w.invalidate()
		return 0
	case wmGetMinMaxInfo:
		info := *(**minMaxInfo)(unsafe.Pointer(&lParam)) // lParam is a MINMAXINFO* owned by Windows
		r := rect{0, 0, w.px(minClientW), w.px(minClientH)}
		adjustWindowRect(&r, wsOverlappedWindow, w.systemDPI())
		width, height := r.w(), r.h()
		if work, ok := monitorWorkArea(hwnd); ok {
			width, height = min(width, work.w()), min(height, work.h())
		}
		info.MinTrackSize = point{width, height}
		return 0
	case wmDpiChanged:
		w.setDPI(uint32(hiWord(wParam)))
		suggested := *(**rect)(unsafe.Pointer(&lParam)) // lParam is a RECT* owned by Windows
		procSetWindowPos.Call(uintptr(hwnd), 0, uintptr(suggested.Left), uintptr(suggested.Top),
			uintptr(suggested.w()), uintptr(suggested.h()), swpNoZOrder|swpNoActivate)
		w.invalidate()
		return 0
	case wmAppRun:
		w.drainQueue()
		return 0
	case wmTimer:
		if wParam == animTimerID {
			w.invalidate()
		}
		return 0
	case wmMouseMove:
		if !w.scripted {
			w.mouseMove(loWord(lParam), hiWord(lParam))
		}
		return 0
	case wmMouseLeave:
		if w.scripted {
			return 0
		}
		w.tracking, w.mouseIn = false, false
		if w.dragging == nil && w.hot != "" {
			w.hot = ""
			w.invalidate()
		}
		return 0
	case wmSetCursor:
		if loWord(lParam) == htClient && windows.HWND(wParam) == hwnd {
			id := idcArrow
			if wd := w.findLast(w.hot); wd != nil && !wd.disabled && (wd.onClick != nil || wd.drag != nil) {
				id = idcHand
			}
			cursor, _, _ := procLoadCursorW.Call(0, uintptr(id))
			procSetCursor.Call(cursor)
			return 1
		}
	case wmLButtonDown, wmLButtonDblClk:
		if w.scripted {
			return 0
		}
		w.mouseDown(loWord(lParam), hiWord(lParam))
		return 0
	case wmLButtonUp:
		if w.scripted {
			return 0
		}
		w.mouseUp(loWord(lParam), hiWord(lParam))
		return 0
	case wmCaptureChanged:
		w.dragging = nil
		return 0
	case wmMouseWheel:
		pt := point{loWord(lParam), hiWord(lParam)}
		procScreenToClient.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&pt)))
		w.wheel(pt.X, pt.Y, hiWord(wParam))
		return 0
	case wmKeyDown, wmSysKeyDown:
		if message == wmSysKeyDown && wParam != vkF5 {
			break // Alt+F4 and the system menu stay with DefWindowProc
		}
		w.handleKey(wParam, false)
		return 0
	case wmChar:
		return 0
	case wmSetFocus:
		w.invalidate()
		return 0
	case wmKillFocus:
		w.invalidate()
		return 0
	case wmActivateApp:
		w.invalidate()
	case wmCommand:
		code := uint32(wParam >> 16)
		if e := w.editByCtrl[wParam&0xffff]; e != nil {
			switch code {
			case enChange:
				if e.onChange != nil {
					e.onChange(windowText(e.hwnd))
				}
				w.invalidate()
			case enSetFocus:
				w.focus = e.id
				w.invalidate()
			case enKillFocus:
				w.invalidate()
			}
		}
		return 0
	case wmCtlColorEdit, wmCtlColorStatic:
		hdc := wParam
		e := w.editForHwnd(windows.HWND(lParam))
		if e != nil {
			procSetTextColor.Call(hdc, theme.Text.colorref())
			procSetBkColor.Call(hdc, theme.Field.colorref())
			return uintptr(w.fieldBrush)
		}
	case wmClose:
		if w.root.canClose() {
			w.destroyed = true
			procDestroyWindow.Call(uintptr(hwnd))
		} else {
			w.root.closeBlocked()
			w.invalidate()
		}
		return 0
	case wmQueryEndSession:
		if w.root.canClose() {
			return 1
		}
		w.root.closeBlocked()
		return 0
	case wmDestroy:
		w.destroyed = true
		procPostQuitMessage.Call(0)
		return 0
	}
	r, _, _ := procDefWindowProcW.Call(uintptr(hwnd), uintptr(message), wParam, lParam)
	return r
}

func (w *win) paint(hwnd windows.HWND) {
	var ps paintStruct
	hdc, _, _ := procBeginPaint.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&ps)))
	client := clientRect(hwnd)
	if w.canvas == nil || w.canvas.width != client.Right || w.canvas.height != client.Bottom {
		w.canvas.release()
		w.canvas = newCanvas(client.Right, client.Bottom)
	}
	w.beginFrame()
	w.root.draw(w)
	w.endFrame()
	w.canvas.blit(windows.Handle(hdc))
	procEndPaint.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&ps)))
	callbacks := w.painted
	w.painted = nil
	for _, fn := range callbacks {
		fn()
	}
	if w.onFrame != nil {
		w.onFrame()
	}
}

func (w *win) beginFrame() {
	w.frame = w.frame[:0]
	w.regions = w.regions[:0]
	w.scrollStack = w.scrollStack[:0]
	w.animate = false
	w.overlay = rect{}
	for _, e := range w.edits {
		e.used = false
	}
	w.canvas.resetClip()
}

func (w *win) endFrame() {
	w.canvas.resetClip()
	w.last, w.frame = w.frame, w.last
	w.lastRegs, w.regions = w.regions, w.lastRegs
	for _, e := range w.edits {
		hide := !e.used || (!w.overlay.empty() && w.overlay.overlaps(e.placed))
		if hide && e.shown {
			procShowWindow.Call(uintptr(e.hwnd), swHide)
			e.shown = false
			if getFocus() == e.hwnd {
				setFocus(w.hwnd)
			}
		} else if !hide && !e.shown {
			procShowWindow.Call(uintptr(e.hwnd), swShowNA)
			e.shown = true
		}
	}
	if w.focus != "" {
		if wd := w.findLast(w.focus); wd == nil || !wd.focusable {
			w.focus = ""
		}
	}
	if w.mouseIn && w.dragging == nil {
		if hot := w.hitTest(w.mouse.X, w.mouse.Y); hot != w.hot {
			w.hot = hot
			w.invalidate()
		}
	}
	if w.animate && !w.timerOn {
		procSetTimer.Call(uintptr(w.hwnd), animTimerID, animInterval, 0)
		w.timerOn = true
	} else if !w.animate && w.timerOn {
		procKillTimer.Call(uintptr(w.hwnd), animTimerID)
		w.timerOn = false
	}
}

// resetScreen drops all per-screen state (native controls, scroll offsets,
// focus) when the flow switches screens.
func (w *win) resetScreen() {
	for id, e := range w.edits {
		if getFocus() == e.hwnd {
			setFocus(w.hwnd)
		}
		procDestroyWindow.Call(uintptr(e.hwnd))
		delete(w.edits, id)
		delete(w.editByCtrl, e.ctrlID)
	}
	w.scrolls = map[string]*scrollState{}
	w.focus, w.hot, w.pressed = "", "", ""
	w.dragging = nil
	w.last = w.last[:0]
	w.lastRegs = w.lastRegs[:0]
	w.invalidate()
}

// add registers an interactive widget for this frame and returns its state.
func (w *win) add(wd widget) widgetState {
	wd.full = wd.r
	wd.r = wd.r.intersect(w.canvas.clip)
	if n := len(w.scrollStack); n > 0 {
		wd.scrollID = w.scrollStack[n-1]
	}
	w.frame = append(w.frame, wd)
	st := widgetState{}
	st.focused = w.focus == wd.id
	st.ring = st.focused && w.cues && !wd.disabled
	if !wd.disabled {
		st.hot = w.hot == wd.id
		st.pressed = st.hot && w.pressed == wd.id
	}
	return st
}

func (w *win) findLast(id string) *widget {
	if id == "" {
		return nil
	}
	for i := len(w.last) - 1; i >= 0; i-- {
		if w.last[i].id == id {
			return &w.last[i]
		}
	}
	return nil
}

func (w *win) hitTest(x, y int32) string {
	for i := len(w.last) - 1; i >= 0; i-- {
		wd := &w.last[i]
		if wd.edit == nil && wd.r.contains(x, y) {
			return wd.id
		}
	}
	return ""
}

func (w *win) mouseMove(x, y int32) {
	w.mouse = point{x, y}
	w.mouseIn = true
	if !w.tracking && !w.scripted {
		tme := trackMouseEvent{Size: uint32(unsafe.Sizeof(trackMouseEvent{})), Flags: tmeLeave, Track: w.hwnd}
		procTrackMouseEvent.Call(uintptr(unsafe.Pointer(&tme)))
		w.tracking = true
	}
	if w.dragging != nil {
		w.dragging.move(y - w.dragOrigin)
		w.invalidate()
		return
	}
	if hot := w.hitTest(x, y); hot != w.hot {
		w.hot = hot
		w.invalidate()
	}
}

func (w *win) mouseDown(x, y int32) {
	w.cues = false
	w.mouse = point{x, y}
	id := w.hitTest(x, y)
	w.hot = id
	wd := w.findLast(id)
	if wd == nil || wd.disabled {
		w.pressed = ""
		if getFocus() != w.hwnd {
			setFocus(w.hwnd)
		}
		w.invalidate()
		return
	}
	w.pressed = id
	if wd.focusable {
		w.focus = id
	}
	if getFocus() != w.hwnd {
		setFocus(w.hwnd)
	}
	procSetCapture.Call(uintptr(w.hwnd))
	if wd.drag != nil {
		w.dragging = wd.drag
		w.dragOrigin = y
		if wd.drag.begin != nil {
			wd.drag.begin()
		}
	}
	w.invalidate()
}

func (w *win) mouseUp(x, y int32) {
	pressed := w.pressed
	w.pressed = ""
	dragging := w.dragging != nil
	w.dragging = nil
	procReleaseCapture.Call()
	if !dragging && pressed != "" && w.hitTest(x, y) == pressed {
		if wd := w.findLast(pressed); wd != nil && !wd.disabled && wd.onClick != nil {
			wd.onClick()
		}
	}
	w.invalidate()
}

func (w *win) wheel(x, y, delta int32) {
	for i := len(w.lastRegs) - 1; i >= 0; i-- {
		region := w.lastRegs[i]
		if !region.r.contains(x, y) {
			continue
		}
		if s := w.scrolls[region.id]; s != nil {
			s.offset -= delta * w.px(48) / wheelDelta
			s.clamp()
			w.invalidate()
		}
		return
	}
}

func (s *scrollState) clamp() {
	s.offset = max(0, min(s.offset, s.content-s.view))
}

func (w *win) handleKey(vk uintptr, fromEdit bool) {
	switch vk {
	case vkShift, vkControl, vkMenu:
		return
	}
	w.cues = true
	defer w.invalidate()
	if vk == vkTab {
		if w.root.key(w, vk, true) {
			return
		}
		if keyDown(vkShift) {
			w.moveFocus(-1)
		} else {
			w.moveFocus(1)
		}
		return
	}
	if w.root.key(w, vk, true) {
		return
	}
	if !fromEdit {
		if wd := w.findLast(w.focus); wd != nil && !wd.disabled && wd.edit == nil {
			if wd.onKey != nil && wd.onKey(vk) {
				return
			}
			if (vk == vkReturn || vk == vkSpace) && wd.onClick != nil {
				wd.onClick()
				return
			}
		}
	}
	if w.root.key(w, vk, false) {
		return
	}
	if fromEdit {
		return
	}
	switch vk {
	case vkUp, vkLeft:
		w.moveFocus(-1)
	case vkDown, vkRight:
		w.moveFocus(1)
	}
}

// moveFocus cycles through the focusable, enabled widgets of the last frame.
func (w *win) moveFocus(dir int) {
	var order []*widget
	current := -1
	for i := range w.last {
		wd := &w.last[i]
		if !wd.focusable || wd.disabled {
			continue
		}
		if wd.id == w.focus {
			current = len(order)
		}
		order = append(order, wd)
	}
	if len(order) == 0 {
		return
	}
	next := 0
	if current < 0 {
		if dir < 0 {
			next = len(order) - 1
		}
	} else {
		next = (current + dir + len(order)) % len(order)
	}
	w.setFocusWidget(order[next])
}

func (w *win) setFocusID(id string) {
	if wd := w.findLast(id); wd != nil {
		w.setFocusWidget(wd)
		return
	}
	w.focus = id
}

func (w *win) setFocusWidget(wd *widget) {
	w.focus = wd.id
	if wd.edit != nil {
		setFocus(wd.edit.hwnd)
	} else if getFocus() != w.hwnd {
		setFocus(w.hwnd)
	}
	if wd.scrollID != "" {
		w.ensureVisible(wd.scrollID, wd.full)
	}
	w.invalidate()
}

// ensureVisible scrolls region id so that r (screen coordinates of the last
// frame) is inside its viewport.
func (w *win) ensureVisible(id string, r rect) {
	s := w.scrolls[id]
	if s == nil {
		return
	}
	for _, region := range w.lastRegs {
		if region.id != id {
			continue
		}
		if r.Top < region.r.Top {
			s.offset -= region.r.Top - r.Top
		} else if r.Bottom > region.r.Bottom {
			s.offset += r.Bottom - region.r.Bottom
		}
		s.clamp()
		return
	}
}

// beginScroll starts a vertically scrolling viewport; content drawn until
// endScroll is clipped to view and should be offset by the returned value.
func (w *win) beginScroll(id string, view rect) int32 {
	s := w.scrolls[id]
	if s == nil {
		s = &scrollState{}
		w.scrolls[id] = s
	}
	s.view = view.h()
	s.clamp()
	w.canvas.pushClip(view)
	w.scrollStack = append(w.scrollStack, id)
	return s.offset
}

func (w *win) endScroll(id string, view rect, content int32) {
	s := w.scrolls[id]
	w.canvas.popClip()
	if n := len(w.scrollStack); n > 0 {
		w.scrollStack = w.scrollStack[:n-1]
	}
	s.content = content
	before := s.offset
	s.clamp()
	if s.offset != before {
		w.invalidate()
	}
	w.regions = append(w.regions, scrollRegion{id: id, r: view})
	if content <= view.h() {
		return
	}
	trackH := view.h()
	thumbH := max(w.px(28), trackH*view.h()/content)
	travel := trackH - thumbH
	thumbY := view.Top
	if travel > 0 && content > view.h() {
		thumbY += int32(int64(travel) * int64(s.offset) / int64(content-view.h()))
	}
	barW := w.px(10)
	hit := rect{view.Right - barW, view.Top, view.Right, view.Bottom}
	var startOffset int32
	st := w.add(widget{id: id + ".thumb", r: hit, drag: &dragHandler{
		begin: func() { startOffset = s.offset },
		move: func(dy int32) {
			if travel > 0 {
				s.offset = startOffset + int32(int64(dy)*int64(content-view.h())/int64(travel))
				s.clamp()
			}
		},
	}})
	thickness := w.px(4)
	col := theme.BorderStrong
	if st.hot || w.dragging != nil && w.pressed == id+".thumb" {
		thickness = w.px(6)
		col = theme.Muted
	}
	thumb := rect{view.Right - w.px(3) - thickness, thumbY + w.px(2), view.Right - w.px(3), thumbY + thumbH - w.px(2)}
	w.canvas.roundRect(thumb, thickness/2, col)
}

// edit places (creating on first use) a native EDIT control inside r.
func (w *win) edit(id string, r rect, o editOptions) (*nativeEdit, widgetState) {
	e := w.edits[id]
	if e == nil {
		style := uintptr(wsChild | wsTabStop)
		if o.multiline {
			style |= esMultiline | esAutoVScroll | wsVScroll | esNoHideSel
		} else {
			style |= esAutoHScroll
		}
		if o.readonly {
			style |= esReadOnly
		}
		w.nextCtrlID++
		ctrl := w.nextCtrlID
		hwnd, _, _ := procCreateWindowExW.Call(0, uintptr(unsafe.Pointer(utf16Ptr("EDIT"))), uintptr(unsafe.Pointer(utf16Ptr(toCRLF(o.initial)))),
			style, uintptr(r.Left), uintptr(r.Top), uintptr(r.w()), uintptr(r.h()), uintptr(w.hwnd), ctrl, w.instance, 0)
		e = &nativeEdit{id: id, hwnd: windows.HWND(hwnd), ctrlID: ctrl, multiline: o.multiline, mono: o.mono, fontSize: o.fontSize}
		if e.fontSize == 0 {
			e.fontSize = 14
		}
		w.edits[id] = e
		w.editByCtrl[ctrl] = e
		sendMessage(e.hwnd, emSetLimitText, 0, 0)
		sendMessage(e.hwnd, wmSetFont, uintptr(w.editFont(e)), 0)
		w.setEditMargins(e)
		if o.multiline {
			setDarkControlTheme(e.hwnd)
		}
		if o.cue != "" {
			sendMessage(e.hwnd, emSetCueBanner, 1, uintptr(unsafe.Pointer(utf16Ptr(o.cue))))
		}
	}
	e.onChange = o.onChange
	e.used = true
	if e.disabled != o.disabled {
		procEnableWindowCall(e.hwnd, !o.disabled)
		e.disabled = o.disabled
	}
	visible := r.intersect(w.canvas.clip)
	if visible != r {
		e.used = false // never show a partly clipped native control
	}
	if e.placed != r {
		procSetWindowPos.Call(uintptr(e.hwnd), 0, uintptr(r.Left), uintptr(r.Top), uintptr(r.w()), uintptr(r.h()), swpNoZOrder|swpNoActivate)
		e.placed = r
	}
	st := w.add(widget{id: id, r: r, focusable: !o.disabled, disabled: o.disabled, edit: e})
	st.focused = getFocus() == e.hwnd
	return e, st
}

func (w *win) editFont(e *nativeEdit) windows.Handle {
	if e.mono {
		return w.mono(e.fontSize)
	}
	return w.font(e.fontSize, fwNormal)
}

func (w *win) setEditMargins(e *nativeEdit) {
	m := uintptr(w.px(2))
	sendMessage(e.hwnd, emSetMargins, ecLeftMargin|ecRightMargin, m|m<<16)
}

func (e *nativeEdit) text() string { return windowText(e.hwnd) }

func (e *nativeEdit) setText(s string) {
	sendMessage(e.hwnd, wmSetText, 0, uintptr(unsafe.Pointer(utf16Ptr(toCRLF(s)))))
}

// appendText adds text at the end and scrolls to it (log view).
func (e *nativeEdit) appendText(s string) {
	end, _, _ := procGetWindowTextLengthW.Call(uintptr(e.hwnd))
	sendMessage(e.hwnd, emSetSel, end, end)
	if s != "" {
		sendMessage(e.hwnd, emReplaceSel, 0, uintptr(unsafe.Pointer(utf16Ptr(toCRLF(s)))))
	}
	sendMessage(e.hwnd, emScrollCaret, 0, 0)
}

var procEnableWindow = user32.NewProc("EnableWindow")

func procEnableWindowCall(hwnd windows.HWND, enabled bool) {
	v := uintptr(0)
	if enabled {
		v = 1
	}
	procEnableWindow.Call(uintptr(hwnd), v)
}

func toCRLF(s string) string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	return strings.ReplaceAll(s, "\n", "\r\n")
}
