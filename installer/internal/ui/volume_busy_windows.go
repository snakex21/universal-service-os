//go:build windows

package ui

import (
	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"github.com/snakex21/universal-service-os/installer/internal/volumelock"
)

// volumeBusyPrompt is the Retry/Cancel card the progress screen shows while
// the operation's worker waits for the user (a volume of the drive stayed
// locked by another program through the automatic retries).
type volumeBusyPrompt struct {
	err   *volumelock.InUseError
	reply chan bool
}

func (p *volumeBusyPrompt) answer(retry bool) {
	select {
	case p.reply <- retry:
	default:
	}
}

// askVolumeInUse runs on the operation's worker goroutine and blocks until
// the user chooses. Outside an operation's progress screen it cancels.
func (f *Flow) askVolumeInUse(e *volumelock.InUseError) bool {
	reply := make(chan bool, 1)
	f.w.post(func() {
		s, ok := f.screen.(*progressScreen)
		if !ok || s.busy != nil {
			reply <- false
			return
		}
		s.busy = &volumeBusyPrompt{err: e, reply: reply}
		s.log.append(e.Error())
		f.w.focus = "busy.retry"
		procMessageBeep.Call(0x30) // MB_ICONEXCLAMATION
		f.w.invalidate()
	})
	return <-reply
}

func (s *progressScreen) resolveBusy(retry bool) {
	if s.busy == nil {
		return
	}
	busy := s.busy
	s.busy = nil
	busy.answer(retry)
	s.f.w.invalidate()
}

// drawBusy draws the card at the top of r and returns its height.
func (s *progressScreen) drawBusy(w *win, r rect) int32 {
	c := w.canvas
	message := s.busy.err.Message()
	textW := r.w() - w.px(40+32)
	textH := c.measure(w.bodyFont(), message, textW)
	h := w.px(18+26+8) + textH + w.px(16+buttonHeight+18)
	card := rect{r.Left, r.Top, r.Right, r.Top + h}
	c.roundRect(card, w.px(8), theme.WarningSoft)
	c.roundBorder(card, w.px(8), max(1, w.px(1)), theme.Warning)
	icon := rect{card.Left + w.px(16), card.Top + w.px(18), card.Left + w.px(40), card.Top + w.px(44)}
	w.glyph(glyphWarning, icon, 18, theme.Warning)
	x := icon.Right + w.px(16)
	c.text(w.font(sizeH2, fwSemiBold), i18n.T("installer.volume_busy.title"), rect{x, card.Top + w.px(18), card.Right - w.px(16), card.Top + w.px(44)}, theme.Text, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
	w.wrapped(w.bodyFont(), message, x, card.Top+w.px(52), textW, theme.Text)
	bar := rect{x, card.Bottom - w.px(18+buttonHeight), card.Right - w.px(16), card.Bottom - w.px(18)}
	w.actions(bar, nil, []action{
		{"busy.cancel", buttonSpec{label: i18n.T("installer.volume_busy.cancel"), onClick: func() { s.resolveBusy(false) }}},
		{"busy.retry", buttonSpec{label: i18n.T("installer.volume_busy.retry"), glyph: glyphSync, style: buttonPrimary, onClick: func() { s.resolveBusy(true) }}},
	})
	return h
}
