//go:build windows

package ui

// Page-level layout helpers shared by the screens.

// pageTitle draws a title with an optional wrapped subtitle and returns the
// area below it. titleColor zero means the normal text colour.
func (w *win) pageTitle(area rect, title, subtitle string, titleColor color, glyph string) rect {
	c := w.canvas
	if titleColor == (color{}) {
		titleColor = theme.Text
	}
	x := area.Left
	if glyph != "" {
		tile := rect{x, area.Top, x + w.px(32), area.Top + w.px(32)}
		c.roundRect(tile, w.px(8), titleColor.mix(theme.Background, 0.82))
		w.glyph(glyph, tile, 16, titleColor)
		x += w.px(44)
	}
	c.text(w.font(sizeTitle, fwSemiBold), title, rect{x, area.Top, area.Right, area.Top + w.px(32)}, titleColor, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
	y := area.Top + w.px(36)
	if subtitle != "" {
		y += w.wrapped(w.bodyFont(), subtitle, area.Left, y, area.w(), theme.Muted)
	}
	return rect{area.Left, y + w.px(16), area.Right, area.Bottom}
}

type action struct {
	id   string
	spec buttonSpec
}

// actionBar reserves the bottom button row and returns (bar, rest).
func (w *win) actionBar(area rect) (rect, rect) {
	bar, rest := area.cutBottom(w.px(buttonHeight))
	w.separator(area.Left, area.Right, bar.Top-w.px(14))
	rest.Bottom = bar.Top - w.px(28)
	return bar, rest
}

// actions lays out buttons: left group from the left edge, right group
// ending at the right edge; tab order follows visual order.
func (w *win) actions(bar rect, left, right []action) {
	x := bar.Left
	for _, a := range left {
		width := max(w.buttonWidth(a.spec), w.px(96))
		w.button(a.id, rect{x, bar.Top, x + width, bar.Bottom}, a.spec)
		x += width + w.px(10)
	}
	total := int32(0)
	widths := make([]int32, len(right))
	for i, a := range right {
		widths[i] = max(w.buttonWidth(a.spec), w.px(120))
		total += widths[i]
	}
	total += int32(max(0, len(right)-1)) * w.px(10)
	x = bar.Right - total
	for i, a := range right {
		w.button(a.id, rect{x, bar.Top, x + widths[i], bar.Bottom}, a.spec)
		x += widths[i] + w.px(10)
	}
}
