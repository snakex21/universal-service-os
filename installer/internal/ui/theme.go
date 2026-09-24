package ui

// rect is a Win32 RECT in device pixels.
type rect struct{ Left, Top, Right, Bottom int32 }

func (r rect) w() int32    { return r.Right - r.Left }
func (r rect) h() int32    { return r.Bottom - r.Top }
func (r rect) empty() bool { return r.Right <= r.Left || r.Bottom <= r.Top }

func (r rect) contains(x, y int32) bool {
	return x >= r.Left && x < r.Right && y >= r.Top && y < r.Bottom
}

func (r rect) inset(dx, dy int32) rect {
	return rect{r.Left + dx, r.Top + dy, r.Right - dx, r.Bottom - dy}
}

func (r rect) intersect(o rect) rect {
	out := rect{max(r.Left, o.Left), max(r.Top, o.Top), min(r.Right, o.Right), min(r.Bottom, o.Bottom)}
	if out.empty() {
		return rect{}
	}
	return out
}

func (r rect) overlaps(o rect) bool { return !r.intersect(o).empty() }

// cutTop splits off a band of height h from the top.
func (r rect) cutTop(h int32) (rect, rect) {
	h = min(h, r.h())
	return rect{r.Left, r.Top, r.Right, r.Top + h}, rect{r.Left, r.Top + h, r.Right, r.Bottom}
}

func (r rect) cutBottom(h int32) (rect, rect) {
	h = min(h, r.h())
	return rect{r.Left, r.Bottom - h, r.Right, r.Bottom}, rect{r.Left, r.Top, r.Right, r.Bottom - h}
}

func (r rect) cutLeft(w int32) (rect, rect) {
	w = min(w, r.w())
	return rect{r.Left, r.Top, r.Left + w, r.Bottom}, rect{r.Left + w, r.Top, r.Right, r.Bottom}
}

func (r rect) cutRight(w int32) (rect, rect) {
	w = min(w, r.w())
	return rect{r.Right - w, r.Top, r.Right, r.Bottom}, rect{r.Left, r.Top, r.Right - w, r.Bottom}
}

// centered returns a w x h rect centred in r.
func (r rect) centered(w, h int32) rect {
	x := r.Left + (r.w()-w)/2
	y := r.Top + (r.h()-h)/2
	return rect{x, y, x + w, y + h}
}

type color struct{ R, G, B uint8 }

func (c color) pixel() uint32     { return uint32(c.B) | uint32(c.G)<<8 | uint32(c.R)<<16 }
func (c color) colorref() uintptr { return uintptr(c.R) | uintptr(c.G)<<8 | uintptr(c.B)<<16 }

// mix blends c toward o by t (0..1).
func (c color) mix(o color, t float64) color {
	lerp := func(a, b uint8) uint8 { return uint8(float64(a)*(1-t) + float64(b)*t + 0.5) }
	return color{lerp(c.R, o.R), lerp(c.G, o.G), lerp(c.B, o.B)}
}

// theme is the USOS palette (src/gui/theme.zig) extended with status colours
// for the Windows installer.
var theme = struct {
	Background, Header, Panel, PanelAlt, Field, Text, Muted, Faint, Accent, AccentHover, AccentPressed,
	AccentSoft, OnAccent, Selected, Border, BorderStrong, Disabled, DisabledText,
	Danger, DangerHover, DangerSoft, Warning, WarningSoft, Success, SuccessSoft color
}{
	Background:    color{0x08, 0x0d, 0x14},
	Header:        color{0x0c, 0x14, 0x1e},
	Panel:         color{0x10, 0x19, 0x23},
	PanelAlt:      color{0x17, 0x25, 0x35},
	Field:         color{0x0b, 0x12, 0x1b},
	Text:          color{0xef, 0xfc, 0xff},
	Muted:         color{0x8f, 0xa8, 0xb8},
	Faint:         color{0x5d, 0x73, 0x82},
	Accent:        color{0x43, 0xd8, 0xe8},
	AccentHover:   color{0x6c, 0xe4, 0xf0},
	AccentPressed: color{0x2f, 0xb4, 0xc4},
	AccentSoft:    color{0x0f, 0x33, 0x40},
	OnAccent:      color{0x05, 0x14, 0x1c},
	Selected:      color{0x14, 0x5b, 0x7a},
	Border:        color{0x29, 0x44, 0x57},
	BorderStrong:  color{0x3a, 0x5c, 0x73},
	Disabled:      color{0x22, 0x2b, 0x35},
	DisabledText:  color{0x5a, 0x66, 0x72},
	Danger:        color{0xf0, 0x5a, 0x5f},
	DangerHover:   color{0xf5, 0x7b, 0x7f},
	DangerSoft:    color{0x35, 0x14, 0x19},
	Warning:       color{0xf2, 0xb1, 0x3c},
	WarningSoft:   color{0x2f, 0x24, 0x10},
	Success:       color{0x4a, 0xd6, 0x8c},
	SuccessSoft:   color{0x0f, 0x2b, 0x21},
}

// Segoe MDL2 Assets code points (shipped with Windows 10 and 11).
const (
	glyphDownload     = "\uE896"
	glyphSync         = "\uE895"
	glyphRefresh      = "\uE72C"
	glyphRepair       = "\uE90F"
	glyphDelete       = "\uE74D"
	glyphGlobe        = "\uE774"
	glyphChevronDown  = "\uE70D"
	glyphChevronUp    = "\uE70E"
	glyphChevronRight = "\uE76C"
	glyphBack         = "\uE72B"
	glyphWarning      = "\uE7BA"
	glyphInfo         = "\uE946"
	glyphErrorCircle  = "\uEA39"
	glyphCheck        = "\uE73E"
	glyphCheckSmall   = "\uF13E"
	glyphCancel       = "\uE711"
	glyphCompleted    = "\uE930"
	glyphShield       = "\uEA18"
	glyphUSB          = "\uE88E"
	glyphDrive        = "\uEDA2"
	glyphClock        = "\uE823"
	glyphCircleOuter  = "\uEA3A"
	glyphCheckSolid   = "\uEC61"
	glyphErrorSolid   = "\uEB90"
	glyphLock         = "\uE72E"
	glyphFolder       = "\uE838"
)
