//go:build windows

package ui

import (
	"fmt"
	"strings"
	"time"

	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"github.com/snakex21/universal-service-os/installer/internal/install"
)

// logView is the collapsible, selectable operation log (native EDIT).
type logView struct {
	text strings.Builder
	edit *nativeEdit
	open bool
}

func (l *logView) append(message string) {
	message = strings.TrimSpace(message)
	if message == "" {
		return
	}
	chunk := message
	if l.text.Len() > 0 {
		chunk = "\n" + message
	}
	l.text.WriteString(chunk)
	if l.edit != nil {
		l.edit.appendText(chunk)
	}
}

func (l *logView) toggleSpec() buttonSpec {
	if l.open {
		return buttonSpec{label: i18n.T("installer.log.hide"), glyph: glyphChevronUp, trailing: true, onClick: func() { l.open = false }}
	}
	return buttonSpec{label: i18n.T("installer.log.show"), glyph: glyphChevronDown, trailing: true, onClick: func() { l.open = true }}
}

// draw places the log EDIT in r (only while open).
func (l *logView) draw(w *win, r rect) {
	if !l.open {
		return
	}
	w.canvas.roundRect(r, w.px(8), theme.Field)
	w.canvas.roundBorder(r, w.px(8), max(1, w.px(1)), theme.Border)
	inner := r.inset(w.px(10), w.px(8))
	created := l.edit == nil
	e, _ := w.edit("log", inner, editOptions{multiline: true, readonly: true, mono: true, fontSize: 12, initial: l.text.String()})
	l.edit = e
	if created {
		e.appendText("") // scroll to the end
	}
}

type progressScreen struct {
	f       *Flow
	op      operation
	model   *progressModel
	log     logView
	started time.Time
	ended   time.Time
	// lastActive/lastView: the stage scrolled into view last and the list
	// height at that time (opening the log shrinks the list).
	lastActive int
	lastView   int32
}

func newProgressScreen(f *Flow, op operation, events <-chan opEvent) *progressScreen {
	s := &progressScreen{f: f, op: op, model: newProgressModel(op.stages()), started: time.Now()}
	go func() {
		for event := range events {
			event := event
			f.w.post(func() { s.apply(event) })
		}
	}()
	return s
}

func (s *progressScreen) apply(e opEvent) {
	switch e.kind {
	case eventLog:
		s.log.append(e.message)
	case eventStage:
		s.model.apply(e)
	case eventFinished:
		if s.model.finished {
			return
		}
		s.model.apply(e)
		s.ended = time.Now()
		s.f.showFinal(s.op, e.verification, e.err, s.log.text.String())
	}
}

func formatElapsed(d time.Duration) string {
	d = d.Round(time.Second)
	h, m, sec := int(d.Hours()), int(d.Minutes())%60, int(d.Seconds())%60
	if h > 0 {
		return fmt.Sprintf("%d:%02d:%02d", h, m, sec)
	}
	return fmt.Sprintf("%02d:%02d", m, sec)
}

func (s *progressScreen) draw(f *Flow, w *win, area rect) {
	c := w.canvas
	body := w.pageTitle(area, s.op.progressTitle(), "", color{}, "")
	body.Top -= w.px(4)
	body.Top += w.banner(body.Left, body.Top, body.w(), s.op.progressWarning(), toneWarning) + w.px(16)

	// Overall progress card.
	overall := s.model.overall()
	cardH := w.px(112)
	card := rect{body.Left, body.Top, body.Right, body.Top + cardH}
	w.panel(card)
	inner := card.inset(w.px(20), w.px(16))
	current := i18n.T("installer.progress.preparing")
	if def, st, ok := s.model.current(); ok {
		current = i18n.T("installer.progress.step", def.Number, def.Total, s.op.stageName(def))
		if st == stateFailed {
			current = i18n.T("installer.common.error_detail", s.op.stageName(def))
		}
	} else if s.model.finished {
		current = i18n.T("installer.progress.finished")
	}
	pct := fmt.Sprintf("%d%%", int(overall*100+0.5))
	pctW := c.textWidth(w.font(sizeTitle, fwSemiBold), pct) + w.px(4)
	c.text(w.font(sizeTitle, fwSemiBold), pct, rect{inner.Right - pctW, inner.Top, inner.Right, inner.Top + w.px(32)}, theme.Accent, dtRight|dtSingleLine|dtVCenter)
	c.text(w.font(sizeH2, fwSemiBold), current, rect{inner.Left, inner.Top, inner.Right - pctW - w.px(12), inner.Top + w.px(32)}, theme.Text, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
	barR := rect{inner.Left, inner.Top + w.px(42), inner.Right, inner.Top + w.px(50)}
	w.progressBar(barR, overall, theme.Accent)
	elapsed := time.Since(s.started)
	if !s.ended.IsZero() {
		elapsed = s.ended.Sub(s.started)
	}
	info := rect{inner.Left, barR.Bottom + w.px(8), inner.Right, barR.Bottom + w.px(30)}
	elapsedText := i18n.T("installer.progress.elapsed", formatElapsed(elapsed))
	elapsedW := c.textWidth(w.captionFont(), elapsedText) + w.px(24)
	w.glyph(glyphClock, rect{info.Left, info.Top, info.Left + w.px(14), info.Bottom}, 12, theme.Muted)
	c.text(w.captionFont(), elapsedText, rect{info.Left + w.px(20), info.Top, info.Left + w.px(20) + elapsedW, info.Bottom}, theme.Muted, dtLeft|dtSingleLine|dtVCenter)
	c.text(w.captionFont(), i18n.T("installer.close.blocked"), rect{info.Left + w.px(20) + elapsedW, info.Top, info.Right, info.Bottom}, theme.Faint, dtRight|dtSingleLine|dtVCenter|dtEndEllipsis)
	w.animate = true // elapsed clock
	body.Top = card.Bottom + w.px(16)

	// Log toggle row at the bottom; the log takes 40 % of the rest when open.
	toggleH := w.px(32)
	toggleRow, rest := body.cutBottom(toggleH)
	if s.log.open {
		logH := rest.h() * 42 / 100
		logR, stagesR := rest.cutBottom(logH)
		stagesR.Bottom -= w.px(12)
		s.drawStages(w, stagesR)
		s.log.draw(w, rect{logR.Left, logR.Top, logR.Right, logR.Bottom - w.px(10)})
	} else {
		s.drawStages(w, rect{rest.Left, rest.Top, rest.Right, rest.Bottom - w.px(10)})
	}
	spec := s.log.toggleSpec()
	width := w.buttonWidth(spec)
	w.button("log.toggle", rect{toggleRow.Left, toggleRow.Top, toggleRow.Left + width, toggleRow.Bottom}, spec)
}

func (s *progressScreen) drawStages(w *win, r rect) {
	w.panel(r)
	view := r.inset(w.px(8), w.px(8))
	rowH := w.px(40)
	// Keep the running stage in view.
	for i, def := range s.model.defs {
		if st := s.model.states[def.ID]; st == stateActive || st == stateFailed {
			if sc := w.scrolls["stages"]; sc != nil && (s.lastActive != def.ID || s.lastView != view.h()) {
				top, bottom := int32(i)*rowH, int32(i+1)*rowH
				if top < sc.offset || bottom > sc.offset+view.h() {
					sc.offset = bottom - view.h() + rowH
				}
			}
			s.lastActive = def.ID
		}
	}
	s.lastView = view.h()
	offset := w.beginScroll("stages", view)
	y := view.Top - offset
	for _, def := range s.model.defs {
		drawStageRow(w, rect{view.Left, y, view.Right - w.px(8), y + rowH}, s.op, def, s.model)
		y += rowH
	}
	w.endScroll("stages", view, int32(len(s.model.defs))*rowH)
}

func drawStageRow(w *win, r rect, op operation, def stageDef, m *progressModel) {
	c := w.canvas
	state := m.states[def.ID]
	if state == stateActive {
		c.roundRect(r, w.px(6), theme.PanelAlt)
	}
	cx, cy := r.Left+w.px(22), r.Top+r.h()/2
	icon := rect{cx - w.px(12), cy - w.px(12), cx + w.px(12), cy + w.px(12)}
	nameCol, statusText, statusCol := theme.Muted, i18n.T("installer.common.pending"), theme.Faint
	switch state {
	case stateActive:
		w.spinner(cx, cy, w.px(8), theme.Accent)
		nameCol, statusText, statusCol = theme.Text, i18n.T("installer.common.active"), theme.Accent
		if m.known[def.ID] {
			statusText = fmt.Sprintf("%d%%", int(m.progress[def.ID]*100+0.5))
		}
	case stateSucceeded:
		w.glyph(glyphCheckSolid, icon, 18, theme.Success)
		nameCol, statusText, statusCol = theme.Text, i18n.T("installer.common.done"), theme.Success
	case stateFailed:
		w.glyph(glyphErrorSolid, icon, 18, theme.Danger)
		nameCol, statusText, statusCol = theme.Danger.mix(theme.Text, 0.3), i18n.T("installer.common.error"), theme.Danger
	default:
		w.glyph(glyphCircleOuter, icon, 18, theme.Border)
	}
	x := r.Left + w.px(46)
	c.text(w.captionFont(), fmt.Sprintf("%d/%d", def.Number, def.Total), rect{x, r.Top, x + w.px(36), r.Bottom}, theme.Faint, dtLeft|dtSingleLine|dtVCenter)
	x += w.px(40)
	statusW := w.px(150)
	nameR := rect{x, r.Top, r.Right - statusW - w.px(12), r.Bottom}
	font := w.bodyFont()
	if state == stateActive {
		font = w.semiFont()
	}
	c.text(font, op.stageName(def), nameR, nameCol, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
	statusR := rect{r.Right - statusW, r.Top, r.Right - w.px(10), r.Bottom}
	if state == stateActive && m.known[def.ID] {
		bar := rect{statusR.Left, cy - w.px(3), statusR.Right - w.px(48), cy + w.px(3)}
		w.progressBar(bar, m.progress[def.ID], theme.Accent)
	}
	c.text(w.captionFont(), statusText, statusR, statusCol, dtRight|dtSingleLine|dtVCenter)
}

func (s *progressScreen) key(f *Flow, w *win, vk uintptr) bool { return false }

// ---- final report -----------------------------------------------------------

type finalScreen struct {
	f      *Flow
	op     operation
	report install.VerificationReport
	err    error
	log    logView
}

func newFinalScreen(f *Flow, op operation, report *install.VerificationReport, err error, log string) *finalScreen {
	s := &finalScreen{f: f, op: op, err: err}
	if report != nil {
		s.report = *report
	}
	s.log.text.WriteString(log)
	return s
}

func (s *finalScreen) texts() (title, status string, ok bool) {
	ok = s.err == nil && s.report.OK()
	name := s.op.name()
	if ok {
		return i18n.T("installer.final.success_title", name), i18n.T("installer.final.success_status"), true
	}
	if len(s.report.Items) > 0 && !s.report.OK() {
		return i18n.T("installer.final.verify_failed_title", name), i18n.T("installer.final.verify_failed_status"), false
	}
	return i18n.T("installer.final.failed_title", name), i18n.T("installer.final.failed_status"), false
}

func (s *finalScreen) draw(f *Flow, w *win, area rect) {
	c := w.canvas
	bar, body := w.actionBar(area)
	title, status, ok := s.texts()
	col, glyph := theme.Success, glyphCheckSolid
	if !ok {
		col, glyph = theme.Danger, glyphErrorSolid
	}
	// Result header.
	iconR := rect{body.Left, body.Top, body.Left + w.px(48), body.Top + w.px(48)}
	c.circle(float64(iconR.Left+iconR.w()/2), float64(iconR.Top+iconR.h()/2), float64(w.px(24)), col.mix(theme.Background, 0.8))
	w.glyph(glyph, iconR, 28, col)
	tx := iconR.Right + w.px(16)
	c.text(w.font(sizeTitle, fwSemiBold), title, rect{tx, body.Top, body.Right, body.Top + w.px(30)}, theme.Text, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
	sh := w.wrapped(w.bodyFont(), status, tx, body.Top+w.px(32), body.Right-tx, theme.Muted)
	y := max(iconR.Bottom, body.Top+w.px(32)+sh) + w.px(16)
	if s.err != nil {
		y += w.banner(body.Left, y, body.w(), i18n.T("installer.common.error_detail", s.err.Error()), toneDanger) + w.px(16)
	}
	toggleRow, rest := rect{body.Left, y, body.Right, body.Bottom}.cutBottom(w.px(32))
	if s.log.open {
		logR, tableR := rest.cutBottom(rest.h() * 42 / 100)
		s.drawReport(w, rect{tableR.Left, tableR.Top, tableR.Right, tableR.Bottom - w.px(12)})
		s.log.draw(w, rect{logR.Left, logR.Top, logR.Right, logR.Bottom - w.px(10)})
	} else {
		s.drawReport(w, rect{rest.Left, rest.Top, rest.Right, rest.Bottom - w.px(10)})
	}
	spec := s.log.toggleSpec()
	w.button("log.toggle", rect{toggleRow.Left, toggleRow.Top, toggleRow.Left + w.buttonWidth(spec), toggleRow.Bottom}, spec)
	w.actions(bar, nil, []action{{"action.primary", buttonSpec{label: i18n.T("installer.final.back"), style: buttonPrimary, onClick: f.showModes}}})
}

func (s *finalScreen) drawReport(w *win, r rect) {
	c := w.canvas
	w.panel(r)
	inner := r.inset(w.px(16), w.px(12))
	if len(s.report.Items) == 0 {
		c.text(w.bodyFont(), i18n.T("installer.final.no_report"), inner, theme.Muted, dtCenter|dtSingleLine|dtVCenter)
		return
	}
	resultW := w.px(120)
	rest := inner.w() - resultW - w.px(12)
	cols := []int32{rest * 26 / 100, rest * 37 / 100, rest - rest*26/100 - rest*37/100}
	headers := []string{i18n.T("installer.final.header.check"), i18n.T("installer.final.header.expected"), i18n.T("installer.final.header.actual"), i18n.T("installer.final.header.result")}
	x := inner.Left
	headH := w.px(28)
	for i, h := range headers {
		width := resultW
		if i < 3 {
			width = cols[i]
		}
		c.text(w.font(sizeCaption, fwSemiBold), h, rect{x, inner.Top, x + width - w.px(10), inner.Top + headH}, theme.Muted, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
		x += width + w.px(4)
	}
	w.separator(inner.Left, inner.Right, inner.Top+headH)
	view := rect{inner.Left, inner.Top + headH + w.px(4), inner.Right, inner.Bottom}
	offset := w.beginScroll("report", view)
	y := view.Top - offset
	for _, item := range s.report.Items {
		values := []string{item.Name, item.Expected, item.Actual}
		rowH := w.px(20)
		for i, v := range values {
			rowH = max(rowH, c.measure(w.bodyFont(), v, cols[i]-w.px(12)))
		}
		rowH += w.px(12)
		x := inner.Left
		for i, v := range values {
			col := theme.Text
			if i > 0 {
				col = theme.Muted
			}
			if !item.Match && i > 0 {
				col = theme.Danger.mix(theme.Text, 0.35)
			}
			c.text(w.bodyFont(), v, rect{x, y + w.px(6), x + cols[i] - w.px(12), y + rowH}, col, dtLeft|dtWordBreak|dtEditControl)
			x += cols[i] + w.px(4)
		}
		label, t := i18n.T("installer.final.match"), toneSuccess
		if !item.Match {
			label, t = i18n.T("installer.final.mismatch"), toneDanger
		}
		w.badge(label, x+w.badgeWidth(label), y+w.px(6)+w.px(10), t)
		y += rowH
		w.separator(inner.Left, inner.Right-w.px(10), y)
		y += w.px(1)
	}
	w.endScroll("report", view, y+offset-view.Top)
}

func (s *finalScreen) key(f *Flow, w *win, vk uintptr) bool { return false }

// ---- startup error ----------------------------------------------------------

type errorScreen struct {
	message string
}

func (s *errorScreen) draw(f *Flow, w *win, area rect) {
	c := w.canvas
	width := min(area.w(), w.px(720))
	textW := width - w.px(48)
	msgH := c.measure(w.bodyFont(), s.message, textW)
	h := w.px(24+48+16+30+16) + msgH + w.px(24+buttonHeight+24)
	card := area.centered(width, min(h, area.h()))
	w.panel(card)
	iconR := rect{card.Left + w.px(24), card.Top + w.px(24), card.Left + w.px(72), card.Top + w.px(72)}
	c.circle(float64(iconR.Left+w.px(24)), float64(iconR.Top+w.px(24)), float64(w.px(24)), theme.DangerSoft)
	w.glyph(glyphErrorSolid, iconR, 28, theme.Danger)
	y := iconR.Bottom + w.px(16)
	c.text(w.font(sizeTitle, fwSemiBold), i18n.T("installer.startup.title"), rect{card.Left + w.px(24), y, card.Right - w.px(24), y + w.px(30)}, theme.Text, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
	y += w.px(30 + 16)
	c.text(w.bodyFont(), s.message, rect{card.Left + w.px(24), y, card.Left + w.px(24) + textW, y + msgH}, theme.Muted, dtLeft|dtWordBreak|dtEditControl)
	bar := rect{card.Left + w.px(24), card.Bottom - w.px(24+buttonHeight), card.Right - w.px(24), card.Bottom - w.px(24)}
	w.actions(bar, nil, []action{{"startup.close", buttonSpec{label: i18n.T("installer.startup.close"), style: buttonPrimary, onClick: func() {
		procPostMessageW.Call(uintptr(w.hwnd), wmClose, 0, 0)
	}}}})
}

func (s *errorScreen) key(f *Flow, w *win, vk uintptr) bool {
	if vk == vkEscape {
		procPostMessageW.Call(uintptr(w.hwnd), wmClose, 0, 0)
		return true
	}
	return false
}
