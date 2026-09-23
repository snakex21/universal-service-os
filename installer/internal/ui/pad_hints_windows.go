//go:build windows

package ui

import "github.com/snakex21/universal-service-os/installer/internal/i18n"

// padHintsH is the height (DIP) of the controller hint bar shown along the
// bottom edge while the gamepad is in use.
const padHintsH = 34

const glyphMenu = "" // GlobalNavigationButton: the pad's Start/Menu key

type padHint struct {
	keys  []string // key caps drawn before the label
	label string
}

// drawPadHints draws "A Select  B Back  LB RB Section  Start Continue" (and
// the right stick when something can scroll) in the bottom bar.
func (f *Flow) drawPadHints(w *win, r rect) {
	c := w.canvas
	c.fill(r, theme.Header)
	c.fill(rect{r.Left, r.Top, r.Right, r.Top + max(1, w.px(1))}, theme.Border)
	hints := []padHint{
		{[]string{"A"}, i18n.T("installer.pad.select")},
		{[]string{"B"}, i18n.T("installer.pad.back")},
	}
	if !f.langOpen {
		hints = append(hints, padHint{[]string{"LB", "RB"}, i18n.T("installer.pad.section")})
		if w.padHasPrimary() {
			hints = append(hints, padHint{[]string{glyphMenu}, i18n.T("installer.pad.continue")})
		}
	}
	if w.padScrollTarget() != "" {
		hints = append(hints, padHint{[]string{"RS"}, i18n.T("installer.pad.scroll")})
	}
	x := r.Left + w.px(pad)
	cy := r.Top + r.h()/2
	font := w.captionFont()
	for _, h := range hints {
		for _, k := range h.keys {
			x = w.padKeyCap(k, x, cy) + w.px(4)
		}
		x += w.px(2)
		tw := c.textWidth(font, h.label)
		if x+tw > r.Right-w.px(pad) {
			break // narrow window: drop what does not fit instead of clipping
		}
		c.text(font, h.label, rect{x, r.Top, x + tw + 1, r.Bottom}, theme.Muted, dtLeft|dtSingleLine|dtVCenter)
		x += tw + w.px(20)
	}
}

// padKeyCap draws one controller button symbol with its left edge at x and
// returns its right edge: A and B as round face buttons in their usual
// colours, bumpers and sticks as pills, Start as a pill with the menu glyph.
func (w *win) padKeyCap(key string, x, cy int32) int32 {
	c := w.canvas
	size := w.px(20)
	top := cy - size/2
	switch key {
	case "A", "B":
		col := theme.Success
		if key == "B" {
			col = theme.Danger
		}
		r := rect{x, top, x + size, top + size}
		c.circle(float64(x)+float64(size)/2, float64(cy), float64(size)/2, col)
		c.text(w.font(sizeCaption, fwBold), key, r, color{0x0b, 0x0f, 0x14}, dtCenter|dtSingleLine|dtVCenter)
		return r.Right
	case glyphMenu:
		r := rect{x, top, x + w.px(30), top + size}
		c.roundRect(r, size/2, theme.PanelAlt)
		c.roundBorder(r, size/2, max(1, w.px(1)), theme.BorderStrong)
		w.glyph(glyphMenu, r, 10, theme.Text)
		return r.Right
	}
	font := w.font(sizeCaption-1, fwBold)
	r := rect{x, top, x + c.textWidth(font, key) + w.px(14), top + size}
	c.roundRect(r, w.px(6), theme.PanelAlt)
	c.roundBorder(r, w.px(6), max(1, w.px(1)), theme.BorderStrong)
	c.text(font, key, r, theme.Text, dtCenter|dtSingleLine|dtVCenter)
	return r.Right
}

// padHasPrimary reports whether the current screen has an enabled main
// button for Start.
func (w *win) padHasPrimary() bool {
	for i := range w.last {
		if w.last[i].primary && !w.last[i].disabled {
			return true
		}
	}
	return false
}
