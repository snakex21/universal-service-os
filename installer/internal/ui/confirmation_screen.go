package ui

import (
	"fmt"
	"strings"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/snakex21/universal-service-os/installer/internal/domain"
)

type ConfirmationScreen struct {
	model     domain.Confirmation
	entry     *widget.Entry
	confirm   *widget.Button
	cancel    *widget.Button
	onCancel  func()
	onConfirm func()
}

func NewConfirmationScreen(disk domain.Disk, onCancel, onConfirm func()) *ConfirmationScreen {
	s := &ConfirmationScreen{
		model:     domain.BuildConfirmation(disk),
		onCancel:  onCancel,
		onConfirm: onConfirm,
	}
	s.entry = widget.NewEntry()
	s.entry.SetPlaceHolder(s.model.ExpectedText)
	s.confirm = widget.NewButton("ROZPOCZNIJ KASOWANIE I INSTALACJĘ", s.confirmDestructive)
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

func (s *ConfirmationScreen) Content() fyne.CanvasObject {
	title := widget.NewLabelWithStyle("UWAGA - OPERACJA NISZCZĄCA", fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	title.Importance = widget.DangerImportance
	warning := widget.NewLabel("Wszystkie partycje i wszystkie dane na wybranym nośniku zostaną bezpowrotnie usunięte. Po rozpoczęciu kroku 1/8 — czyszczenia tablicy partycji — anulowanie nie będzie już możliwe. Nie odłączaj nośnika ani nie wyłączaj komputera podczas operacji.")
	warning.Wrapping = fyne.TextWrapWord
	warning.Importance = widget.DangerImportance

	disk := widget.NewLabel(fmt.Sprintf(
		"Cel: %s\nPhysicalDrive%d\nPojemność: %s\nSerial: %s",
		s.model.DiskModel,
		s.model.DiskNumber,
		s.model.DiskCapacity,
		s.model.DiskSerial,
	))

	lossHeader := widget.NewLabelWithStyle("To zostanie usunięte:", fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	lossObjects := make([]fyne.CanvasObject, 0, len(s.model.Losses)+1)
	lossObjects = append(lossObjects, lossHeader)
	if len(s.model.Losses) == 0 {
		lossObjects = append(lossObjects, widget.NewLabel("Brak obecnie rozpoznanych woluminów — tablica partycji i tak zostanie wyczyszczona."))
	}
	for _, item := range s.model.Losses {
		root := strings.TrimSpace(item.RootContent)
		if root == "" {
			root = "-"
		}
		label := widget.NewLabel(fmt.Sprintf(
			"%s\n  system plików: %s | pojemność: %s | zajęte: %s\n  katalog główny: %s",
			item.Volume,
			item.FileSystem,
			item.Capacity,
			item.Used,
			root,
		))
		label.Wrapping = fyne.TextWrapWord
		lossObjects = append(lossObjects, label)
	}
	lossScroll := container.NewVScroll(container.NewVBox(lossObjects...))
	lossScroll.SetMinSize(fyne.NewSize(1000, 280))

	prompt := widget.NewLabel("Aby potwierdzić, wpisz pełny model urządzenia dokładnie znak w znak:")
	expected := widget.NewLabelWithStyle(s.model.ExpectedText, fyne.TextAlignLeading, fyne.TextStyle{Bold: true, Monospace: true})
	buttons := container.NewHBox(s.cancel, s.confirm)

	return container.NewBorder(
		container.NewVBox(title, warning, widget.NewSeparator(), disk),
		container.NewVBox(widget.NewSeparator(), prompt, expected, s.entry, buttons),
		nil,
		nil,
		lossScroll,
	)
}

func (s *ConfirmationScreen) confirmDestructive() {
	if !s.model.Accepts(s.entry.Text) || s.onConfirm == nil {
		return
	}
	s.confirm.Disable()
	s.cancel.Disable()
	s.entry.Disable()
	s.onConfirm()
}
