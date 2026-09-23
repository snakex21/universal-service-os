package ui

// Mouse wheel arithmetic, kept free of Win32 so it can be unit tested.
//
// A classic wheel reports multiples of WHEEL_DELTA (120) per notch; precision
// touchpads and free-spinning or high-resolution wheels report many small
// deltas instead. Converting each message on its own (delta*step/120) loses
// the fraction every time, so slow touchpad scrolling stalls or stutters.
// wheelAccum keeps that fraction per target and hands out whole units only.

const wheelNotch = 120 // WHEEL_DELTA

// wheelAccum converts wheel deltas to whole scroll units (pixels, rows),
// carrying the remainder between messages. The remainder is dropped when the
// target or the direction changes, so a reversal reacts immediately.
type wheelAccum struct {
	target string
	rem    int64 // delta*perNotch not yet handed out, same sign as the last delta
}

// add feeds one wheel message for target. perNotch is how many units one
// full notch (120) is worth; the result is the number of whole units to
// scroll, positive in the direction of positive delta (away from the user
// for vertical wheels, to the right for horizontal ones).
func (a *wheelAccum) add(target string, delta int32, perNotch int32) int32 {
	if delta == 0 || perNotch <= 0 {
		return 0
	}
	if target != a.target || (a.rem > 0 && delta < 0) || (a.rem < 0 && delta > 0) {
		a.target, a.rem = target, 0
	}
	a.rem += int64(delta) * int64(perNotch)
	units := a.rem / wheelNotch // truncates toward zero: the remainder keeps the sign
	a.rem -= units * wheelNotch
	return int32(units)
}

func (a *wheelAccum) reset() { a.target, a.rem = "", 0 }

// wheelPageScroll is SPI_GETWHEELSCROLLLINES' "one screen per notch" value.
const wheelPageScroll = ^uint32(0)

// wheelStep returns the pixels one notch scrolls: lines*lineHeight, or one
// view height (less a line of overlap) when the user chose page scrolling.
// lines == 0 (scrolling disabled in Settings) yields 0.
func wheelStep(lines uint32, lineHeight, view int32) int32 {
	if lines == wheelPageScroll {
		return max(lineHeight, view-lineHeight)
	}
	if lines > 100 {
		lines = 100
	}
	return int32(lines) * lineHeight
}
