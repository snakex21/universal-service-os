//go:build windows

package ui

import "math"

// Drive icons. Internal disks and non-USB removable media keep the shell
// stock icons; Windows has no distinct stock icon for a USB flash drive or a
// USB-attached disk (SIID_DRIVEREMOVE and SIID_DRIVEFIXED are both flat
// drives that look alike at 32 px), so those two are drawn here as
// anti-aliased vector glyphs in the palette of the operation icons, at the
// exact device-pixel size (DPI scaled by the caller).

var (
	iconMetal     = color{0xc4, 0xd2, 0xdb}
	iconMetalDark = color{0x8a, 0x9d, 0xab}
)

func (w *win) driveIcon(kind driveKind, x, y, size int32) {
	c := w.canvas
	switch kind {
	case driveUSBStick:
		c.usbStickGlyph(x, y, size)
	case driveExternal:
		c.externalDriveGlyph(x, y, size)
	case driveRemovable:
		c.icon(w.stockIcon(siidDriveRemove, size), x, y, size)
	default:
		c.icon(w.stockIcon(siidDriveFixed, size), x, y, size)
	}
}

// boxSDF is the signed distance to a rounded box centred at (cx, cy) with
// half extents hx, hy and corner radius r.
func boxSDF(px, py, cx, cy, hx, hy, r float64) float64 {
	qx := math.Abs(px-cx) - hx + r
	qy := math.Abs(py-cy) - hy + r
	return math.Hypot(math.Max(qx, 0), math.Max(qy, 0)) + math.Min(math.Max(qx, qy), 0) - r
}

// shape fills the pixels of box whose signed distance (from sdf, in pixel
// units, evaluated at pixel centres) is negative, anti-aliased.
func (c *canvas) shape(box rect, col color, sdf func(px, py float64) float64) {
	c.flush()
	area := box.intersect(c.clip)
	for y := area.Top; y < area.Bottom; y++ {
		for x := area.Left; x < area.Right; x++ {
			c.blend(x, y, col, coverage(sdf(float64(x)+0.5, float64(y)+0.5)))
		}
	}
	c.dirty = true
}

// usbStickGlyph draws a pendrive lying diagonally, connector to the top
// right: a rounded accent body with a lanyard hole and a darker label, and a
// metal plug with the two contact windows of a USB-A connector.
func (c *canvas) usbStickGlyph(x, y, size int32) {
	s := float64(size)
	cx, cy := float64(x)+s/2, float64(y)+s/2
	const k = math.Sqrt2 / 2
	// (u, v): u along the stick towards the plug, v across it; units of s.
	local := func(px, py float64) (float64, float64) {
		dx, dy := (px-cx)/s, (py-cy)/s
		return (dx - dy) * k, (dx + dy) * k
	}
	box := rect{x, y, x + size, y + size}
	part := func(col color, uc, vc, hu, hv, r float64) {
		c.shape(box, col, func(px, py float64) float64 {
			u, v := local(px, py)
			return boxSDF(u, v, uc, vc, hu, hv, r) * s
		})
	}
	disc := func(col color, uc, vc, r float64) {
		c.shape(box, col, func(px, py float64) float64 {
			u, v := local(px, py)
			return math.Hypot(u-uc, v-vc)*s - r*s
		})
	}
	part(iconMetal, 0.31, 0, 0.19, 0.13, 0.025)                                // plug shell
	part(iconMetalDark, 0.33, -0.055, 0.055, 0.03, 0.008)                      // contact windows
	part(iconMetalDark, 0.33, 0.055, 0.055, 0.03, 0.008)                       //
	part(theme.Accent, -0.18, 0, 0.32, 0.19, 0.09)                             // body
	part(theme.Accent.mix(theme.OnAccent, 0.28), -0.09, 0, 0.15, 0.105, 0.035) // label
	disc(theme.OnAccent, -0.395, 0, 0.045)                                     // lanyard hole
}

// externalDriveGlyph draws a portable disk standing upright: an accent
// enclosure showing a platter, an activity LED and a short cable with a metal
// plug leaving to the right.
func (c *canvas) externalDriveGlyph(x, y, size int32) {
	s := float64(size)
	ox, oy := float64(x)+s/2, float64(y)+s/2
	box := rect{x, y, x + size, y + size}
	part := func(col color, cx, cy, hx, hy, r float64) {
		c.shape(box, col, func(px, py float64) float64 {
			return boxSDF((px-ox)/s, (py-oy)/s, cx, cy, hx, hy, r) * s
		})
	}
	disc := func(col color, cx, cy, r float64) {
		c.shape(box, col, func(px, py float64) float64 {
			return (math.Hypot((px-ox)/s-cx, (py-oy)/s-cy) - r) * s
		})
	}
	part(iconMetalDark, 0.26, 0.29, 0.08, 0.025, 0.01) // cable
	part(iconMetal, 0.39, 0.29, 0.075, 0.06, 0.02)     // plug
	part(theme.Accent, -0.09, 0, 0.29, 0.43, 0.09)     // enclosure
	disc(theme.Accent.mix(theme.OnAccent, 0.62), -0.09, -0.08, 0.2)
	disc(theme.Accent.mix(theme.OnAccent, 0.2), -0.09, -0.08, 0.055)           // hub
	part(theme.Accent.mix(theme.OnAccent, 0.62), -0.09, 0.08, 0.02, 0.1, 0.02) // head arm
	disc(theme.Success, 0.08, 0.31, 0.04)                                      // activity LED
}
