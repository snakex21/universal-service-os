package ui

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
)

type UninstallConfirmationScreen struct {
	target    installed.Target
	model     domain.Confirmation
	entry     *widget.Entry
	confirm   *widget.Button
	cancel    *widget.Button
	onCancel  func()
	onConfirm func()
}

func NewUninstallConfirmationScreen(target installed.Target, onCancel, onConfirm func()) *UninstallConfirmationScreen {
	s := &UninstallConfirmationScreen{
		target:    target,
		model:     domain.BuildConfirmation(target.Disk),
		onCancel:  onCancel,
		onConfirm: onConfirm,
	}
	s.entry = widget.NewEntry()
	s.entry.SetPlaceHolder(s.model.ExpectedText)
	s.confirm = widget.NewButton(i18n.T("installer.uninstall.button"), s.confirmDestructive)
	s.confirm.Importance = widget.DangerImportance
	s.confirm.Disable()
	s.cancel = widget.NewButton(i18n.T("installer.common.cancel"), func() {
		if s.onCancel != nil {
			s.onCancel()
		}
	})
	s.entry.OnChanged = func(value string) {
		if s.model.Accepts(value) {
			s.confirm.Enable()
		} else {
			s.confirm.Disable()
		}
	}
	return s
}

func (s *UninstallConfirmationScreen) Content() fyne.CanvasObject {
	title := widget.NewLabelWithStyle(i18n.T("installer.uninstall.confirm_title"), fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	title.Importance = widget.DangerImportance
	warning := widget.NewLabel(i18n.T("installer.uninstall.confirm_warning"))
	warning.Wrapping = fyne.TextWrapWord
	warning.Importance = widget.DangerImportance

	serial := s.target.Disk.DisplaySerial()
	if serial == "" {
		serial = "-"
	}
	identity := widget.NewLabel(i18n.T(
		"installer.common.target_identity",
		s.target.Disk.DisplayName(),
		s.target.Disk.Number,
		domain.FormatBytes(s.target.Disk.SizeBytes),
		serial,
	))
	identity.Wrapping = fyne.TextWrapWord

	losses := container.NewVBox(
		widget.NewLabelWithStyle(i18n.T("installer.uninstall.losses_header"), fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
		widget.NewLabel(i18n.T("installer.uninstall.loss_esp")),
		widget.NewLabel(i18n.T("installer.uninstall.loss_data")),
		widget.NewLabel(i18n.T("installer.uninstall.loss_work")),
	)
	prompt := widget.NewLabel(i18n.T("installer.uninstall.prompt"))
	expected := widget.NewLabelWithStyle(s.model.ExpectedText, fyne.TextAlignLeading, fyne.TextStyle{Bold: true, Monospace: true})
	buttons := container.NewHBox(s.cancel, s.confirm)
	return container.NewBorder(
		container.NewVBox(title, warning, widget.NewSeparator(), identity, widget.NewSeparator()),
		container.NewVBox(widget.NewSeparator(), prompt, expected, s.entry, buttons),
		nil,
		nil,
		losses,
	)
}

func (s *UninstallConfirmationScreen) confirmDestructive() {
	if !s.model.Accepts(s.entry.Text) || s.onConfirm == nil {
		return
	}
	s.confirm.Disable()
	s.cancel.Disable()
	s.entry.Disable()
	s.onConfirm()
}
