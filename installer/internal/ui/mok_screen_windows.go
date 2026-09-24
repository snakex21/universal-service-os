//go:build windows

package ui

import (
	"errors"

	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"github.com/snakex21/universal-service-os/installer/internal/mokenroll"
	"github.com/snakex21/universal-service-os/installer/internal/payload"
)

// mokScreen is the "Add the USOS key on this computer" guide
// (docs/secure-boot-usos.md). No password is involved:
//
//   - Way 1 (easiest): restart into the firmware settings, turn Secure Boot
//     off, start USOS once and confirm "Add the key" on its home screen
//     (USOS writes shim's MokList itself), turn Secure Boot back on.
//   - Way 2 (Secure Boot stays on): "Prepare" writes only MokTimeout = -1 so
//     MokManager waits on its menu instead of a 10 s countdown after
//     "Verification failed"; then Enroll key from disk -> USOS_ESP ->
//     USOS-KEY.cer -> Continue -> Yes -> Reboot, shown as drawn MokManager
//     screens.
//
// The MokNew + password request (mokutil --import) remains a command-line
// option only (-prepare-mok-enrollment -mok-password).
type mokScreen struct {
	f        *Flow
	back     func()
	fw       mokenroll.Firmware
	status   mokenroll.Status
	statusOK bool
	working  bool
	prepared bool
	result   string
	tone     tone
}

func newMokScreen(f *Flow, back func()) *mokScreen {
	s := &mokScreen{f: f, back: back, fw: f.mokFirmware()}
	if der, err := usosCertificate(); err == nil {
		// Read-only look at Secure Boot, MokListRT and MokTimeout.
		if st, err := mokenroll.Check(s.fw, der); err == nil {
			s.status, s.statusOK = st, true
			s.prepared = st.WaitPending
		}
	}
	return s
}

// usosCertificate is the DER certificate the release put on the drive
// (EFI\USOS\ENROLL_THIS_KEY_IN_MOKMANAGER.cer, also \USOS-KEY.cer) from the
// embedded payload.
func usosCertificate() ([]byte, error) {
	bundle, err := payload.Embedded()
	if err != nil {
		return nil, err
	}
	der, err := bundle.ReadFile(mokenroll.PayloadCertPath)
	if err != nil {
		return nil, err
	}
	return der, mokenroll.CheckCertificate(der)
}

func (s *mokScreen) prepare() {
	if s.working {
		return
	}
	s.working, s.result = true, ""
	s.f.busy = true
	go func() {
		text, t, ok := mokPrepareWait(s.fw)
		s.f.w.post(func() {
			s.working, s.f.busy = false, false
			s.result, s.tone = text, t
			if ok {
				s.prepared = true
			}
			s.f.refreshSecureBoot(nil)
			s.f.w.invalidate()
		})
	}()
}

// mokPrepareWait writes MokTimeout = -1 and returns the localized outcome.
func mokPrepareWait(fw mokenroll.Firmware) (string, tone, bool) {
	der, err := usosCertificate()
	if err != nil {
		return i18n.T("installer.mok.cert_missing", err.Error()), toneDanger, false
	}
	res, err := mokenroll.PrepareWait(fw, der)
	switch {
	case errors.Is(err, mokenroll.ErrNotUEFI):
		return i18n.T("installer.mok.not_uefi"), toneDanger, false
	case errors.Is(err, mokenroll.ErrPrivilege):
		return i18n.T("installer.mok.no_privilege"), toneDanger, false
	case err != nil:
		return i18n.T("installer.mok.failed", err.Error()), toneDanger, false
	case res.AlreadyEnrolled:
		return i18n.T("installer.mok.already"), toneSuccess, false
	}
	return i18n.T("installer.mok.prepared"), toneSuccess, true
}

func (s *mokScreen) restart(toFirmware bool) {
	run := s.f.cfg.Restart
	if toFirmware {
		run = s.f.cfg.RestartToFirmware
	}
	if run == nil {
		run = mokenroll.Restart
		if toFirmware {
			run = mokenroll.RestartToFirmware
		}
	}
	if err := run(); err != nil {
		s.result, s.tone = i18n.T("installer.mok.restart_failed", err.Error()), toneDanger
		s.f.w.invalidate()
	}
}

// statusNote is the line above the guide: what this computer needs.
func (s *mokScreen) statusNote() (string, tone) {
	switch {
	case s.working:
		return i18n.T("installer.mok.working"), toneNeutral
	case s.result != "":
		return s.result, s.tone
	case s.f.sb.ready && s.f.sb.assessment.Enrolled:
		return i18n.T("installer.mok.already"), toneSuccess
	case s.statusOK && s.status.Enrolled == mokenroll.Yes:
		return i18n.T("installer.mok.already"), toneSuccess
	case s.prepared:
		return i18n.T("installer.mok.pending"), toneAccent
	case s.statusOK && s.status.UEFI && s.status.SecureBoot == mokenroll.No:
		return i18n.T("installer.mok.secure_boot_off"), toneNeutral
	}
	return "", toneNeutral
}

func (s *mokScreen) draw(f *Flow, w *win, area rect) {
	bar, body := w.actionBar(area)
	body = w.pageTitle(body, i18n.T("installer.mok.button"), "", color{}, glyphShield)

	if note, t := s.statusNote(); note != "" {
		body.Top += w.banner(body.Left, body.Top, body.w(), note, t) + w.px(12)
	}

	// The guide scrolls when a long translation or a small window does not
	// fit.
	w.panel(body)
	view := body.inset(w.px(20), w.px(16))
	offset := w.beginScroll("mok.text", view)
	y := view.Top - offset
	width := view.w() - w.px(12)
	c := w.canvas
	y += w.wrapped(w.bodyFont(), i18n.T("installer.mok.intro"), view.Left, y, width, theme.Text) + w.px(16)

	y += s.section(w, view.Left, y, width, "1", i18n.T("installer.mok.way1_title"))
	y += w.wrapped(w.bodyFont(), i18n.T("installer.mok.way1_text"), view.Left+w.px(36), y, width-w.px(36), theme.Text) + w.px(20)

	y += s.section(w, view.Left, y, width, "2", i18n.T("installer.mok.way2_title"))
	y += w.wrapped(w.bodyFont(), i18n.T("installer.mok.way2_text"), view.Left+w.px(36), y, width-w.px(36), theme.Text) + w.px(12)
	y += drawMokSteps(w, view.Left+w.px(36), y, width-w.px(36)) + w.px(12)
	y += w.wrapped(w.semiFont(), i18n.T("installer.mok.tap_once"), view.Left+w.px(36), y, width-w.px(36), theme.Warning) + w.px(12)
	y += w.wrapped(w.captionFont(), i18n.T("installer.mok.scope"), view.Left, y, width, theme.Muted)
	_ = c
	w.endScroll("mok.text", view, y+offset-view.Top)

	enrolled := (f.sb.ready && f.sb.assessment.Enrolled) || (s.statusOK && s.status.Enrolled == mokenroll.Yes)
	firmware := buttonSpec{label: i18n.T("installer.mok.way1_button"), glyph: glyphRefresh, disabled: s.working, onClick: func() { s.restart(true) }}
	var primary buttonSpec
	if s.prepared {
		primary = buttonSpec{label: i18n.T("installer.mok.restart"), glyph: glyphRefresh, style: buttonPrimary, disabled: s.working, onClick: func() { s.restart(false) }}
	} else {
		primary = buttonSpec{label: i18n.T("installer.mok.prepare"), glyph: glyphShield, style: buttonPrimary, disabled: s.working || enrolled, onClick: s.prepare}
	}
	w.actions(bar,
		[]action{{"action.back", buttonSpec{label: i18n.T("installer.common.back"), glyph: glyphBack, disabled: s.working, onClick: s.back}}},
		[]action{{"action.firmware", firmware}, {"action.primary", primary}},
	)
}

// section draws a numbered heading and returns its height.
func (s *mokScreen) section(w *win, x, y, width int32, number, title string) int32 {
	c := w.canvas
	d := w.px(26)
	c.circle(float64(x)+float64(d)/2, float64(y)+float64(d)/2, float64(d)/2, theme.Accent)
	c.text(w.font(sizeBody, fwBold), number, rect{x, y, x + d, y + d}, theme.OnAccent, dtCenter|dtSingleLine|dtVCenter)
	h := max(d, w.canvas.measure(w.font(sizeH2+1, fwSemiBold), title, width-w.px(36)))
	c.text(w.font(sizeH2+1, fwSemiBold), title, rect{x + w.px(36), y, x + width, y + h}, theme.Text, dtLeft|dtWordBreak|dtEditControl)
	return h + w.px(8)
}

// mokStep is one drawn MokManager screen: its title, menu items, the item
// to pick and the localized caption below it.
type mokStep struct {
	title    string
	items    []string
	selected int
	caption  string
}

func mokSteps() []mokStep {
	return []mokStep{
		{"ERROR", []string{"Verification failed", "OK"}, 1, i18n.T("installer.mok.step_verify")},
		{"Perform MOK management", []string{"Continue boot", "Enroll key from disk", "Enroll hash from disk"}, 1, i18n.T("installer.mok.step_enroll")},
		{"Select Key", []string{"USOS_ESP", "..."}, 0, i18n.T("installer.mok.step_volume")},
		{"USOS_ESP", []string{"EFI/", "USOS-KEY.cer"}, 1, i18n.T("installer.mok.step_file")},
		{"[Enroll MOK]", []string{"View key 0", "Continue"}, 1, i18n.T("installer.mok.step_continue")},
		{"Enroll the key(s)?", []string{"No", "Yes"}, 1, i18n.T("installer.mok.step_yes")},
		{"Perform MOK management", []string{"Reboot", "Enroll key from disk"}, 0, i18n.T("installer.mok.step_reboot")},
	}
}

// MokManager's console colours (shim 16.1 in QEMU/OVMF: EFI blue
// background, light grey text, black selection bar).
var (
	mokBlue = color{0x00, 0x00, 0xa8}
	mokGrey = color{0xaa, 0xaa, 0xaa}
	mokText = color{0xd8, 0xd8, 0xd8}
)

// drawMokSteps lays the drawn MokManager screens out in rows (numbered,
// arrow between them) and returns the height used.
func drawMokSteps(w *win, x, y, width int32) int32 {
	c := w.canvas
	steps := mokSteps()
	tileW, tileH := w.px(168), w.px(104)
	gap := w.px(14)
	columns := max(1, (width+gap)/(tileW+gap))
	captionFont := w.captionFont()
	captionH := int32(0)
	for _, st := range steps {
		captionH = max(captionH, c.measure(captionFont, st.caption, tileW))
	}
	rowH := tileH + w.px(8) + captionH + w.px(14)
	mono := w.mono(9)
	for i, st := range steps {
		col, row := int32(i)%columns, int32(i)/columns
		tx := x + col*(tileW+gap)
		ty := y + row*rowH
		r := rect{tx, ty, tx + tileW, ty + tileH}
		c.roundRect(r, w.px(6), mokBlue)
		// Thin frame like the MokManager screen border.
		frame := r.inset(w.px(4), w.px(4))
		c.roundBorder(frame, w.px(2), max(1, w.px(1)), mokGrey)
		c.text(mono, st.title, rect{frame.Left, frame.Top + w.px(3), frame.Right, frame.Top + w.px(17)}, mokText, dtCenter|dtSingleLine|dtVCenter|dtEndEllipsis)
		lineH := w.px(15)
		boxH := int32(len(st.items))*lineH + w.px(8)
		box := rect{frame.Left + w.px(10), frame.Top + w.px(22) + (frame.h()-w.px(22)-boxH)/2, frame.Right - w.px(10), 0}
		box.Bottom = box.Top + boxH
		c.roundBorder(box, 0, max(1, w.px(1)), mokGrey)
		for j, item := range st.items {
			line := rect{box.Left + w.px(2), box.Top + w.px(4) + int32(j)*lineH, box.Right - w.px(2), box.Top + w.px(4) + int32(j+1)*lineH}
			col := mokText
			if j == st.selected {
				c.fill(line, color{0, 0, 0})
				col = color{0xff, 0xff, 0xff}
			}
			c.text(mono, item, line, col, dtCenter|dtSingleLine|dtVCenter|dtEndEllipsis)
		}
		// Step number badge.
		d := w.px(22)
		c.circle(float64(r.Left)+float64(d)/2-float64(w.px(4)), float64(r.Top)+float64(d)/2-float64(w.px(4)), float64(d)/2, theme.Accent)
		c.text(w.font(sizeCaption, fwBold), itoa(uint32(i+1)), rect{r.Left - w.px(4), r.Top - w.px(4), r.Left - w.px(4) + d, r.Top - w.px(4) + d}, theme.OnAccent, dtCenter|dtSingleLine|dtVCenter)
		c.text(captionFont, st.caption, rect{tx, r.Bottom + w.px(8), tx + tileW, r.Bottom + w.px(8) + captionH}, theme.Text, dtCenter|dtWordBreak|dtEditControl)
	}
	rows := (int32(len(steps)) + columns - 1) / columns
	return rows*rowH - w.px(14)
}

func (s *mokScreen) key(f *Flow, w *win, vk uintptr) bool {
	if vk == vkEscape && !s.working {
		s.back()
		return true
	}
	return false
}
