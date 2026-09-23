//go:build windows

package ui

import (
	"fmt"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
)

// driveEntry is one row of a drive list plus what its details panel shows.
type driveEntry struct {
	title      string
	meta       string
	reason     string
	badge      string
	badgeTone  tone
	selectable bool
	kind       driveKind
	details    [][2]string
	root       string
}

// driveList is a keyboard-navigable list of drives (one focus stop: "list").
type driveList struct {
	selected int
	entries  []driveEntry
}

func busLabel(d domain.Disk) string {
	if name := d.BusName(); name != "" {
		return name
	}
	return i18n.T("installer.bus.unknown")
}

func joinMeta(parts ...string) string {
	kept := parts[:0]
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" && p != "-" {
			kept = append(kept, p)
		}
	}
	return strings.Join(kept, "  ·  ")
}

func diskDetails(d domain.Disk, row domain.DeviceRow) [][2]string {
	serial := d.DisplaySerial()
	if serial == "" {
		serial = "-"
	}
	return [][2]string{
		{i18n.T("installer.field.disk"), fmt.Sprintf("PhysicalDrive%d", d.Number)},
		{i18n.T("installer.field.capacity"), row.Capacity},
		{i18n.T("installer.field.bus"), busLabel(d)},
		{i18n.T("installer.field.serial"), serial},
		{i18n.T("installer.field.letters"), row.Letters},
		{i18n.T("installer.field.labels"), row.Labels},
		{i18n.T("installer.field.filesystem"), row.FileSystems},
		{i18n.T("installer.field.used"), row.Used},
	}
}

func (l *driveList) move(delta int) {
	if len(l.entries) == 0 {
		return
	}
	if l.selected < 0 {
		l.selected = 0
		return
	}
	l.selected = max(0, min(len(l.entries)-1, l.selected+delta))
}

// draw renders the list inside r. status is shown above the rows.
func (l *driveList) draw(w *win, r rect, status string, statusTone tone, loading bool, empty string, onEnter func()) {
	c := w.canvas
	head, body := r.cutTop(w.px(28))
	if loading {
		w.spinner(head.Left+w.px(8), head.Top+head.h()/2, w.px(7), theme.Accent)
		c.text(w.captionFont(), status, rect{head.Left + w.px(24), head.Top, head.Right, head.Bottom}, theme.Muted, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
	} else {
		col := theme.Muted
		if statusTone == toneDanger {
			col = theme.Danger
		}
		c.text(w.captionFont(), status, head, col, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
	}
	body.Top += w.px(4)
	st := w.add(widget{id: "list", r: body, focusable: true, onKey: func(vk uintptr) bool {
		switch vk {
		case vkUp:
			l.move(-1)
		case vkDown:
			l.move(1)
		case vkHome:
			l.selected = 0
		case vkEnd:
			l.selected = len(l.entries) - 1
		case vkPrior:
			l.move(-5)
		case vkNext:
			l.move(5)
		case vkReturn:
			if onEnter != nil {
				onEnter()
			}
			return true
		default:
			return false
		}
		l.ensureSelectedVisible(w)
		return true
	}})
	w.panel(body)
	listFocused := st.focused
	view := body.inset(w.px(6), w.px(6))
	if len(l.entries) == 0 {
		if !loading {
			w.glyph(glyphUSB, rect{view.Left, view.Top + view.h()/2 - w.px(44), view.Right, view.Top + view.h()/2}, 28, theme.Faint)
			c.text(w.bodyFont(), empty, rect{view.Left + w.px(16), view.Top + view.h()/2, view.Right - w.px(16), view.Top + view.h()/2 + w.px(48)}, theme.Muted, dtCenter|dtWordBreak)
		}
		if st.ring {
			w.focusRing(body, w.px(radiusCard))
		}
		return
	}
	rowH := w.px(64)
	rowGap := w.px(4)
	offset := w.beginScroll("list.scroll", view)
	y := view.Top - offset
	for i := range l.entries {
		e := &l.entries[i]
		row := rect{view.Left, y, view.Right - w.px(8), y + rowH}
		idx := i
		rs := w.add(widget{id: fmt.Sprintf("list.row.%d", i), r: row, onClick: func() {
			l.selected = idx
			w.focus = "list"
		}})
		l.drawRow(w, row, e, i == l.selected, rs.hot, listFocused && w.cues && i == l.selected)
		y += rowH + rowGap
	}
	w.endScroll("list.scroll", view, int32(len(l.entries))*(rowH+rowGap)-rowGap)
	if st.ring && l.selected < 0 {
		w.focusRing(body, w.px(radiusCard))
	}
}

func (l *driveList) ensureSelectedVisible(w *win) {
	if l.selected < 0 {
		return
	}
	if wd := w.findLast(fmt.Sprintf("list.row.%d", l.selected)); wd != nil {
		w.ensureVisible("list.scroll", wd.full)
	}
}

func (l *driveList) drawRow(w *win, r rect, e *driveEntry, selected, hot, ring bool) {
	c := w.canvas
	radius := w.px(8)
	switch {
	case selected:
		c.roundRect(r, radius, theme.Selected.mix(theme.Panel, 0.45))
		c.roundBorder(r, radius, max(1, w.px(1)), theme.Accent.mix(theme.Selected, 0.4))
		c.fill(rect{r.Left, r.Top + w.px(12), r.Left + w.px(3), r.Bottom - w.px(12)}, theme.Accent)
	case hot:
		c.roundRect(r, radius, theme.PanelAlt)
	}
	if ring {
		w.focusRing(r, radius)
	}
	iconSize := w.px(32)
	w.driveIcon(e.kind, r.Left+w.px(14), r.Top+(r.h()-iconSize)/2, iconSize)
	badgeRect := w.badge(e.badge, r.Right-w.px(14), r.Top+r.h()/2, e.badgeTone)
	textX := r.Left + w.px(14) + iconSize + w.px(14)
	textR := badgeRect.Left - w.px(12)
	titleCol := theme.Text
	if !e.selectable {
		titleCol = theme.Muted
	}
	titleR := rect{textX, r.Top + w.px(11), textR, r.Top + w.px(32)}
	c.text(w.semiFont(), e.title, titleR, titleCol, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
	line2, col := e.meta, theme.Muted
	if e.reason != "" {
		// Rejected rows use line 2 for the reason; bus and size move up
		// next to the model.
		line2, col = e.reason, theme.Warning
		if tw := c.textWidth(w.semiFont(), e.title); titleR.Left+tw+w.px(16) < titleR.Right {
			c.text(w.captionFont(), e.meta, rect{titleR.Left + tw + w.px(12), titleR.Top, titleR.Right, titleR.Bottom}, theme.Faint, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
		}
	}
	c.text(w.captionFont(), line2, rect{textX, r.Top + w.px(34), textR, r.Top + w.px(52)}, col, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
}

// drawDetails renders the right-hand panel for the selected entry.
func drawDetails(w *win, r rect, e *driveEntry, hint string) {
	c := w.canvas
	w.panel(r)
	inner := r.inset(w.px(20), w.px(18))
	if e == nil {
		mid := inner.Top + inner.h()/2
		w.glyph(glyphDrive, rect{inner.Left, mid - w.px(48), inner.Right, mid - w.px(8)}, 30, theme.Faint)
		c.text(w.bodyFont(), hint, rect{inner.Left, mid, inner.Right, mid + w.px(60)}, theme.Muted, dtCenter|dtWordBreak)
		return
	}
	offset := w.beginScroll("details.scroll", inner)
	y := inner.Top - offset
	iconSize := w.px(48)
	w.driveIcon(e.kind, inner.Left, y, iconSize)
	tx := inner.Left + iconSize + w.px(14)
	titleW := inner.Right - tx - w.px(10)
	th := c.measure(w.font(sizeH2, fwSemiBold), e.title, titleW)
	c.text(w.font(sizeH2, fwSemiBold), e.title, rect{tx, y, tx + titleW, y + th}, theme.Text, dtLeft|dtWordBreak|dtEditControl)
	badgeY := y + th + w.px(16)
	bw := w.badgeWidth(e.badge)
	w.badge(e.badge, tx+bw, badgeY, e.badgeTone)
	y += max(iconSize, th+w.px(30)) + w.px(16)
	if e.reason != "" {
		y += w.banner(inner.Left, y, inner.w()-w.px(10), e.reason, toneWarning) + w.px(14)
	}
	w.separator(inner.Left, inner.Right-w.px(10), y)
	y += w.px(14)
	labelW := min(w.px(130), inner.w()/3)
	for _, kv := range e.details {
		y += w.kvRow(inner.Left, y, labelW, inner.w()-w.px(10), kv[0], kv[1]) + w.px(8)
	}
	y += w.px(6)
	c.text(w.captionFont(), i18n.T("installer.field.root_contents"), rect{inner.Left, y, inner.Right, y + w.px(18)}, theme.Muted, dtLeft|dtSingleLine|dtVCenter)
	y += w.px(22)
	y += w.wrapped(w.bodyFont(), e.root, inner.Left, y, inner.w()-w.px(10), theme.Text)
	w.endScroll("details.scroll", inner, y+offset-inner.Top)
}

// ---- install: every disk, eligibility enforced ----------------------------

type deviceScreen struct {
	f       *Flow
	loading bool
	err     error
	disks   []domain.Disk
	hidden  int
	list    driveList
	gen     int
}

func newDeviceScreen(f *Flow) *deviceScreen {
	s := &deviceScreen{f: f}
	s.list.selected = -1
	s.refresh()
	return s
}

func (s *deviceScreen) refreshing() bool { return s.loading }

func (s *deviceScreen) refresh() {
	s.loading = true
	s.list.selected = -1
	s.gen++
	gen := s.gen
	source, installedSource := s.f.cfg.Disks, s.f.cfg.Installed
	go func() {
		disks, err := source.ListDisks()
		hidden := 0
		if err == nil && installedSource != nil {
			// Drives that already carry USOS are hidden from installation;
			// they are handled by update, repair or uninstall.
			if targets, tErr := installedSource.ListInstalledUSOS(); tErr == nil && len(targets) > 0 {
				hide := map[uint32]bool{}
				for _, t := range targets {
					hide[t.Disk.Number] = true
				}
				kept := make([]domain.Disk, 0, len(disks))
				for _, d := range disks {
					if !hide[d.Number] {
						kept = append(kept, d)
					}
				}
				hidden = len(disks) - len(kept)
				disks = kept
			}
		}
		s.f.w.post(func() {
			if gen != s.gen {
				return
			}
			s.loading, s.err = false, err
			if err != nil {
				s.disks, s.hidden = nil, 0
			} else {
				s.disks, s.hidden = disks, hidden
			}
			// Nothing is preselected: the user picks the target explicitly.
			s.list.selected = -1
		})
	}()
}

// relocalize re-derives the translated rejection reasons after a language
// change; eligibility itself is never recomputed into a different verdict.
func (s *deviceScreen) relocalize() {
	for i, d := range s.disks {
		if again := domain.ApplyEligibility(d); again.Eligible == d.Eligible {
			s.disks[i].Reason = again.Reason
		}
	}
}

func (s *deviceScreen) entries() []driveEntry {
	out := make([]driveEntry, len(s.disks))
	for i, d := range s.disks {
		row := domain.BuildDeviceRow(d)
		e := driveEntry{
			title:      row.Model,
			meta:       joinMeta(busLabel(d), row.Capacity, row.Letters),
			selectable: row.Selectable,
			kind:       classifyDrive(d),
			details:    diskDetails(d, row),
			root:       row.RootContents,
		}
		if row.Selectable {
			e.badge, e.badgeTone = i18n.T("installer.badge.ready"), toneSuccess
		} else {
			e.badge, e.badgeTone = i18n.T("installer.badge.rejected"), toneNeutral
			e.reason = i18n.T("installer.device.rejected", row.Reason)
		}
		e.details = append(e.details, [2]string{i18n.T("installer.field.state"), deviceState(row)})
		out[i] = e
	}
	return out
}

func deviceState(row domain.DeviceRow) string {
	if row.Selectable {
		return i18n.T("installer.device.ready")
	}
	return i18n.T("installer.device.rejected", row.Reason)
}

func (s *deviceScreen) canContinue() bool {
	return !s.loading && s.list.selected >= 0 && s.list.selected < len(s.disks) && s.disks[s.list.selected].Eligible
}

func (s *deviceScreen) next() {
	if !s.canContinue() {
		return
	}
	s.f.showInstallConfirmation(s.disks[s.list.selected])
}

func (s *deviceScreen) draw(f *Flow, w *win, area rect) {
	bar, body := w.actionBar(area)
	body = w.pageTitle(body, i18n.T("installer.device.heading"), i18n.T("installer.device.description"), color{}, "")
	if s.hidden > 0 {
		body.Top += w.banner(body.Left, body.Top, body.w(), i18n.N("installer.device.hidden", s.hidden), toneAccent) + w.px(14)
	}
	s.list.entries = s.entries()
	listW := body.w() * 56 / 100
	listR, detailsR := body.cutLeft(listW)
	detailsR.Left += w.px(16)
	eligible := 0
	for _, d := range s.disks {
		if d.Eligible {
			eligible++
		}
	}
	status, t := i18n.T("installer.device.found", len(s.disks), eligible), toneNeutral
	if s.loading {
		status = i18n.T("installer.device.searching")
	} else if s.err != nil {
		status, t = i18n.T("installer.common.scan_error", s.err.Error()), toneDanger
	}
	s.list.draw(w, listR, status, t, s.loading, i18n.T("installer.device.empty"), s.next)
	detailsR.Top += w.px(32)
	var selected *driveEntry
	if s.list.selected >= 0 && s.list.selected < len(s.list.entries) {
		selected = &s.list.entries[s.list.selected]
	}
	drawDetails(w, detailsR, selected, i18n.T("installer.device.pick_hint"))
	w.actions(bar,
		[]action{{"action.back", buttonSpec{label: i18n.T("installer.common.back"), glyph: glyphBack, onClick: f.showModes}}},
		[]action{{"action.next", buttonSpec{label: i18n.T("installer.common.next"), glyph: glyphChevronRight, trailing: true, style: buttonPrimary, disabled: !s.canContinue(), onClick: s.next}}},
	)
}

func (s *deviceScreen) key(f *Flow, w *win, vk uintptr) bool {
	if vk == vkEscape {
		f.showModes()
		return true
	}
	return false
}

// ---- update / repair / uninstall: only drives with a detected USOS -------

type installedScreen struct {
	f       *Flow
	op      operation
	loading bool
	err     error
	targets []installed.Target
	list    driveList
	gen     int
}

func newInstalledScreen(f *Flow, op operation) *installedScreen {
	s := &installedScreen{f: f, op: op}
	s.list.selected = -1
	s.refresh()
	return s
}

func (s *installedScreen) refreshing() bool { return s.loading }

func (s *installedScreen) refresh() {
	s.loading = true
	s.list.selected = -1
	s.gen++
	gen := s.gen
	source := s.f.cfg.Installed
	go func() {
		targets, err := source.ListInstalledUSOS()
		s.f.w.post(func() {
			if gen != s.gen {
				return
			}
			s.loading, s.err = false, err
			if err != nil {
				targets = nil
			}
			s.targets = targets
			s.list.selected = -1
		})
	}()
}

func (s *installedScreen) titles() (string, string) {
	switch s.op {
	case opUpdate:
		return i18n.T("installer.update.select_title"), i18n.T("installer.update.select_description")
	case opRepair:
		return i18n.T("installer.repair.select_title"), i18n.T("installer.repair.select_description")
	default:
		return i18n.T("installer.uninstall.select_title"), i18n.T("installer.uninstall.select_description")
	}
}

func (s *installedScreen) entries() []driveEntry {
	out := make([]driveEntry, len(s.targets))
	for i, t := range s.targets {
		row := domain.BuildDeviceRow(t.Disk)
		version := t.BuildInfo.Display()
		details := diskDetails(t.Disk, row)
		details = append(details,
			[2]string{i18n.T("installer.field.version"), version},
			[2]string{i18n.T("installer.field.state"), i18n.T("installer.installed.state")},
		)
		out[i] = driveEntry{
			title:      row.Model,
			meta:       joinMeta(busLabel(t.Disk), row.Capacity, row.Letters),
			badge:      i18n.T("installer.badge.usos"),
			badgeTone:  toneAccent,
			selectable: true,
			kind:       classifyDrive(t.Disk),
			details:    details,
			root:       row.RootContents,
		}
	}
	return out
}

func (s *installedScreen) canContinue() bool {
	return !s.loading && s.list.selected >= 0 && s.list.selected < len(s.targets)
}

func (s *installedScreen) next() {
	if !s.canContinue() {
		return
	}
	target := s.targets[s.list.selected]
	switch s.op {
	case opUpdate:
		s.f.showUpdateConfirmation(target)
	case opRepair:
		s.f.showRepairConfirmation(target)
	case opUninstall:
		s.f.showUninstallConfirmation(target)
	}
}

func (s *installedScreen) draw(f *Flow, w *win, area rect) {
	bar, body := w.actionBar(area)
	title, subtitle := s.titles()
	body = w.pageTitle(body, title, subtitle, color{}, "")
	s.list.entries = s.entries()
	listR, detailsR := body.cutLeft(body.w() * 56 / 100)
	detailsR.Left += w.px(16)
	status, t := installedFoundNote(len(s.targets)), toneNeutral
	if s.loading {
		status = i18n.T("installer.installed.searching")
	} else if s.err != nil {
		status, t = i18n.T("installer.common.scan_error", s.err.Error()), toneDanger
	}
	s.list.draw(w, listR, status, t, s.loading, i18n.T("installer.installed.empty"), s.next)
	detailsR.Top += w.px(32)
	var selected *driveEntry
	if s.list.selected >= 0 && s.list.selected < len(s.list.entries) {
		selected = &s.list.entries[s.list.selected]
	}
	drawDetails(w, detailsR, selected, i18n.T("installer.installed.pick_hint"))
	style := buttonPrimary
	if s.op == opUninstall {
		style = buttonDanger
	}
	w.actions(bar,
		[]action{{"action.back", buttonSpec{label: i18n.T("installer.common.back"), glyph: glyphBack, onClick: f.showModes}}},
		[]action{{"action.next", buttonSpec{label: i18n.T("installer.common.next"), glyph: glyphChevronRight, trailing: true, style: style, disabled: !s.canContinue(), onClick: s.next}}},
	)
}

func (s *installedScreen) key(f *Flow, w *win, vk uintptr) bool {
	if vk == vkEscape {
		f.showModes()
		return true
	}
	return false
}

func installedFoundNote(count int) string {
	if count <= 0 {
		return i18n.T("installer.installed.none")
	}
	return i18n.N("installer.installed.found", count)
}
