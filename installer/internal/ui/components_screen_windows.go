//go:build windows

package ui

import (
	"context"
	"fmt"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/components"
	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
)

// ComponentsBackend reads and installs the optional components on a USOS
// drive (winhost.Backend). The download itself happens in the UI's runner.
type ComponentsBackend interface {
	ComponentStatus(install.MediaLayout) (components.Status, error)
	InstallComponent(media install.MediaLayout, id components.ID, zipPath string, storeOnly bool, log func(string)) error
}

// componentsInstaller binds the backend to one drive for components.Runner.
type componentsInstaller struct {
	backend ComponentsBackend
	media   install.MediaLayout
}

func (c componentsInstaller) InstallComponent(id components.ID, zipPath string, storeOnly bool, log func(string)) error {
	return c.backend.InstallComponent(c.media, id, zipPath, storeOnly, log)
}

// finalArgs is the finished operation the components step comes after; the
// final screen shows it afterwards.
type finalArgs struct {
	op     operation
	report *install.VerificationReport
	err    error
	log    string
}

type xpLanguage int

const (
	xpPreferred xpLanguage = iota // the installer language (PL for Polish, else EN)
	xpPolish
	xpEnglish
	xpBoth
)

// componentsScreen is the "Components" step after install, update and
// repair: the WinPE donor and the XP package, downloaded from this
// installer's release (default), picked from a local zip, or skipped.
type componentsScreen struct {
	f       *Flow
	after   finalArgs
	release components.Release
	// forced: opened from the final screen (show even when complete).
	forced bool

	checking  bool
	checkErr  error
	target    installed.Target
	hasTarget bool
	status    components.Status

	winpeSource components.Source
	xpSource    components.Source
	xpLang      xpLanguage
	local       map[components.ID]string

	running bool
	ran     bool
	cancel  context.CancelFunc
	phase   map[components.ID]components.Phase
	prog    map[components.ID]components.Progress
	errs    map[components.ID]error
	last    []components.Choice
	logText strings.Builder
	cardH   map[string]int32
}

func (f *Flow) showComponents(after finalArgs, forced bool) {
	s := &componentsScreen{f: f, after: after, forced: forced, release: f.componentsRelease(), checking: true,
		local: map[components.ID]string{}, phase: map[components.ID]components.Phase{},
		prog: map[components.ID]components.Progress{}, errs: map[components.ID]error{}}
	if !s.release.CanDownload() {
		s.winpeSource, s.xpSource = components.SourceLocal, components.SourceLocal
	}
	f.busy = false
	f.show(s, "components.primary")
	s.check()
}

func (f *Flow) componentsRelease() components.Release {
	if f.cfg.ComponentsRelease != nil {
		return *f.cfg.ComponentsRelease
	}
	return components.CurrentRelease()
}

// check finds the drive again (install assigns new volumes) and reads its
// component state in the background.
func (s *componentsScreen) check() {
	f := s.f
	disk := f.compDisk
	go func() {
		var target installed.Target
		found := false
		targets, err := f.cfg.Installed.ListInstalledUSOS()
		if err == nil {
			for _, t := range targets {
				if t.Disk.Number == disk {
					target, found = t, true
				}
			}
			if !found {
				err = fmt.Errorf("USOS drive %d not found", disk)
			}
		}
		var status components.Status
		if err == nil {
			status, err = f.cfg.Components.ComponentStatus(target.Media)
		}
		f.w.post(func() {
			if f.screen != s {
				return
			}
			s.checking, s.checkErr, s.target, s.hasTarget, s.status = false, err, target, found, status
			f.compMissing = err != nil || !status.Complete()
			if err == nil && status.Complete() && !s.forced {
				s.finish()
			}
			f.w.invalidate()
		})
	}()
}

func (s *componentsScreen) log(line string) {
	if s.f.cfg.ComponentsLog != nil {
		s.f.cfg.ComponentsLog(line)
	}
	s.logText.WriteString(line + "\n")
}

// finish goes on to the operation's final screen.
func (s *componentsScreen) finish() {
	log := s.after.log
	if s.logText.Len() > 0 {
		log = strings.TrimRight(log, "\n") + "\n" + strings.TrimRight(s.logText.String(), "\n")
	}
	s.f.showFinalScreen(finalArgs{op: s.after.op, report: s.after.report, err: s.after.err, log: log})
}

func (s *componentsScreen) xpIDs() []components.ID {
	preferred := components.PreferredXP(i18n.Current())
	switch s.xpLang {
	case xpPolish:
		return []components.ID{components.XPPL}
	case xpEnglish:
		return []components.ID{components.XPEN}
	case xpBoth:
		other := components.XPEN
		if preferred == components.XPEN {
			other = components.XPPL
		}
		return []components.ID{preferred, other}
	}
	return []components.ID{preferred}
}

// choices is what Install runs: only missing components.
func (s *componentsScreen) choices() []components.Choice {
	var result []components.Choice
	if !s.status.WinPE {
		result = append(result, components.Choice{ID: components.WinPE, Source: s.winpeSource, LocalPath: s.local[components.WinPE]})
	}
	if !s.status.XPOK() {
		for i, id := range s.xpIDs() {
			result = append(result, components.Choice{ID: id, Source: s.xpSource, LocalPath: s.local[id], StoreOnly: i > 0})
		}
	}
	return result
}

func (s *componentsScreen) start(choices []components.Choice) {
	for _, c := range choices {
		if c.Source == components.SourceLocal && c.LocalPath == "" {
			s.f.showToast(i18n.T("installer.components.local_missing"))
			return
		}
	}
	f := s.f
	s.running, s.last = true, choices
	f.busy = true
	for _, c := range choices {
		s.phase[c.ID], s.errs[c.ID] = components.PhaseWaiting, nil
		delete(s.prog, c.ID)
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	runner := &components.Runner{
		Release:    s.release,
		Downloader: &components.Downloader{Release: s.release, Dir: components.DefaultDir(s.release), Log: func(l string) { f.w.post(func() { s.log(l) }) }},
		Installer:  componentsInstaller{backend: f.cfg.Components, media: s.target.Media},
		Log:        func(l string) { f.w.post(func() { s.log(l) }) },
	}
	s.log(fmt.Sprintf("[COMPONENTS] release %s, download folder %s", s.release.Tag, components.DefaultDir(s.release)))
	go func() {
		results := runner.Run(ctx, choices, func(e components.Event) {
			f.w.post(func() {
				s.phase[e.ID] = e.Phase
				if e.Phase == components.PhaseDownload && e.Progress.Asset != "" {
					s.prog[e.ID] = e.Progress
				}
				if e.Err != nil {
					s.errs[e.ID] = e.Err
				}
				f.w.invalidate()
			})
		})
		cancel()
		f.w.post(func() {
			for id, err := range results {
				s.errs[id] = err
			}
			s.running, s.ran, f.busy = false, true, false
			s.recheck()
		})
	}()
}

// recheck reads the drive again after a run.
func (s *componentsScreen) recheck() {
	f := s.f
	go func() {
		status, err := f.cfg.Components.ComponentStatus(s.target.Media)
		f.w.post(func() {
			if err == nil {
				s.status = status
				f.compMissing = !status.Complete()
			}
			f.w.invalidate()
		})
	}()
}

func (s *componentsScreen) failed() []components.Choice {
	var result []components.Choice
	for _, c := range s.last {
		if s.errs[c.ID] != nil {
			result = append(result, c)
		}
	}
	return result
}

func (s *componentsScreen) pick(id components.ID) {
	title := i18n.T("installer.components.pick_title", s.release.Asset(id))
	if path, ok := pickZipFile(s.f.w.hwnd, title, i18n.T("installer.components.pick_filter")); ok {
		s.local[id] = path
	}
	s.f.w.invalidate()
}

// ---- drawing -----------------------------------------------------------------

func (s *componentsScreen) draw(f *Flow, w *win, area rect) {
	bar, body := w.actionBar(area)
	subtitle := i18n.T("installer.components.subtitle", s.release.Tag)
	if !s.release.CanDownload() {
		subtitle = i18n.T("installer.components.no_release")
	}
	body = w.pageTitle(body, i18n.T("installer.components.title"), subtitle, color{}, glyphDownload)
	y := body.Top
	switch {
	case s.checking:
		text := i18n.T("installer.components.checking")
		h := w.bannerHeight(body.w(), text)
		fg, bg := toneColors(toneNeutral)
		r := rect{body.Left, y, body.Right, y + h}
		w.canvas.roundRect(r, w.px(8), bg)
		w.spinner(r.Left+w.px(26), r.Top+h/2, w.px(8), theme.Accent)
		w.canvas.text(w.bodyFont(), text, rect{r.Left + w.px(48), r.Top, r.Right - w.px(16), r.Bottom}, fg.mix(theme.Text, 0.6), dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
	case s.checkErr != nil:
		w.banner(body.Left, y, body.w(), i18n.T("installer.components.check_failed", s.checkErr.Error()), toneDanger)
	default:
		offset := w.beginScroll("components", body)
		y = body.Top - offset
		y += s.drawWinPE(w, rect{body.Left, y, body.Right - w.px(12), 0}) + w.px(14)
		y += s.drawXP(w, rect{body.Left, y, body.Right - w.px(12), 0}) + w.px(14)
		w.endScroll("components", body, y+offset-body.Top)
	}
	s.drawActions(w, bar)
}

func (s *componentsScreen) drawActions(w *win, bar rect) {
	var left, right []action
	switch {
	case s.running:
		right = append(right, action{"components.cancel", buttonSpec{label: i18n.T("installer.components.cancel"), glyph: glyphCancel, onClick: func() {
			if s.cancel != nil {
				s.cancel()
			}
		}}})
	case s.checking || s.checkErr != nil:
		right = append(right, action{"components.primary", buttonSpec{label: i18n.T("installer.components.continue"), style: buttonPrimary, disabled: s.checking, onClick: s.finish}})
	case s.ran && len(s.failed()) > 0:
		right = append(right,
			action{"components.skip", buttonSpec{label: i18n.T("installer.components.continue"), onClick: s.finish}},
			action{"components.primary", buttonSpec{label: i18n.T("installer.components.retry"), glyph: glyphRefresh, style: buttonPrimary, onClick: func() { s.start(s.failed()) }}})
	case s.status.Complete() || s.ran:
		right = append(right, action{"components.primary", buttonSpec{label: i18n.T("installer.components.continue"), style: buttonPrimary, onClick: s.finish}})
	default:
		choices := s.choices()
		work := false
		for _, c := range choices {
			if c.Source != components.SourceSkip {
				work = true
			}
		}
		left = append(left, action{"components.skip", buttonSpec{label: i18n.T("installer.components.skip_all"), onClick: s.finish}})
		label := i18n.T("installer.components.install")
		if !work {
			label = i18n.T("installer.components.continue")
		}
		right = append(right, action{"components.primary", buttonSpec{label: label, glyph: glyphDownload, style: buttonPrimary, onClick: func() {
			if !work {
				s.finish()
				return
			}
			s.start(choices)
		}}})
	}
	w.actions(bar, left, right)
}

// componentCard draws the frame, title, need text and status badge of one
// component and returns the inner rect below the header and its y.
func (s *componentsScreen) cardHeader(w *win, r rect, glyph, title, need, badge string, badgeTone tone) (rect, int32) {
	c := w.canvas
	inner := rect{r.Left + w.px(20), r.Top + w.px(16), r.Right - w.px(20), r.Bottom}
	tile := rect{inner.Left, inner.Top, inner.Left + w.px(36), inner.Top + w.px(36)}
	c.roundRect(tile, w.px(8), theme.AccentSoft)
	w.glyph(glyph, tile, 16, theme.Accent)
	x := tile.Right + w.px(14)
	badgeW := w.badgeWidth(badge)
	c.text(w.font(sizeH2, fwSemiBold), title, rect{x, inner.Top, inner.Right - badgeW - w.px(12), inner.Top + w.px(22)}, theme.Text, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
	w.badge(badge, inner.Right, inner.Top+w.px(11), badgeTone)
	y := inner.Top + w.px(24)
	y += w.wrapped(w.bodyFont(), need, x, y, inner.Right-x, theme.Muted)
	return rect{x, inner.Top, inner.Right, inner.Bottom}, max(y, tile.Bottom) + w.px(12)
}

type segment struct {
	id, label string
	selected  bool
	onClick   func()
}

// segments draws a row of toggle buttons (the selected one filled) and
// returns the row height.
func (s *componentsScreen) segments(w *win, x, y, right int32, items []segment, disabled bool) int32 {
	h := w.px(32)
	rowY, left := y, x
	for _, it := range items {
		style := buttonSecondary
		if it.selected {
			style = buttonPrimary
		}
		spec := buttonSpec{label: it.label, style: style, disabled: disabled, onClick: it.onClick}
		width := min(w.buttonWidth(spec), right-left)
		if x+width > right && x > left {
			// Long translations wrap onto the next line.
			rowY += h + w.px(8)
			x = left
		}
		w.button(it.id, rect{x, rowY, x + width, rowY + h}, spec)
		x += width + w.px(8)
	}
	return rowY - y + h
}

func (s *componentsScreen) sourceSegments(w *win, prefix string, x, y, right int32, source *components.Source, disabled bool) int32 {
	var items []segment
	if s.release.CanDownload() {
		items = append(items, segment{prefix + ".download", i18n.T("installer.components.source.download"), *source == components.SourceDownload, func() { *source = components.SourceDownload }})
	}
	items = append(items,
		segment{prefix + ".local", i18n.T("installer.components.source.local"), *source == components.SourceLocal, func() { *source = components.SourceLocal }},
		segment{prefix + ".skip", i18n.T("installer.components.source.skip"), *source == components.SourceSkip, func() { *source = components.SourceSkip }})
	return s.segments(w, x, y, right, items, disabled)
}

// localRow: "Choose file" button and the chosen path.
func (s *componentsScreen) localRow(w *win, id components.ID, x, y, right int32, label string) int32 {
	spec := buttonSpec{label: label, glyph: glyphFolder, disabled: s.running, onClick: func() { s.pick(id) }}
	width := w.buttonWidth(spec)
	h := w.px(32)
	w.button("components.pick."+string(id), rect{x, y, x + width, y + h}, spec)
	path := s.local[id]
	text, col := i18n.T("installer.components.no_file"), theme.Faint
	if path != "" {
		text, col = path, theme.Text
	}
	const dtPathEllipsis = 0x4000
	w.canvas.text(w.captionFont(), text, rect{x + width + w.px(12), y, right, y + h}, col, dtLeft|dtSingleLine|dtVCenter|dtPathEllipsis)
	return h
}

// progressLine: phase text (and a bar while downloading) for one component.
func (s *componentsScreen) progressLine(w *win, id components.ID, x, y, right int32) int32 {
	phase, ok := s.phase[id]
	if !ok {
		return 0
	}
	c := w.canvas
	text, col := "", theme.Muted
	switch phase {
	case components.PhaseWaiting:
		text = i18n.T("installer.components.phase.waiting")
	case components.PhaseChecksums:
		text = i18n.T("installer.components.phase.checksums")
	case components.PhaseDownload:
		p := s.prog[id]
		total := "?"
		if p.Total > 0 {
			total = fmt.Sprintf("%.1f", float64(p.Total)/1e6)
		}
		text = i18n.T("installer.components.phase.download", fmt.Sprintf("%.1f", float64(p.Done)/1e6), total, fmt.Sprintf("%.1f", p.BytesPerSec/1e6))
	case components.PhaseVerify:
		text = i18n.T("installer.components.phase.verify")
	case components.PhaseInstall:
		text = i18n.T("installer.components.phase.install")
	case components.PhaseDone:
		text, col = i18n.T("installer.components.phase.done"), theme.Success
		for _, c := range s.last {
			if c.ID == id && c.StoreOnly {
				text = i18n.T("installer.components.phase.stored")
			}
		}
	case components.PhaseSkipped:
		text = i18n.T("installer.components.phase.skipped")
	case components.PhaseFailed:
		text, col = i18n.T("installer.components.phase.failed", fmt.Sprint(s.errs[id])), theme.Danger.mix(theme.Text, 0.3)
	}
	label := strings.ToUpper(string(id))
	if id == components.WinPE {
		label = "WinPE"
	}
	text = label + ": " + text
	h := c.measure(w.captionFont(), text, right-x)
	c.text(w.captionFont(), text, rect{x, y, right, y + h}, col, dtLeft|dtWordBreak|dtEditControl)
	y += h + w.px(6)
	if phase == components.PhaseDownload {
		p := s.prog[id]
		fraction := 0.0
		if p.Total > 0 {
			fraction = float64(p.Done) / float64(p.Total)
		}
		w.progressBar(rect{x, y, right, y + w.px(6)}, fraction, theme.Accent)
		w.animate = true
		return h + w.px(6) + w.px(12)
	}
	if phase == components.PhaseChecksums || phase == components.PhaseVerify || phase == components.PhaseInstall {
		w.animate = true
	}
	return h + w.px(6)
}

// card draws a panel sized by the content's height from the previous frame
// (immediate-mode UI: the height is only known after drawing) and repaints
// once more when it changed.
func (s *componentsScreen) card(w *win, id string, r rect, content func(*win, rect) int32) int32 {
	if s.cardH == nil {
		s.cardH = map[string]int32{}
	}
	height := s.cardH[id]
	if height == 0 {
		height = w.px(120)
	}
	w.panel(rect{r.Left, r.Top, r.Right, r.Top + height})
	actual := content(w, r)
	if actual != height {
		s.cardH[id] = actual
		w.invalidate()
	}
	return actual
}

func (s *componentsScreen) drawWinPE(w *win, r rect) int32 {
	return s.card(w, "winpe", r, s.winpeContent)
}

func (s *componentsScreen) winpeContent(w *win, r rect) int32 {
	badge, t := i18n.T("installer.components.status.missing"), toneWarning
	if s.status.WinPE {
		badge, t = i18n.T("installer.components.status.installed"), toneSuccess
	}
	inner, y := s.cardHeader(w, r, glyphDrive, i18n.T("installer.components.winpe.name"), i18n.T("installer.components.winpe.need"), badge, t)
	if s.status.WinPE {
		y += w.wrapped(w.captionFont(), s.status.WinPEName, inner.Left, y, inner.w(), theme.Faint) + w.px(4)
		y += s.progressLine(w, components.WinPE, inner.Left, y, inner.Right)
		return y - r.Top + w.px(8)
	}
	y += s.sourceSegments(w, "components.winpe", inner.Left, y, inner.Right, &s.winpeSource, s.running) + w.px(10)
	switch s.winpeSource {
	case components.SourceLocal:
		y += s.localRow(w, components.WinPE, inner.Left, y, inner.Right, i18n.T("installer.components.choose_file")) + w.px(10)
	case components.SourceSkip:
		y += w.wrapped(w.captionFont(), i18n.T("installer.components.winpe.skip_note"), inner.Left, y, inner.w(), theme.Warning) + w.px(10)
	}
	y += s.progressLine(w, components.WinPE, inner.Left, y, inner.Right)
	return y - r.Top + w.px(8)
}

func (s *componentsScreen) drawXP(w *win, r rect) int32 {
	return s.card(w, "xp", r, s.xpContent)
}

func (s *componentsScreen) xpContent(w *win, r rect) int32 {
	badge, t := i18n.T("installer.components.status.missing"), toneWarning
	switch {
	case s.status.XPOK():
		badge, t = i18n.T("installer.components.status.installed_lang", strings.ToUpper(s.status.XPLang)), toneSuccess
	case s.status.XPLang != "":
		badge = i18n.T("installer.components.status.outdated")
	}
	inner, y := s.cardHeader(w, r, glyphDownload, i18n.T("installer.components.xp.name"), i18n.T("installer.components.xp.need"), badge, t)
	if s.status.XPOK() {
		for _, id := range []components.ID{components.XPPL, components.XPEN} {
			y += s.progressLine(w, id, inner.Left, y, inner.Right)
		}
		return y - r.Top + w.px(8)
	}
	preferred := components.PreferredXP(i18n.Current())
	langs := []segment{
		{"components.xp.pl", i18n.T("installer.components.lang.pl"), s.xpLang == xpPolish || (s.xpLang == xpPreferred && preferred == components.XPPL), func() { s.xpLang = xpPolish }},
		{"components.xp.en", i18n.T("installer.components.lang.en"), s.xpLang == xpEnglish || (s.xpLang == xpPreferred && preferred == components.XPEN), func() { s.xpLang = xpEnglish }},
		{"components.xp.both", i18n.T("installer.components.lang.both"), s.xpLang == xpBoth, func() { s.xpLang = xpBoth }},
	}
	y += s.segments(w, inner.Left, y, inner.Right, langs, s.running) + w.px(8)
	if s.xpLang == xpBoth {
		y += w.wrapped(w.captionFont(), i18n.T("installer.components.xp.both_note", strings.ToUpper(preferred.XPLang())), inner.Left, y, inner.w(), theme.Muted) + w.px(8)
	}
	y += s.sourceSegments(w, "components.xp", inner.Left, y, inner.Right, &s.xpSource, s.running) + w.px(10)
	switch s.xpSource {
	case components.SourceLocal:
		for _, id := range s.xpIDs() {
			y += s.localRow(w, id, inner.Left, y, inner.Right, i18n.T("installer.components.choose_xp_file", strings.ToUpper(id.XPLang()))) + w.px(8)
		}
	case components.SourceSkip:
		y += w.wrapped(w.captionFont(), i18n.T("installer.components.xp.skip_note"), inner.Left, y, inner.w(), theme.Warning) + w.px(10)
	}
	for _, id := range []components.ID{components.XPPL, components.XPEN} {
		y += s.progressLine(w, id, inner.Left, y, inner.Right)
	}
	return y - r.Top + w.px(8)
}

func (s *componentsScreen) key(f *Flow, w *win, vk uintptr) bool {
	if vk == vkEscape && s.running && s.cancel != nil {
		s.cancel()
		return true
	}
	return false
}
