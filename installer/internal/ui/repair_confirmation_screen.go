package ui

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
)

type RepairConfirmationScreen struct {
	target    installed.Target
	onCancel  func()
	onConfirm func()
}

func NewRepairConfirmationScreen(target installed.Target, onCancel, onConfirm func()) *RepairConfirmationScreen {
	return &RepairConfirmationScreen{target: target, onCancel: onCancel, onConfirm: onConfirm}
}

func (s *RepairConfirmationScreen) Content() fyne.CanvasObject {
	title := widget.NewLabelWithStyle(i18n.T("installer.repair.title"), fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	description := widget.NewLabel(i18n.T("installer.repair.description"))
	description.Wrapping = fyne.TextWrapWord
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
	back := widget.NewButton(i18n.T("installer.common.back"), func() {
		if s.onCancel != nil {
			s.onCancel()
		}
	})
	start := widget.NewButton(i18n.T("installer.repair.button"), func() {
		if s.onConfirm != nil {
			s.onConfirm()
		}
	})
	start.Importance = widget.HighImportance
	return container.NewBorder(
		container.NewVBox(title, description, widget.NewSeparator()),
		container.NewHBox(back, start),
		nil,
		nil,
		identity,
	)
}
