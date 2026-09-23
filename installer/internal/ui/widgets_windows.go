//go:build windows

package ui

import (
	"math"
	"time"

	"golang.org/x/sys/windows"
)

// Type scale and metrics in DIPs.
const (
	sizeCaption = 12
	sizeBody    = 14
	sizeLead    = 15
	sizeH2      = 16
	sizeTitle   = 22

	radiusCard   = 10
	radiusButton = 6
	buttonHeight = 36
	pad          = 24
)

type buttonStyle int

const (
	buttonSecondary buttonStyle = iota
	buttonPrimary
	buttonDanger
	buttonGhost
)

type buttonSpec struct {
	label    string
	glyph    string
	style    buttonStyle
	disabled bool
	onClick  func()
	// trailing places the glyph after the label (dropdown chevrons).
	trailing bool
	// commits marks a button that starts a disk operation. With primary
	// (set by actions for the right-most button) the gamepad Start button
	// only focuses such a button and never presses it.
	commits bool
	primary bool
}

func (w *win) bodyFont() windows.Handle    { return w.font(sizeBody, fwNormal) }
func (w *win) semiFont() windows.Handle    { return w.font(sizeBody, fwSemiBold) }
func (w *win) captionFont() windows.Handle { return w.font(sizeCaption, fwNormal) }

func (w *win) buttonWidth(b buttonSpec) int32 {
	width := w.canvas.textWidth(w.semiFont(), b.label)
	if b.glyph != "" {
		width += w.px(16)
		if b.label != "" {
			width += w.px(8)
		}
	}
	return width + w.px(32)
}

func (w *win) button(id string, r rect, b buttonSpec) widgetState {
	st := w.add(widget{id: id, r: r, focusable: true, disabled: b.disabled, onClick: b.onClick,
		primary: b.primary, guarded: b.commits || b.style == buttonDanger})
	var bg, fg, border color
	switch b.style {
	case buttonPrimary:
		bg, fg = theme.Accent, theme.OnAccent
		if st.hot {
			bg = theme.AccentHover
		}
		if st.pressed {
			bg = theme.AccentPressed
		}
	case buttonDanger:
		bg, fg = theme.Danger, color{0xff, 0xff, 0xff}
		if st.hot {
			bg = theme.DangerHover
		}
		if st.pressed {
			bg = theme.Danger.mix(theme.Background, 0.25)
		}
	case buttonGhost:
		bg, fg = theme.Header, theme.Text
		if st.hot {
			bg = theme.PanelAlt
		}
		if st.pressed {
			bg = theme.Panel
		}
	default:
		bg, fg, border = theme.PanelAlt, theme.Text, theme.Border
		if st.hot {
			bg, border = theme.PanelAlt.mix(theme.Text, 0.06), theme.BorderStrong
		}
		if st.pressed {
			bg = theme.Panel
		}
	}
	if b.disabled {
		bg, fg, border = theme.Disabled, theme.DisabledText, color{}
	}
	radius := w.px(radiusButton)
	w.canvas.roundRect(r, radius, bg)
	if border != (color{}) {
		w.canvas.roundBorder(r, radius, max(1, w.px(1)), border)
	}
	if st.ring {
		w.focusRing(r, radius)
	}
	// Content: optional glyph + label, centred.
	labelW := w.canvas.textWidth(w.semiFont(), b.label)
	glyphW := int32(0)
	if b.glyph != "" {
		glyphW = w.px(16)
	}
	spacing := int32(0)
	if glyphW > 0 && labelW > 0 {
		spacing = w.px(8)
	}
	total := labelW + glyphW + spacing
	x := r.Left + (r.w()-total)/2
	if b.trailing {
		w.canvas.text(w.semiFont(), b.label, rect{x, r.Top, x + labelW + 1, r.Bottom}, fg, dtLeft|dtSingleLine|dtVCenter)
		if glyphW > 0 {
			w.glyph(b.glyph, rect{x + labelW + spacing, r.Top, x + total, r.Bottom}, 12, fg)
		}
		return st
	}
	if glyphW > 0 {
		w.glyph(b.glyph, rect{x, r.Top, x + glyphW, r.Bottom}, 16, fg)
		x += glyphW + spacing
	}
	w.canvas.text(w.semiFont(), b.label, rect{x, r.Top, x + labelW + 1, r.Bottom}, fg, dtLeft|dtSingleLine|dtVCenter)
	return st
}

// focusRing draws the keyboard focus indicator around r.
func (w *win) focusRing(r rect, radius int32) {
	o := w.px(3)
	w.canvas.roundBorder(rect{r.Left - o, r.Top - o, r.Right + o, r.Bottom + o}, radius+o, max(1, w.px(2)), theme.Accent)
}

// glyph draws a Segoe MDL2 Assets symbol centred in r.
func (w *win) glyph(g string, r rect, size int32, col color) {
	w.canvas.text(w.glyphFont(size), g, r, col, dtCenter|dtSingleLine|dtVCenter)
}

// wrapped draws word-wrapped text starting at (x, y) and returns its height.
func (w *win) wrapped(font windows.Handle, s string, x, y, width int32, col color) int32 {
	h := w.canvas.measure(font, s, width)
	w.canvas.text(font, s, rect{x, y, x + width, y + h}, col, dtLeft|dtWordBreak|dtEditControl)
	return h
}

type tone int

const (
	toneNeutral tone = iota
	toneAccent
	toneSuccess
	toneWarning
	toneDanger
)

func toneColors(t tone) (fg, bg color) {
	switch t {
	case toneAccent:
		return theme.Accent, theme.AccentSoft
	case toneSuccess:
		return theme.Success, theme.SuccessSoft
	case toneWarning:
		return theme.Warning, theme.WarningSoft
	case toneDanger:
		return theme.Danger, theme.DangerSoft
	default:
		return theme.Muted, theme.PanelAlt.mix(theme.Border, 0.45)
	}
}

func toneGlyph(t tone) string {
	switch t {
	case toneSuccess:
		return glyphCompleted
	case toneWarning:
		return glyphWarning
	case toneDanger:
		return glyphErrorCircle
	default:
		return glyphInfo
	}
}

func (w *win) badgeWidth(text string) int32 {
	return w.canvas.textWidth(w.font(sizeCaption, fwSemiBold), text) + w.px(20)
}

// badge draws a pill whose right edge is at right, vertically centred on cy.
func (w *win) badge(text string, right, cy int32, t tone) rect {
	fg, bg := toneColors(t)
	width := w.badgeWidth(text)
	h := w.px(22)
	r := rect{right - width, cy - h/2, right, cy - h/2 + h}
	w.canvas.roundRect(r, h/2, bg)
	w.canvas.text(w.font(sizeCaption, fwSemiBold), text, r, fg, dtCenter|dtSingleLine|dtVCenter)
	return r
}

func (w *win) bannerHeight(width int32, text string) int32 {
	textW := width - w.px(16+20+12+16)
	return max(w.px(44), w.canvas.measure(w.bodyFont(), text, textW)+w.px(24))
}

// banner draws a status message with a tone icon; returns its height.
func (w *win) banner(x, y, width int32, text string, t tone) int32 {
	h := w.bannerHeight(width, text)
	fg, bg := toneColors(t)
	r := rect{x, y, x + width, y + h}
	w.canvas.roundRect(r, w.px(8), bg)
	w.canvas.fill(rect{r.Left, r.Top + w.px(8), r.Left + w.px(3), r.Bottom - w.px(8)}, fg)
	w.glyph(toneGlyph(t), rect{x + w.px(16), y, x + w.px(36), y + w.px(44)}, 16, fg)
	textX := x + w.px(16+20+12)
	textW := width - w.px(16+20+12+16)
	th := w.canvas.measure(w.bodyFont(), text, textW)
	w.canvas.text(w.bodyFont(), text, rect{textX, y + (h-th)/2, textX + textW, y + (h-th)/2 + th}, theme.Text, dtLeft|dtWordBreak|dtEditControl)
	return h
}

func (w *win) panel(r rect) {
	w.canvas.roundRect(r, w.px(radiusCard), theme.Panel)
	w.canvas.roundBorder(r, w.px(radiusCard), max(1, w.px(1)), theme.Border)
}

func (w *win) separator(x0, x1, y int32) {
	w.canvas.fill(rect{x0, y, x1, y + max(1, w.px(1))}, theme.Border)
}

func (w *win) progressBar(r rect, fraction float64, col color) {
	fraction = math.Max(0, math.Min(1, fraction))
	radius := r.h() / 2
	w.canvas.roundRect(r, radius, theme.Field)
	if fraction <= 0 {
		return
	}
	fillW := max(r.h(), int32(float64(r.w())*fraction+0.5))
	w.canvas.roundRect(rect{r.Left, r.Top, r.Left + fillW, r.Bottom}, radius, col)
}

// spinner draws a rotating arc and keeps the animation timer running.
func (w *win) spinner(cx, cy, radius int32, col color) {
	w.animate = true
	t := float64(time.Now().UnixMilli()%1200) / 1200
	start := t * 2 * math.Pi
	w.canvas.arc(float64(cx), float64(cy), float64(radius), float64(max(2, w.px(2))), 0, 2*math.Pi-0.01, theme.Border)
	w.canvas.arc(float64(cx), float64(cy), float64(radius), float64(max(2, w.px(2))), start, math.Pi*0.6, col)
}

// checkbox draws a toggle with a wrapped label; returns the used height.
func (w *win) checkbox(id string, x, y, width int32, label string, checked bool, onToggle func()) int32 {
	box := w.px(20)
	textX := x + box + w.px(12)
	textW := width - box - w.px(12)
	th := max(box, w.canvas.measure(w.bodyFont(), label, textW))
	r := rect{x - w.px(6), y - w.px(6), x + width + w.px(6), y + th + w.px(6)}
	st := w.add(widget{id: id, r: r, focusable: true, onClick: onToggle})
	br := rect{x, y + (min(th, w.px(22))-box)/2, x + box, y + (min(th, w.px(22))-box)/2 + box}
	if checked {
		w.canvas.roundRect(br, w.px(4), theme.Danger)
		w.glyph(glyphCheck, br, 14, color{0xff, 0xff, 0xff})
	} else {
		border := theme.BorderStrong
		if st.hot {
			border = theme.Muted
		}
		w.canvas.roundRect(br, w.px(4), theme.Field)
		w.canvas.roundBorder(br, w.px(4), max(1, w.px(1)), border)
	}
	if st.ring {
		w.focusRing(r, w.px(6))
	}
	w.canvas.text(w.bodyFont(), label, rect{textX, y, textX + textW, y + th}, theme.Text, dtLeft|dtWordBreak|dtEditControl)
	return th
}

// kvRow draws a label/value pair; the value wraps. Returns the row height.
func (w *win) kvRow(x, y, labelW, width int32, label, value string) int32 {
	h := w.kvHeight(labelW, width, label, value)
	// A label too long for its column (long translations) wraps instead of
	// being cut off.
	labelR := rect{x, y + w.px(1), x + labelW - w.px(8), y + w.px(20)}
	if w.canvas.textWidth(w.captionFont(), label) > labelR.w() {
		labelR.Bottom = y + h
		w.canvas.text(w.captionFont(), label, labelR, theme.Muted, dtLeft|dtWordBreak|dtEditControl)
	} else {
		w.canvas.text(w.captionFont(), label, labelR, theme.Muted, dtLeft|dtSingleLine|dtVCenter)
	}
	w.canvas.text(w.bodyFont(), value, rect{x + labelW, y, x + width, y + h}, theme.Text, dtLeft|dtWordBreak|dtEditControl)
	return h
}

func (w *win) kvHeight(labelW, width int32, label, value string) int32 {
	h := max(w.px(20), w.canvas.measure(w.bodyFont(), value, width-labelW))
	if w.canvas.textWidth(w.captionFont(), label) > labelW-w.px(8) {
		h = max(h, w.canvas.measure(w.captionFont(), label, labelW-w.px(8))+w.px(1))
	}
	return h
}

// textField draws the frame of a native single-line EDIT and places it.
func (w *win) textField(id string, r rect, o editOptions) (*nativeEdit, widgetState) {
	inner := rect{r.Left + w.px(12), r.Top, r.Right - w.px(12), r.Bottom}
	lineH := w.canvas.lineHeight(w.editFontFor(o)) + w.px(2)
	inner.Top = r.Top + (r.h()-lineH)/2
	inner.Bottom = inner.Top + lineH
	radius := w.px(radiusButton)
	w.canvas.roundRect(r, radius, theme.Field)
	e, st := w.edit(id, inner, o)
	border := theme.BorderStrong
	thickness := max(1, w.px(1))
	if st.focused {
		border = theme.Accent
		thickness = max(2, w.px(2))
	}
	if o.disabled {
		border = theme.Disabled
	}
	w.canvas.roundBorder(r, radius, thickness, border)
	return e, st
}

func (w *win) editFontFor(o editOptions) windows.Handle {
	size := o.fontSize
	if size == 0 {
		size = 14
	}
	if o.mono {
		return w.mono(size)
	}
	return w.font(size, fwNormal)
}
