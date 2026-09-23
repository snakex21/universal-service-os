//go:build windows

package ui

import (
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/buildinfo"
	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
)

// modeScreen is the home screen: four operation cards and the result of the
// installed-USOS detection.
type modeScreen struct {
	f        *Flow
	checking bool
	targets  []installed.Target
	err      error
	gen      int
}

func newModeScreen(f *Flow) *modeScreen {
	s := &modeScreen{f: f}
	s.refresh()
	return s
}

func (s *modeScreen) refreshing() bool { return s.checking }

func (s *modeScreen) refresh() {
	source := s.f.cfg.Installed
	if source == nil {
		return
	}
	s.checking = true
	s.gen++
	gen := s.gen
	go func() {
		targets, err := source.ListInstalledUSOS()
		s.f.w.post(func() {
			if gen != s.gen {
				return
			}
			s.checking, s.targets, s.err = false, targets, err
		})
	}()
}

func (s *modeScreen) status() (string, tone) {
	switch {
	case s.f.cfg.Installed == nil:
		return i18n.T("installer.mode.no_source"), toneNeutral
	case s.checking:
		return i18n.T("installer.mode.checking"), toneNeutral
	case s.err != nil:
		return i18n.T("installer.mode.check_failed", s.err.Error()), toneDanger
	case len(s.targets) == 0:
		return i18n.T("installer.mode.none_detected"), toneNeutral
	}
	names := make([]string, 0, len(s.targets))
	for _, t := range s.targets {
		names = append(names, t.Disk.DisplayName())
	}
	return i18n.T("installer.mode.detected", strings.Join(names, ", ")) + i18n.N("installer.mode.detected_hidden", len(s.targets)), toneAccent
}

type chip struct {
	text string
	tone tone
}

type modeCard struct {
	id, glyph, title, summary string
	danger                    bool
	onClick                   func()
	chips                     []chip
}

func (s *modeScreen) cards() []modeCard {
	f := s.f
	erases := chip{i18n.T("installer.chip.erases"), toneDanger}
	keeps := chip{i18n.T("installer.chip.keeps_data"), toneSuccess}
	return []modeCard{
		{"mode.install", glyphDownload, i18n.T("installer.mode.install.title"), i18n.T("installer.mode.install.summary"), false, f.showInstallDevices,
			[]chip{erases, {i18n.T("installer.chip.layout"), toneNeutral}}},
		{"mode.update", glyphSync, i18n.T("installer.mode.update.title"), i18n.T("installer.mode.update.summary"), false, func() { f.showInstalledDevices(opUpdate) },
			[]chip{keeps, {i18n.T("installer.chip.no_format"), toneNeutral}}},
		{"mode.repair", glyphRepair, i18n.T("installer.mode.repair.title"), i18n.T("installer.mode.repair.summary"), false, func() { f.showInstalledDevices(opRepair) },
			[]chip{keeps, {i18n.T("installer.chip.esp_only"), toneNeutral}}},
		{"mode.uninstall", glyphDelete, i18n.T("installer.mode.uninstall.title"), i18n.T("installer.mode.uninstall.summary"), true, func() { f.showInstalledDevices(opUninstall) },
			[]chip{erases, {i18n.T("installer.chip.exfat"), toneNeutral}}},
	}
}

func (s *modeScreen) draw(f *Flow, w *win, area rect) {
	c := w.canvas
	y := area.Top
	title := i18n.T("installer.mode.title")
	c.text(w.font(sizeTitle, fwSemiBold), title, rect{area.Left, y, area.Right, y + w.px(32)}, theme.Text, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
	y += w.px(34)
	y += w.wrapped(w.bodyFont(), i18n.T("installer.mode.subtitle"), area.Left, y, area.w(), theme.Muted)
	y += w.px(16)
	text, t := s.status()
	if s.checking {
		h := w.bannerHeight(area.w(), text)
		fg, bg := toneColors(toneNeutral)
		r := rect{area.Left, y, area.Right, y + h}
		c.roundRect(r, w.px(8), bg)
		w.spinner(r.Left+w.px(26), r.Top+h/2, w.px(8), theme.Accent)
		c.text(w.bodyFont(), text, rect{r.Left + w.px(48), r.Top, r.Right - w.px(16), r.Bottom}, fg.mix(theme.Text, 0.6), dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
		y += h
	} else {
		y += w.banner(area.Left, y, area.w(), text, t)
	}
	y += w.px(18)

	footerH := w.px(20)
	grid := rect{area.Left, y, area.Right, area.Bottom - footerH - w.px(12)}
	cards := s.cards()
	g := w.px(16)
	cellW := (grid.w() - g) / 2
	cellH := min(w.px(140), (grid.h()-g)/2)
	cellH = max(cellH, w.px(96))
	for i, card := range cards {
		col, row := int32(i%2), int32(i/2)
		r := rect{grid.Left + col*(cellW+g), grid.Top + row*(cellH+g), 0, 0}
		r.Right, r.Bottom = r.Left+cellW, r.Top+cellH
		s.drawCard(w, r, card)
	}
	build := buildinfo.Current()
	c.text(w.captionFont(), i18n.T("installer.mode.build", build.Display()), rect{area.Left, area.Bottom - footerH, area.Right, area.Bottom}, theme.Faint, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
	c.text(w.captionFont(), i18n.T("installer.mode.keys_hint"), rect{area.Left, area.Bottom - footerH, area.Right, area.Bottom}, theme.Faint, dtRight|dtSingleLine|dtVCenter|dtEndEllipsis)
}

func (s *modeScreen) drawCard(w *win, r rect, card modeCard) {
	c := w.canvas
	st := w.add(widget{id: card.id, r: r, focusable: true, onClick: card.onClick})
	accent, soft := theme.Accent, theme.AccentSoft
	if card.danger {
		accent, soft = theme.Danger, theme.DangerSoft
	}
	bg, border := theme.Panel, theme.Border
	if st.hot {
		bg, border = theme.PanelAlt, accent.mix(theme.Border, 0.35)
	}
	if st.pressed {
		bg = theme.Panel.mix(accent, 0.08)
	}
	radius := w.px(radiusCard)
	c.roundRect(r, radius, bg)
	c.roundBorder(r, radius, max(1, w.px(1)), border)
	if st.ring {
		w.focusRing(r, radius)
	}
	inner := r.inset(w.px(20), w.px(18))
	tile := w.px(48)
	tileR := rect{inner.Left, inner.Top, inner.Left + tile, inner.Top + tile}
	c.roundRect(tileR, w.px(12), soft)
	w.glyph(card.glyph, tileR, 22, accent)
	textX := tileR.Right + w.px(16)
	textW := inner.Right - textX - w.px(28)
	titleCol := theme.Text
	if card.danger {
		titleCol = theme.Danger.mix(theme.Text, 0.25)
	}
	c.text(w.font(sizeH2+1, fwSemiBold), card.title, rect{textX, inner.Top, textX + textW, inner.Top + w.px(26)}, titleCol, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
	summaryH := min(c.measure(w.bodyFont(), card.summary, textW), inner.Bottom-inner.Top-w.px(30))
	c.text(w.bodyFont(), card.summary, rect{textX, inner.Top + w.px(30), textX + textW, inner.Top + w.px(30) + summaryH}, theme.Muted, dtLeft|dtWordBreak|dtEditControl|dtEndEllipsis)
	// Effect chips along the bottom edge.
	cx := textX
	cy := inner.Bottom - w.px(11)
	if cy-w.px(11) <= inner.Top+w.px(30)+summaryH && textOverflowHook != nil && len(card.chips) > 0 {
		textOverflowHook("chips hidden under: "+card.summary, inner.Top+w.px(30)+summaryH, cy-w.px(11), true)
	}
	if cy-w.px(11) > inner.Top+w.px(30)+summaryH {
		for _, ch := range card.chips {
			bw := w.badgeWidth(ch.text)
			if cx+bw > inner.Right {
				if textOverflowHook != nil {
					textOverflowHook("chip: "+ch.text, cx+bw-textX, inner.Right-textX, false)
				}
				break
			}
			w.badge(ch.text, cx+bw, cy, ch.tone)
			cx += bw + w.px(8)
		}
	}
	chev := glyphChevronRight
	chevCol := theme.Faint
	if st.hot {
		chevCol = accent
	}
	w.glyph(chev, rect{inner.Right - w.px(20), inner.Top, inner.Right, inner.Top + tile}, 14, chevCol)
}

func (s *modeScreen) key(f *Flow, w *win, vk uintptr) bool {
	// Arrow keys move through the 2x2 grid.
	order := []string{"mode.install", "mode.update", "mode.repair", "mode.uninstall"}
	idx := -1
	for i, id := range order {
		if id == w.focus {
			idx = i
		}
	}
	if idx < 0 {
		return false
	}
	next := idx
	switch vk {
	case vkLeft:
		if idx%2 == 1 {
			next = idx - 1
		}
	case vkRight:
		if idx%2 == 0 {
			next = idx + 1
		}
	case vkUp:
		if idx >= 2 {
			next = idx - 2
		}
	case vkDown:
		if idx < 2 {
			next = idx + 2
		}
	default:
		return false
	}
	w.setFocusID(order[next])
	return true
}
