package ui

import (
	"fmt"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
)

type UpdateConfirmationScreen struct {
	target    installed.Target
	onCancel  func()
	onConfirm func()
}

func NewUpdateConfirmationScreen(target installed.Target, onCancel, onConfirm func()) *UpdateConfirmationScreen {
	return &UpdateConfirmationScreen{target: target, onCancel: onCancel, onConfirm: onConfirm}
}

func (s *UpdateConfirmationScreen) Content() fyne.CanvasObject {
	title := widget.NewLabelWithStyle("Aktualizacja lokalna Universal Service OS", fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	description := widget.NewLabel("Aktualizacja wgra aktualne pliki USOS, uzupełni gotowe foldery systemów i odbuduje katalog menu ESP z faktycznej zawartości DATA. Nie formatuje partycji, nie usuwa obrazów systemów, unattended ani programów i nie czyści WORK.")
	description.Wrapping = fyne.TextWrapWord
	serial := s.target.Disk.DisplaySerial()
	if serial == "" {
		serial = "-"
	}
	identity := widget.NewLabel(fmt.Sprintf(
		"Cel: %s\nPhysicalDrive%d\nPojemność: %s\nSerial: %s",
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
	start := widget.NewButton("Aktualizuj USOS", func() {
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
