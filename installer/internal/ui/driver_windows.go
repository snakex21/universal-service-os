//go:build windows

package ui

import (
	"fmt"
	"image"
	"image/png"
	"os"
	"time"
	"unsafe"

	"github.com/snakex21/universal-service-os/installer/internal/i18n"
)

// Driver scripts the window for the screenshot harness
// (cmd/usos-installer-uidemo). Every method runs its work on the UI thread
// and waits for it; nothing here is reachable from the production installer,
// which never sets Config.Script.
type Driver struct {
	f *Flow
	w *win
}

func (d *Driver) do(fn func()) {
	done := make(chan struct{})
	d.w.post(func() {
		fn()
		close(done)
	})
	<-done
}

// Idle waits until all queued UI work is done and a frame has been painted.
func (d *Driver) Idle() {
	painted := make(chan struct{})
	d.do(func() {
		d.w.painted = append(d.w.painted, func() { close(painted) })
		d.w.invalidate()
	})
	select {
	case <-painted:
	case <-time.After(3 * time.Second):
	}
	// A second frame settles hover/scroll adjustments made by the first.
	painted2 := make(chan struct{})
	d.do(func() {
		d.w.painted = append(d.w.painted, func() { close(painted2) })
		d.w.invalidate()
	})
	select {
	case <-painted2:
	case <-time.After(3 * time.Second):
	}
}

// Activate clicks the widget with the given id, as the mouse would.
func (d *Driver) Activate(id string) error {
	var err error
	d.do(func() {
		wd := d.w.findLast(id)
		switch {
		case wd == nil:
			err = fmt.Errorf("widget %q not on screen", id)
		case wd.disabled:
			err = fmt.Errorf("widget %q is disabled", id)
		case wd.onClick == nil:
			err = fmt.Errorf("widget %q is not clickable", id)
		default:
			d.w.cues = false
			wd.onClick()
			d.w.invalidate()
		}
	})
	d.Idle()
	return err
}

// Enabled reports whether a widget is on screen and enabled.
func (d *Driver) Enabled(id string) bool {
	var ok bool
	d.do(func() {
		wd := d.w.findLast(id)
		ok = wd != nil && !wd.disabled
	})
	return ok
}

// Hover moves the virtual mouse to the centre of a widget.
func (d *Driver) Hover(id string) {
	d.do(func() {
		if wd := d.w.findLast(id); wd != nil {
			d.w.mouseMove(wd.r.Left+wd.r.w()/2, wd.r.Top+wd.r.h()/2)
		}
	})
	d.Idle()
}

// Key sends a key press through the real message path to the focused window.
func (d *Driver) Key(vk uintptr) {
	d.do(func() {
		target := getFocus()
		if target == 0 {
			target = d.w.hwnd
		}
		procPostMessageW.Call(uintptr(target), wmKeyDown, vk, 0)
	})
	d.Idle()
}

// Type sends characters to the focused native control.
func (d *Driver) Type(text string) {
	for _, r := range text {
		d.do(func() {
			// The focused EDIT, even when another application is active.
			target := getFocus()
			if e := d.w.edits[d.w.focus]; e != nil {
				target = e.hwnd
			}
			if target != 0 {
				procPostMessageW.Call(uintptr(target), wmChar, uintptr(r), 0)
			}
		})
	}
	d.Idle()
}

// Pad feeds one controller input as the XInput poll would: "up", "down",
// "left", "right", "a", "b", "lb", "rb" or "start".
func (d *Driver) Pad(button string) error {
	events := map[string]padEvent{
		"up": {kind: padMove, dir: dirUp}, "down": {kind: padMove, dir: dirDown},
		"left": {kind: padMove, dir: dirLeft}, "right": {kind: padMove, dir: dirRight},
		"a": {kind: padActivate}, "b": {kind: padCancel},
		"lb": {kind: padPrevSection}, "rb": {kind: padNextSection}, "start": {kind: padPrimary},
	}
	e, ok := events[button]
	if !ok {
		return fmt.Errorf("unknown pad button %q", button)
	}
	d.do(func() { d.w.padEvent(e) })
	d.Idle()
	return nil
}

// Focused returns the id of the focused widget.
func (d *Driver) Focused() string {
	var id string
	d.do(func() { id = d.w.focus })
	return id
}

// Focus gives keyboard focus to a widget.
func (d *Driver) Focus(id string) {
	d.do(func() {
		d.w.cues = true
		d.w.setFocusID(id)
	})
	d.Idle()
}

// SetLanguage switches the UI language (not persisted by the harness).
func (d *Driver) SetLanguage(code string) {
	d.do(func() { d.f.setLanguage(i18n.Normalize(code)) })
	d.Idle()
}

// OnTextOverflow registers fn for every drawn string that is ellipsized or
// clipped (see textOverflowHook); screen is the current screen type.
func (d *Driver) OnTextOverflow(fn func(screen, text string, need, have int32, wrapped bool)) {
	d.do(func() {
		textOverflowHook = func(text string, need, have int32, wrapped bool) {
			fn(fmt.Sprintf("%T", d.f.screen), text, need, have, wrapped)
		}
	})
}

// Busy reports whether an operation is running.
func (d *Driver) Busy() bool {
	var busy bool
	d.do(func() { busy = d.f.busy })
	return busy
}

// Close asks the window to close (subject to the busy guard).
func (d *Driver) Close() {
	d.do(func() { procPostMessageW.Call(uintptr(d.w.hwnd), wmClose, 0, 0) })
}

// Size returns the outer window and client sizes in device pixels.
func (d *Driver) Size() (outer, client [2]int32) {
	d.do(func() {
		r := windowRect(d.w.hwnd)
		c := clientRect(d.w.hwnd)
		outer = [2]int32{r.w(), r.h()}
		client = [2]int32{c.w(), c.h()}
	})
	return
}

// Memory returns the process working set and private bytes in KiB.
func (d *Driver) Memory() (uint64, uint64) { return processMemory() }

// Shot saves the whole window (frame, title bar and child controls) as PNG.
// The window is raised above other windows and copied from the screen, which
// captures exactly what DWM composed, native controls included.
func (d *Driver) Shot(path string) error {
	d.do(func() {
		if iconic, _, _ := procIsIconic.Call(uintptr(d.w.hwnd)); iconic != 0 {
			procShowWindow.Call(uintptr(d.w.hwnd), swRestore)
		}
	})
	d.Idle()
	d.do(func() {
		procSetWindowPos.Call(uintptr(d.w.hwnd), hwndTopmost, 0, 0, 0, 0, swpNoMove|swpNoSize|swpNoActivate)
	})
	time.Sleep(150 * time.Millisecond) // let DWM present the frame
	var err error
	d.do(func() {
		err = captureWindow(d.w, path)
		procSetWindowPos.Call(uintptr(d.w.hwnd), hwndNoTopmost, 0, 0, 0, 0, swpNoMove|swpNoSize|swpNoActivate)
	})
	return err
}

const (
	hwndTopmost   = ^uintptr(0) // HWND_TOPMOST (-1)
	hwndNoTopmost = ^uintptr(1) // HWND_NOTOPMOST (-2)
	captureBlt    = 0x40000000
)

var (
	procBitBlt                = gdi32.NewProc("BitBlt")
	procDwmGetWindowAttribute = dwmapi.NewProc("DwmGetWindowAttribute")
)

const (
	dwmaExtendedFrameBounds = 9
	swRestore               = 9
)

var procIsIconic = user32.NewProc("IsIconic")

// Loaded waits until the header refresh control is enabled again, i.e. the
// current screen finished scanning.
func (d *Driver) Loaded() {
	for i := 0; i < 400; i++ {
		if d.Enabled("header.refresh") {
			break
		}
		time.Sleep(25 * time.Millisecond)
	}
	d.Idle()
}

func captureWindow(w *win, path string) error {
	r := windowRect(w.hwnd)
	// The visible frame, without the invisible resize borders.
	var frame rect
	if procDwmGetWindowAttribute.Find() == nil {
		if hr, _, _ := procDwmGetWindowAttribute.Call(uintptr(w.hwnd), dwmaExtendedFrameBounds, uintptr(unsafe.Pointer(&frame)), unsafe.Sizeof(frame)); hr == 0 && !frame.empty() {
			r = frame
		}
	}
	width, height := r.w(), r.h()
	screenDC, _, _ := procGetDC.Call(0)
	defer procReleaseDC.Call(0, screenDC)
	target := newCanvas(width, height) // a DIB section to copy into
	defer target.release()
	if ok, _, _ := procBitBlt.Call(uintptr(target.dc), 0, 0, uintptr(width), uintptr(height), screenDC, uintptr(r.Left), uintptr(r.Top), srcCopy|captureBlt); ok == 0 {
		return fmt.Errorf("BitBlt failed")
	}
	procGdiFlush.Call()
	img := image.NewRGBA(image.Rect(0, 0, int(width), int(height)))
	for i, p := range target.pixels {
		o := i * 4
		img.Pix[o], img.Pix[o+1], img.Pix[o+2], img.Pix[o+3] = uint8(p>>16), uint8(p>>8), uint8(p), 255
	}
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	defer file.Close()
	return png.Encode(file, img)
}
