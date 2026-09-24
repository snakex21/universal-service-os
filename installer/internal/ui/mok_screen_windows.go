//go:build windows

package ui

import (
	"errors"

	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"github.com/snakex21/universal-service-os/installer/internal/mokenroll"
	"github.com/snakex21/universal-service-os/installer/internal/payload"
)

// mokScreen prepares a MokManager enrollment of the USOS Secure Boot key on
// this computer (the Windows-side "mokutil --import"): it writes MokNew and
// MokAuth, so shim opens MokManager by itself on the next start of the USOS
// drive (docs/secure-boot-usos.md). Reached from the Secure Boot note on the
// final screen.
type mokScreen struct {
	f        *Flow
	back     func()
	fw       mokenroll.Firmware
	password string
	status   mokenroll.Status
	statusOK bool
	working  bool
	done     bool
	result   string
	tone     tone
}

func newMokScreen(f *Flow, back func()) *mokScreen {
	fw := f.cfg.MokFirmware
	if fw == nil {
		fw = mokenroll.System()
	}
	s := &mokScreen{f: f, back: back, fw: fw, password: mokenroll.DefaultPassword}
	if der, err := usosCertificate(); err == nil {
		// Read-only look at Secure Boot and a pending request.
		if st, err := mokenroll.Check(s.fw, der); err == nil {
			s.status, s.statusOK = st, true
		}
	}
	return s
}

// usosCertificate is the DER certificate the release put on the drive
// (EFI\USOS\ENROLL_THIS_KEY_IN_MOKMANAGER.cer) from the embedded payload.
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

func (s *mokScreen) valid() bool { return mokenroll.ValidatePassword(s.password) == nil }

func (s *mokScreen) prepare() {
	if s.working || !s.valid() {
		return
	}
	s.working, s.result = true, ""
	s.f.busy = true
	password := s.password
	go func() {
		text, t := mokPrepare(s.fw, password)
		s.f.w.post(func() {
			s.working, s.f.busy = false, false
			s.result, s.tone = text, t
			s.done = t == toneSuccess
			s.f.w.invalidate()
		})
	}()
}

// mokPrepare runs the enrollment and returns the localized outcome.
func mokPrepare(fw mokenroll.Firmware, password string) (string, tone) {
	der, err := usosCertificate()
	if err != nil {
		return i18n.T("installer.mok.cert_missing", err.Error()), toneDanger
	}
	res, err := mokenroll.Prepare(fw, der, password, nil)
	switch {
	case errors.Is(err, mokenroll.ErrNotUEFI):
		return i18n.T("installer.mok.not_uefi"), toneDanger
	case errors.Is(err, mokenroll.ErrPrivilege):
		return i18n.T("installer.mok.no_privilege"), toneDanger
	case err != nil:
		return i18n.T("installer.mok.failed", err.Error()), toneDanger
	case res.AlreadyEnrolled:
		return i18n.T("installer.mok.already"), toneSuccess
	}
	text := i18n.T("installer.mok.success", password)
	if res.MergedPending {
		text += "\n" + i18n.T("installer.mok.merged")
	}
	return text, toneSuccess
}

func (s *mokScreen) draw(f *Flow, w *win, area rect) {
	bar, body := w.actionBar(area)
	body = w.pageTitle(body, i18n.T("installer.mok.button"), "", color{}, glyphShield)
	c := w.canvas

	// Bottom block (password row and outcome), measured first so the
	// explanation above gets whatever height is left.
	var notes []struct {
		text string
		t    tone
	}
	add := func(text string, t tone) {
		notes = append(notes, struct {
			text string
			t    tone
		}{text, t})
	}
	switch err := mokenroll.ValidatePassword(s.password); {
	case err != nil:
		add(i18n.T("installer.mok.password_invalid"), toneDanger)
	case len(s.password) < mokenroll.RecommendedPasswordLength:
		add(i18n.T("installer.mok.password_short"), toneWarning)
	}
	switch {
	case s.working:
		add(i18n.T("installer.mok.working"), toneNeutral)
	case s.result != "":
		add(s.result, s.tone)
	case s.statusOK && s.status.Enrolled == mokenroll.Yes:
		add(i18n.T("installer.mok.already"), toneSuccess)
	case s.statusOK && s.status.Pending:
		add(i18n.T("installer.mok.pending"), toneAccent)
	case s.statusOK && s.status.UEFI && s.status.SecureBoot == mokenroll.No:
		add(i18n.T("installer.mok.secure_boot_off"), toneNeutral)
	}
	fieldW := min(w.px(320), body.w()/2)
	hintX := body.Left + fieldW + w.px(16)
	hint := i18n.T("installer.mok.password_hint")
	rowH := max(w.px(40), c.measure(w.captionFont(), hint, body.Right-hintX))
	bottomH := w.px(28) + rowH
	for _, n := range notes {
		bottomH += w.px(12) + w.bannerHeight(body.w(), n.text)
	}

	// Explanation (scrolls when a long translation does not fit).
	panelR := rect{body.Left, body.Top, body.Right, body.Bottom - bottomH - w.px(16)}
	w.panel(panelR)
	view := panelR.inset(w.px(20), w.px(16))
	offset := w.beginScroll("mok.text", view)
	y := view.Top - offset
	width := view.w() - w.px(12)
	y += w.wrapped(w.bodyFont(), i18n.T("installer.mok.intro"), view.Left, y, width, theme.Text) + w.px(12)
	y += w.wrapped(w.semiFont(), i18n.T("installer.mok.steps"), view.Left, y, width, theme.Text) + w.px(12)
	y += w.wrapped(w.bodyFont(), i18n.T("installer.mok.scope"), view.Left, y, width, theme.Muted)
	w.endScroll("mok.text", view, y+offset-view.Top)

	// Password row: label, field, rules next to it; then the notes.
	y = panelR.Bottom + w.px(16)
	c.text(w.semiFont(), i18n.T("installer.mok.password_label"), rect{body.Left, y, body.Right, y + w.px(22)}, theme.Text, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
	y += w.px(28)
	inR := rect{body.Left, y, body.Left + fieldW, y + w.px(40)}
	w.textField("mok.password", inR, editOptions{mono: true, fontSize: 15, initial: s.password, disabled: s.working, onChange: func(text string) {
		s.password = text
		s.result, s.done = "", false
	}})
	hintH := c.measure(w.captionFont(), hint, body.Right-hintX)
	c.text(w.captionFont(), hint, rect{hintX, y + (w.px(40)-min(hintH, w.px(40)))/2, body.Right, y + rowH}, theme.Muted, dtLeft|dtWordBreak|dtEditControl)
	y += rowH
	for _, n := range notes {
		y += w.px(12)
		y += w.banner(body.Left, y, body.w(), n.text, n.t)
	}

	w.actions(bar,
		[]action{{"action.back", buttonSpec{label: i18n.T("installer.common.back"), glyph: glyphBack, disabled: s.working, onClick: s.back}}},
		[]action{{"action.primary", buttonSpec{label: i18n.T("installer.mok.prepare"), glyph: glyphShield, style: buttonPrimary, disabled: s.working || s.done || !s.valid(), onClick: s.prepare, commits: true}}},
	)
}

func (s *mokScreen) key(f *Flow, w *win, vk uintptr) bool {
	if vk == vkEscape && !s.working {
		s.back()
		return true
	}
	return false
}
