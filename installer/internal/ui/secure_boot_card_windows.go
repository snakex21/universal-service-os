//go:build windows

package ui

import (
	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
	"github.com/snakex21/universal-service-os/installer/internal/mokenroll"
)

// secureBootState is what the installer knows about the USOS key on this
// computer (docs/secure-boot-usos.md, "Installer: proactive card"). It is
// computed in the background at startup and after every operation.
type secureBootState struct {
	ready      bool
	gen        int
	status     mokenroll.Status
	assessment mokenroll.Assessment
	machine    string
}

func (f *Flow) mokFirmware() mokenroll.Firmware {
	if f.cfg.MokFirmware != nil {
		return f.cfg.MokFirmware
	}
	return mokenroll.System()
}

func (f *Flow) mokMarkerDir() string {
	if f.cfg.MokMarkerDir != "" {
		return f.cfg.MokMarkerDir
	}
	return mokenroll.AppDataDir()
}

func (f *Flow) machineUUID() string {
	if f.cfg.MachineUUID != nil {
		return f.cfg.MachineUUID()
	}
	id, _ := mokenroll.MachineUUID()
	return id
}

// refreshSecureBoot re-reads the firmware (read-only), this computer's
// marker and the per-machine reports on the detected USOS drives. When a
// source confirms the key, the marker is written so later starts know it
// without the drive.
func (f *Flow) refreshSecureBoot(targets []installed.Target) {
	if targets != nil {
		f.lastTargets = targets
	}
	targets = f.lastTargets
	f.sb.gen++
	gen := f.sb.gen
	fw, dir := f.mokFirmware(), f.mokMarkerDir()
	go func() {
		var next secureBootState
		next.machine = f.machineUUID()
		der, err := usosCertificate()
		if err == nil {
			next.status, _ = mokenroll.Check(fw, der)
		}
		var reports []mokenroll.Report
		for _, t := range targets {
			if rep, ok := mokenroll.ReadReport(t.Media.ESP.VolumePath, next.machine); ok {
				reports = append(reports, rep)
			}
		}
		marker := mokenroll.HasMarker(dir, next.machine)
		next.assessment = mokenroll.Assess(next.status, next.status.WaitPending, marker, reports)
		if next.assessment.Enrolled && !marker && next.machine != "" {
			_ = mokenroll.WriteMarker(dir, next.machine, next.assessment.ConfirmedBy)
		}
		next.ready = true
		f.w.post(func() {
			if gen != f.sb.gen {
				return
			}
			next.gen = gen
			f.sb = next
			f.w.invalidate()
		})
	}()
}

// markKeyDone records "Already done" for this computer.
func (f *Flow) markKeyDone() {
	if f.sb.machine != "" {
		if err := mokenroll.WriteMarker(f.mokMarkerDir(), f.sb.machine, "user"); err != nil {
			f.showToast(err.Error())
		}
	}
	f.sb.assessment = mokenroll.Assessment{Enrolled: true, ConfirmedBy: "user"}
	f.w.invalidate()
}

func (f *Flow) secureBootCardShown() bool {
	return f.sb.ready && f.sb.assessment.Card != mokenroll.CardNone
}

func (f *Flow) secureBootCardHeight(w *win, width int32) int32 {
	if !f.secureBootCardShown() {
		return 0
	}
	textW := width - w.px(20+48+16+20)
	h := w.px(18) + w.px(24) + w.px(4) + w.canvas.measure(w.bodyFont(), f.secureBootCardText(), textW) + w.px(14) + w.px(buttonHeight) + w.px(18)
	return max(h, w.px(96))
}

func (f *Flow) secureBootCardText() string {
	if f.sb.assessment.Card == mokenroll.CardPrepared {
		return i18n.T("installer.sbcard.text") + " " + i18n.T("installer.mok.pending")
	}
	return i18n.T("installer.sbcard.text")
}

// drawSecureBootCard draws "Secure Boot is on on this computer ... [Prepare
// (one time)] [Already done]" at y and returns its height (0 when hidden).
func (f *Flow) drawSecureBootCard(w *win, x, y, width int32, back func()) int32 {
	h := f.secureBootCardHeight(w, width)
	if h == 0 {
		return 0
	}
	c := w.canvas
	r := rect{x, y, x + width, y + h}
	radius := w.px(radiusCard)
	c.roundRect(r, radius, theme.WarningSoft)
	c.roundBorder(r, radius, max(1, w.px(1)), theme.Warning.mix(theme.Border, 0.45))
	inner := r.inset(w.px(20), w.px(18))
	tile := rect{inner.Left, inner.Top, inner.Left + w.px(48), inner.Top + w.px(48)}
	c.roundRect(tile, w.px(12), theme.Warning.mix(theme.Background, 0.78))
	w.glyph(glyphShield, tile, 22, theme.Warning)
	tx := tile.Right + w.px(16)
	c.text(w.font(sizeH2+1, fwSemiBold), i18n.T("installer.sbcard.title"), rect{tx, inner.Top, inner.Right, inner.Top + w.px(24)}, theme.Text, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
	ty := inner.Top + w.px(28)
	ty += w.wrapped(w.bodyFont(), f.secureBootCardText(), tx, ty, inner.Right-tx, theme.Muted) + w.px(14)
	prepare := buttonSpec{label: i18n.T("installer.sbcard.prepare"), glyph: glyphShield, style: buttonPrimary, onClick: func() { f.showMok(back) }}
	pw := min(w.buttonWidth(prepare), inner.Right-tx)
	w.button("sb.prepare", rect{tx, ty, tx + pw, ty + w.px(buttonHeight)}, prepare)
	done := buttonSpec{label: i18n.T("installer.sbcard.done"), glyph: glyphCheck, onClick: f.markKeyDone}
	dx := tx + pw + w.px(10)
	if dw := w.buttonWidth(done); dx+dw <= inner.Right {
		w.button("sb.done", rect{dx, ty, dx + dw, ty + w.px(buttonHeight)}, done)
	}
	return h
}

// showMok opens the "Add the USOS key" guide; back returns to the caller.
func (f *Flow) showMok(back func()) {
	f.show(newMokScreen(f, back), "action.primary")
}
