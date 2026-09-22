package ui

import (
	"fmt"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
	"github.com/snakex21/universal-service-os/installer/internal/localupdate"
)

type UpdateConfirmationScreen struct {
	target    installed.Target
	onCancel  func()
	onConfirm func(allowDowngrade bool)
}

func NewUpdateConfirmationScreen(target installed.Target, onCancel func(), onConfirm func(bool)) *UpdateConfirmationScreen {
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

	payloadInfo, payloadErr := localupdate.PayloadBuildInfo()
	versionText := fmt.Sprintf("Wersja nośnika: %s", s.target.BuildInfo.Display())
	if payloadErr != nil {
		versionText += "\nWersja instalatora: BŁĄD ODCZYTU PAYLOADU"
	} else {
		versionText += fmt.Sprintf("\nWersja instalatora: %s", payloadInfo.Display())
	}
	versions := widget.NewLabel(versionText)
	versions.Wrapping = fyne.TextWrapWord

	back := widget.NewButton("Wstecz", func() {
		if s.onCancel != nil {
			s.onCancel()
		}
	})
	start := widget.NewButton("Aktualizuj USOS", nil)
	start.Importance = widget.HighImportance

	middle := container.NewVBox(identity, widget.NewSeparator(), versions)
	allowDowngrade := false
	if payloadErr != nil {
		warning := widget.NewLabel("Nie można potwierdzić wersji payloadu instalatora: " + payloadErr.Error())
		warning.Wrapping = fyne.TextWrapWord
		middle.Add(widget.NewSeparator())
		middle.Add(warning)
		start.Disable()
	} else if localupdate.IsDowngrade(s.target.BuildInfo, payloadInfo) {
		warning := widget.NewLabelWithStyle(
			fmt.Sprintf("Nośnik ma nowszą wersję (%s), instalator ma (%s) — cofnąć?", s.target.BuildInfo.Display(), payloadInfo.Display()),
			fyne.TextAlignLeading,
			fyne.TextStyle{Bold: true},
		)
		warning.Wrapping = fyne.TextWrapWord
		confirm := widget.NewCheck("Potwierdzam cofnięcie nośnika do starszej wersji USOS.", func(checked bool) {
			allowDowngrade = checked
			if checked {
				start.Enable()
			} else {
				start.Disable()
			}
		})
		middle.Add(widget.NewSeparator())
		middle.Add(warning)
		middle.Add(confirm)
		start.SetText("Cofnij USOS do " + payloadInfo.Display())
		start.Importance = widget.DangerImportance
		start.Disable()
	}

	start.OnTapped = func() {
		if s.onConfirm != nil {
			s.onConfirm(allowDowngrade)
		}
	}

	return container.NewBorder(
		container.NewVBox(title, description, widget.NewSeparator()),
		container.NewHBox(back, start),
		nil,
		nil,
		middle,
	)
}
