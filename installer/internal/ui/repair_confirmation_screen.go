package ui

import (
	"fmt"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/snakex21/universal-service-os/installer/internal/domain"
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
	title := widget.NewLabelWithStyle("Naprawa Universal Service OS", fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	description := widget.NewLabel("Naprawa odtworzy wylacznie pliki na ESP. DATA i WORK nie beda formatowane ani czyszczone.")
	description.Wrapping = fyne.TextWrapWord
	serial := s.target.Disk.DisplaySerial()
	if serial == "" {
		serial = "-"
	}
	identity := widget.NewLabel(fmt.Sprintf(
		"Cel: %s\nPhysicalDrive%d\nPojemnosc: %s\nSerial: %s",
		s.target.Disk.DisplayName(),
		s.target.Disk.Number,
		domain.FormatBytes(s.target.Disk.SizeBytes),
		serial,
	))
	identity.Wrapping = fyne.TextWrapWord
	back := widget.NewButton("Wstecz", func() {
		if s.onCancel != nil {
			s.onCancel()
		}
	})
	start := widget.NewButton("Napraw ESP", func() {
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
