//go:build windows

package ui

import (
	"strings"
	"time"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
	"github.com/snakex21/universal-service-os/installer/internal/localupdate"
)

// drawTarget draws the identity card of the drive an operation will touch.
// Returns the height used.
func drawTarget(w *win, x, y, width int32, disk domain.Disk, extra [][2]string) int32 {
	c := w.canvas
	serial := disk.DisplaySerial()
	if serial == "" {
		serial = "-"
	}
	rows := [][2]string{
		{i18n.T("installer.field.disk"), "PhysicalDrive" + itoa(disk.Number)},
		{i18n.T("installer.field.capacity"), domain.FormatBytes(disk.SizeBytes)},
		{i18n.T("installer.field.bus"), busLabel(disk)},
		{i18n.T("installer.field.serial"), serial},
	}
	rows = append(rows, extra...)
	rows = append(rows, [2]string{i18n.T("installer.common.drive_language"), languageName(i18n.Current())})
	inner := width - w.px(40)
	labelW := min(w.px(170), inner/3)
	h := w.px(18) + w.px(40) + w.px(12)
	for _, kv := range rows {
		h += w.kvHeight(labelW, inner, kv[0], kv[1]) + w.px(6)
	}
	h += w.px(12)
	r := rect{x, y, x + width, y + h}
	w.panel(r)
	iconSize := w.px(40)
	ix, iy := x+w.px(20), y+w.px(18)
	w.driveIcon(classifyDrive(disk), ix, iy, iconSize)
	c.text(w.font(sizeH2, fwSemiBold), disk.DisplayName(), rect{ix + iconSize + w.px(14), iy, r.Right - w.px(20), iy + iconSize}, theme.Text, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
	yy := iy + iconSize + w.px(12)
	for _, kv := range rows {
		yy += w.kvRow(ix, yy, labelW, inner, kv[0], kv[1]) + w.px(6)
	}
	return h
}

func itoa(n uint32) string {
	if n == 0 {
		return "0"
	}
	var b [10]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}

// ---- erase confirmation (install and uninstall) ---------------------------

// eraseConfirmScreen guards the destructive operations. The start button is
// enabled only after the "everything on this drive will be erased" box is
// ticked and the screen has been shown for domain.DestructiveConfirmDelay.
type eraseConfirmScreen struct {
	f         *Flow
	op        operation
	disk      domain.Disk
	target    installed.Target
	model     domain.Confirmation
	gate      domain.DestructiveGate
	submitted bool
	onCancel  func()
	onConfirm func()
}

func newInstallConfirmation(f *Flow, disk domain.Disk) *eraseConfirmScreen {
	s := &eraseConfirmScreen{f: f, op: opInstall, disk: disk, model: domain.BuildConfirmation(disk), gate: domain.NewDestructiveGate(time.Now()), onCancel: f.showInstallDevices}
	s.onConfirm = func() { f.showInstallProgress(disk) }
	return s
}

func newUninstallConfirmation(f *Flow, target installed.Target) *eraseConfirmScreen {
	s := &eraseConfirmScreen{f: f, op: opUninstall, disk: target.Disk, target: target, model: domain.BuildConfirmation(target.Disk), gate: domain.NewDestructiveGate(time.Now())}
	s.onCancel = func() { f.showInstalledDevices(opUninstall) }
	s.onConfirm = func() { f.showUninstallProgress(target) }
	return s
}

func (s *eraseConfirmScreen) relocalize() {
	s.model = domain.BuildConfirmation(s.disk)
}

func (s *eraseConfirmScreen) accepted() bool { return s.gate.Ready(time.Now()) }

func (s *eraseConfirmScreen) toggle() {
	if !s.submitted {
		s.gate.Toggle()
	}
}

func (s *eraseConfirmScreen) confirm() {
	if s.submitted || !s.accepted() || s.onConfirm == nil {
		return
	}
	s.submitted = true
	s.onConfirm()
}

func (s *eraseConfirmScreen) cancel() {
	if !s.submitted && s.onCancel != nil {
		s.onCancel()
	}
}

func (s *eraseConfirmScreen) draw(f *Flow, w *win, area rect) {
	c := w.canvas
	bar, body := w.actionBar(area)
	title, warning := i18n.T("installer.confirm.title"), i18n.T("installer.confirm.warning")
	button := i18n.T("installer.confirm.button")
	if s.op == opUninstall {
		title, warning = i18n.T("installer.uninstall.confirm_title"), i18n.T("installer.uninstall.confirm_warning")
		button = i18n.T("installer.uninstall.button")
	}
	body = w.pageTitle(body, title, "", theme.Danger, glyphWarning)
	body.Top -= w.px(4)
	body.Top += w.banner(body.Left, body.Top, body.w(), warning, toneDanger) + w.px(16)

	// Bottom block: the acknowledgement checkbox. Measured first so the
	// middle area gets whatever height is left.
	ack := i18n.T("installer.confirm.acknowledge")
	box := w.px(20)
	ackH := max(box, c.measure(w.bodyFont(), ack, body.w()-box-w.px(12)))
	middle := rect{body.Left, body.Top, body.Right, body.Bottom - ackH - w.px(18)}
	leftW := middle.w() * 44 / 100
	leftR, rightR := middle.cutLeft(leftW)
	rightR.Left += w.px(16)
	drawTarget(w, leftR.Left, leftR.Top, leftR.w(), s.disk, nil)
	s.drawLosses(w, rightR)

	w.checkbox("confirm.ack", body.Left+w.px(4), body.Bottom-ackH, body.w()-w.px(8), ack, s.gate.Acknowledged(), s.toggle)

	now := time.Now()
	if left := s.gate.RemainingSeconds(now); left > 0 && !s.submitted {
		button += " (" + itoa(uint32(left)) + ")"
		w.animate = true // repaint until the delay has passed
	}
	w.actions(bar,
		[]action{{"action.back", buttonSpec{label: i18n.T("installer.common.cancel"), disabled: s.submitted, onClick: s.cancel}}},
		[]action{{"confirm.go", buttonSpec{label: button, glyph: glyphWarning, style: buttonDanger, disabled: s.submitted || !s.gate.Ready(now), onClick: s.confirm, commits: true}}},
	)
}

func (s *eraseConfirmScreen) drawLosses(w *win, r rect) {
	c := w.canvas
	w.panel(r)
	inner := r.inset(w.px(20), w.px(16))
	c.text(w.font(sizeBody, fwSemiBold), i18n.T("installer.confirm.losses_header"), rect{inner.Left, inner.Top, inner.Right, inner.Top + w.px(22)}, theme.Danger.mix(theme.Text, 0.3), dtLeft|dtSingleLine|dtVCenter)
	view := rect{inner.Left, inner.Top + w.px(30), inner.Right, inner.Bottom}
	offset := w.beginScroll("losses", view)
	y := view.Top - offset
	width := view.w() - w.px(12)
	if s.op == opUninstall {
		for _, line := range []string{i18n.T("installer.uninstall.loss_esp"), i18n.T("installer.uninstall.loss_data"), i18n.T("installer.uninstall.loss_work")} {
			line = strings.TrimSpace(strings.TrimPrefix(line, "-"))
			w.glyph(glyphDelete, rect{view.Left, y, view.Left + w.px(18), y + w.px(20)}, 13, theme.Danger)
			y += w.wrapped(w.bodyFont(), line, view.Left+w.px(28), y, width-w.px(28), theme.Text) + w.px(10)
		}
	} else if len(s.model.Losses) == 0 {
		y += w.wrapped(w.bodyFont(), i18n.T("installer.confirm.no_volumes"), view.Left, y, width, theme.Muted)
	} else {
		for _, item := range s.model.Losses {
			root := strings.TrimSpace(item.RootContent)
			if root == "" {
				root = "-"
			}
			w.glyph(glyphDrive, rect{view.Left, y, view.Left + w.px(18), y + w.px(20)}, 13, theme.Danger)
			x := view.Left + w.px(28)
			y += w.wrapped(w.semiFont(), item.Volume, x, y, width-w.px(28), theme.Text) + w.px(2)
			meta := joinMeta(item.FileSystem, i18n.T("installer.confirm.capacity", item.Capacity), i18n.T("installer.confirm.used", item.Used))
			y += w.wrapped(w.captionFont(), meta, x, y, width-w.px(28), theme.Muted) + w.px(2)
			y += w.wrapped(w.captionFont(), i18n.T("installer.confirm.root", root), x, y, width-w.px(28), theme.Muted) + w.px(12)
		}
	}
	w.endScroll("losses", view, y+offset-view.Top)
}

func (s *eraseConfirmScreen) key(f *Flow, w *win, vk uintptr) bool {
	if vk == vkEscape {
		s.cancel()
		return true
	}
	return false
}

// ---- update confirmation (downgrade needs an explicit tick) --------------

type updateConfirmScreen struct {
	f              *Flow
	target         installed.Target
	payloadInfo    string
	payloadErr     error
	downgrade      bool
	allowDowngrade bool
	started        bool
}

func newUpdateConfirmation(f *Flow, target installed.Target) *updateConfirmScreen {
	s := &updateConfirmScreen{f: f, target: target}
	info, err := localupdate.PayloadBuildInfo()
	s.payloadErr = err
	if err == nil {
		s.payloadInfo = info.Display()
		s.downgrade = localupdate.IsDowngrade(target.BuildInfo, info)
	}
	return s
}

func (s *updateConfirmScreen) canStart() bool {
	if s.started || s.payloadErr != nil {
		return false
	}
	return !s.downgrade || s.allowDowngrade
}

func (s *updateConfirmScreen) start() {
	if !s.canStart() {
		return
	}
	s.started = true
	s.f.showUpdateProgress(s.target, s.downgrade && s.allowDowngrade)
}

func (s *updateConfirmScreen) draw(f *Flow, w *win, area rect) {
	bar, body := w.actionBar(area)
	body = w.pageTitle(body, i18n.T("installer.update.title"), i18n.T("installer.update.description"), color{}, glyphSync)
	leftW := body.w() * 50 / 100
	leftR, rightR := body.cutLeft(leftW)
	rightR.Left += w.px(16)
	drawTarget(w, leftR.Left, leftR.Top, leftR.w(), s.target.Disk, nil)

	// Versions card.
	c := w.canvas
	inner := rightR.Right - rightR.Left - w.px(40)
	labelW := min(w.px(170), inner/2)
	installerVersion := s.payloadInfo
	if s.payloadErr != nil {
		installerVersion = i18n.T("installer.update.payload_read_error")
	}
	rows := [][2]string{
		{i18n.T("installer.update.media_version_label"), s.target.BuildInfo.Display()},
		{i18n.T("installer.update.installer_version_label"), installerVersion},
	}
	h := w.px(18+26+12) + w.px(16)
	for _, kv := range rows {
		h += w.kvHeight(labelW, inner, kv[0], kv[1]) + w.px(6)
	}
	card := rect{rightR.Left, rightR.Top, rightR.Right, rightR.Top + h}
	w.panel(card)
	x, y := card.Left+w.px(20), card.Top+w.px(18)
	c.text(w.font(sizeBody, fwSemiBold), i18n.T("installer.update.versions"), rect{x, y, card.Right - w.px(20), y + w.px(26)}, theme.Text, dtLeft|dtSingleLine|dtVCenter)
	y += w.px(26 + 12)
	for _, kv := range rows {
		y += w.kvRow(x, y, labelW, inner, kv[0], kv[1]) + w.px(6)
	}
	y = card.Bottom + w.px(16)
	switch {
	case s.payloadErr != nil:
		w.banner(rightR.Left, y, rightR.w(), i18n.T("installer.update.payload_unverified", s.payloadErr.Error()), toneDanger)
	case s.downgrade:
		y += w.banner(rightR.Left, y, rightR.w(), i18n.T("installer.update.downgrade_warning", s.target.BuildInfo.Display(), s.payloadInfo), toneDanger) + w.px(16)
		w.checkbox("update.downgrade", rightR.Left+w.px(4), y, rightR.w()-w.px(8), i18n.T("installer.update.downgrade_confirm"), s.allowDowngrade, func() {
			if !s.started {
				s.allowDowngrade = !s.allowDowngrade
			}
		})
	default:
		w.banner(rightR.Left, y, rightR.w(), i18n.T("installer.update.safe_note"), toneSuccess)
	}

	spec := buttonSpec{label: i18n.T("installer.mode.update.button"), glyph: glyphSync, style: buttonPrimary, disabled: !s.canStart(), onClick: s.start, commits: true}
	if s.downgrade && s.payloadErr == nil {
		spec.label = i18n.T("installer.update.downgrade_button", s.payloadInfo)
		spec.style = buttonDanger
	}
	w.actions(bar,
		[]action{{"action.back", buttonSpec{label: i18n.T("installer.common.back"), glyph: glyphBack, disabled: s.started, onClick: func() { f.showInstalledDevices(opUpdate) }}}},
		[]action{{"action.primary", spec}},
	)
}

func (s *updateConfirmScreen) key(f *Flow, w *win, vk uintptr) bool {
	if vk == vkEscape && !s.started {
		f.showInstalledDevices(opUpdate)
		return true
	}
	return false
}

// ---- repair confirmation --------------------------------------------------

type repairConfirmScreen struct {
	f       *Flow
	target  installed.Target
	started bool
}

func newRepairConfirmation(f *Flow, target installed.Target) *repairConfirmScreen {
	return &repairConfirmScreen{f: f, target: target}
}

func (s *repairConfirmScreen) start() {
	if s.started {
		return
	}
	s.started = true
	s.f.showRepairProgress(s.target)
}

func (s *repairConfirmScreen) draw(f *Flow, w *win, area rect) {
	bar, body := w.actionBar(area)
	body = w.pageTitle(body, i18n.T("installer.repair.title"), i18n.T("installer.repair.description"), color{}, glyphRepair)
	leftR, rightR := body.cutLeft(body.w() * 50 / 100)
	rightR.Left += w.px(16)
	drawTarget(w, leftR.Left, leftR.Top, leftR.w(), s.target.Disk, [][2]string{{i18n.T("installer.field.version"), s.target.BuildInfo.Display()}})
	y := rightR.Top
	y += w.banner(rightR.Left, y, rightR.w(), i18n.T("installer.repair.keeps"), toneSuccess) + w.px(12)
	w.banner(rightR.Left, y, rightR.w(), i18n.T("installer.repair.rewrites"), toneAccent)
	w.actions(bar,
		[]action{{"action.back", buttonSpec{label: i18n.T("installer.common.back"), glyph: glyphBack, disabled: s.started, onClick: func() { f.showInstalledDevices(opRepair) }}}},
		[]action{{"action.primary", buttonSpec{label: i18n.T("installer.repair.button"), glyph: glyphRepair, style: buttonPrimary, disabled: s.started, onClick: s.start, commits: true}}},
	)
}

func (s *repairConfirmScreen) key(f *Flow, w *win, vk uintptr) bool {
	if vk == vkEscape && !s.started {
		f.showInstalledDevices(opRepair)
		return true
	}
	return false
}

// Compile-time check that the engines satisfy the runner interfaces.
var _ InstallRunner = (*install.Engine)(nil)
