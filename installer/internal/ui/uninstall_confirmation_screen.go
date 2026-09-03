package ui

import (
	"fmt"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/snakex21/universal-service-os/installer/internal/domain"
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
	s.confirm = widget.NewButton("ROZPOCZNIJ DEINSTALACJĘ", s.confirmDestructive)
	s.confirm.Importance = widget.DangerImportance
	s.confirm.Disable()
	s.cancel = widget.NewButton("Anuluj", func() {
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
	title := widget.NewLabelWithStyle("UWAGA - DEINSTALACJA USOS", fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	title.Importance = widget.DangerImportance
	warning := widget.NewLabel("Deinstalacja usunie cały układ USOS i utworzy jedną zwykłą partycję exFAT. Cała zawartość DATA, w tym Systems, Utilities i Programs, zniknie. Po rozpoczęciu czyszczenia tablicy partycji operacji nie można anulować ani automatycznie naprawić.")
	warning.Wrapping = fyne.TextWrapWord
	warning.Importance = widget.DangerImportance

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

	losses := container.NewVBox(
		widget.NewLabelWithStyle("Zostanie usunięte:", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
		widget.NewLabel("- ESP z bootmanagerem USOS"),
		widget.NewLabel("- DATA razem z Systems, Utilities, Programs i pozostałą zawartością"),
		widget.NewLabel("- WORK razem z zawartością roboczą i .usos-work"),
	)
	prompt := widget.NewLabel("Aby potwierdzić, wpisz pełny model urządzenia dokładnie znak w znak:")
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
