package ui

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/snakex21/universal-service-os/installer/internal/install"
)

type FinalScreen struct {
	operation string
	report    install.VerificationReport
	err       error
	onBack    func()
}

func NewFinalScreen(report *install.VerificationReport, err error, onBack func()) *FinalScreen {
	return NewOperationFinalScreen("Instalacja", report, err, onBack)
}

func NewOperationFinalScreen(operation string, report *install.VerificationReport, err error, onBack func()) *FinalScreen {
	var value install.VerificationReport
	if report != nil {
		value = *report
	}
	return &FinalScreen{operation: operation, report: value, err: err, onBack: onBack}
}

func (s *FinalScreen) Content() fyne.CanvasObject {
	success := s.err == nil && s.report.OK()
	titleText := s.operation + " zakonczona i zweryfikowana"
	statusText := "Koncowy odczyt nosnika jest zgodny z oczekiwanym stanem operacji."
	importance := widget.SuccessImportance
	if !success {
		titleText = s.operation + " zakonczona bledem weryfikacji"
		statusText = "Nosnik nie przeszedl koncowej weryfikacji. Nie traktuj go jako poprawnie przygotowanego."
		importance = widget.DangerImportance
	}
	title := widget.NewLabelWithStyle(titleText, fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	title.Importance = importance
	status := widget.NewLabel(statusText)
	status.Wrapping = fyne.TextWrapWord
	status.Importance = importance
	if s.err != nil {
		errorLabel := widget.NewLabel("Blad: " + s.err.Error())
		errorLabel.Wrapping = fyne.TextWrapWord
		errorLabel.Importance = widget.DangerImportance
		status = errorLabel
	}

	table := widget.NewTable(
		func() (int, int) { return len(s.report.Items), 4 },
		func() fyne.CanvasObject {
			label := widget.NewLabel("")
			label.Truncation = fyne.TextTruncateEllipsis
			return label
		},
		func(id widget.TableCellID, object fyne.CanvasObject) {
			label := object.(*widget.Label)
			item := s.report.Items[id.Row]
			label.Importance = widget.MediumImportance
			if !item.Match {
				label.Importance = widget.DangerImportance
			}
			switch id.Col {
			case 0:
				label.SetText(item.Name)
			case 1:
				label.SetText(item.Expected)
			case 2:
				label.SetText(item.Actual)
			case 3:
				if item.Match {
					label.SetText("ZGODNE")
				} else {
					label.SetText("NIEZGODNE")
				}
			}
		},
	)
	table.ShowHeaderRow = true
	headers := []string{"Sprawdzenie", "Zapisane / oczekiwane", "Odczytane z nosnika", "Wynik"}
	table.CreateHeader = func() fyne.CanvasObject {
		return widget.NewLabelWithStyle("", fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	}
	table.UpdateHeader = func(id widget.TableCellID, object fyne.CanvasObject) {
		if id.Row == -1 && id.Col >= 0 && id.Col < len(headers) {
			object.(*widget.Label).SetText(headers[id.Col])
		}
	}
	table.SetColumnWidth(0, 230)
	table.SetColumnWidth(1, 390)
	table.SetColumnWidth(2, 520)
	table.SetColumnWidth(3, 120)

	back := widget.NewButton("Wroc do wyboru trybu", func() {
		if s.onBack != nil {
			s.onBack()
		}
	})
	return container.NewBorder(
		container.NewVBox(title, status, widget.NewSeparator()),
		container.NewHBox(back),
		nil,
		nil,
		table,
	)
}
