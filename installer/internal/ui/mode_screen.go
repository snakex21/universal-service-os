package ui

import (
	"fmt"
	"strings"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
)

type ModeScreen struct {
	onInstall       func()
	onUpdate        func()
	onRepair        func()
	onUninstall     func()
	installedSource InstalledUSOSSource
	status          *widget.Label
}

func NewModeScreen(onInstall, onUpdate, onRepair, onUninstall func()) *ModeScreen {
	return NewModeScreenWithDetection(onInstall, onUpdate, onRepair, onUninstall, nil)
}

func NewModeScreenWithDetection(onInstall, onUpdate, onRepair, onUninstall func(), installedSource InstalledUSOSSource) *ModeScreen {
	s := &ModeScreen{onInstall: onInstall, onUpdate: onUpdate, onRepair: onRepair, onUninstall: onUninstall, installedSource: installedSource}
	s.status = widget.NewLabel("Sprawdzanie, czy podłączony jest nośnik z USOS...")
	s.status.Wrapping = fyne.TextWrapWord
	s.Refresh()
	return s
}

func (s *ModeScreen) Refresh() {
	if s.status == nil {
		return
	}
	if s.installedSource == nil {
		s.status.Importance = widget.MediumImportance
		s.status.SetText("Podłącz nośnik i wybierz operację. Istniejący USOS możesz lokalnie zaktualizować, naprawić albo odinstalować.")
		return
	}
	s.status.Importance = widget.MediumImportance
	s.status.SetText("Sprawdzanie, czy podłączony jest nośnik z USOS...")
	s.status.Refresh()
	go func() {
		targets, err := s.installedSource.ListInstalledUSOS()
		fyne.Do(func() {
			if err != nil {
				s.status.Importance = widget.DangerImportance
				s.status.SetText("Nie udało się sprawdzić zainstalowanego USOS: " + err.Error())
				s.status.Refresh()
				return
			}
			if len(targets) == 0 {
				s.status.Importance = widget.MediumImportance
				s.status.SetText("Nie wykryto zainstalowanego USOS. Instalacja utworzy nowy nośnik.")
			} else {
				s.status.Importance = widget.HighImportance
				names := make([]string, 0, len(targets))
				for _, t := range targets {
					names = append(names, t.Disk.DisplayName())
				}
				label := "Wykryto USOS na: " + strings.Join(names, ", ")
				if len(targets) == 1 {
					label += ". Ten nośnik jest ukryty przed ponowną instalacją — użyj aktualizacji, naprawy albo deinstalacji."
				} else if len(targets) >= 2 && len(targets) <= 4 {
					label += fmt.Sprintf(". Te %d nośniki są ukryte przed ponowną instalacją — użyj aktualizacji, naprawy albo deinstalacji.", len(targets))
				} else {
					label += fmt.Sprintf(". Tych %d nośników jest ukrytych przed ponowną instalacją — użyj aktualizacji, naprawy albo deinstalacji.", len(targets))
				}
				s.status.SetText(label)
			}
			s.status.Refresh()
		})
	}()
}

func (s *ModeScreen) Content() fyne.CanvasObject {
	title := widget.NewLabelWithStyle("Universal Service OS Installer", fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	description := widget.NewLabel("Wybierz operację. Instalacja przygotowuje nowy nośnik, aktualizacja lokalna wgrywa bieżący build bez formatowania, naprawa odtwarza ESP, a deinstalacja przywraca nośnik do jednej zwykłej partycji exFAT.")
	description.Wrapping = fyne.TextWrapWord

	installButton := widget.NewButton("Zainstaluj USOS", s.onInstall)
	installButton.Importance = widget.HighImportance
	updateButton := widget.NewButton("Aktualizuj USOS", s.onUpdate)
	updateButton.Importance = widget.HighImportance
	repairButton := widget.NewButton("Napraw USOS", s.onRepair)
	uninstallButton := widget.NewButton("Odinstaluj USOS", s.onUninstall)
	uninstallButton.Importance = widget.DangerImportance
	refreshButton := widget.NewButton("Odśwież stan USOS", s.Refresh)

	cards := container.NewGridWithColumns(1,
		widget.NewCard("Instalacja", "Tworzy ESP, DATA i WORK. Wszystkie dane na wybranym nośniku zostaną usunięte. Nośniki z wykrytym USOS są tu ukryte.", installButton),
		widget.NewCard("Aktualizacja lokalna", "Wgrywa aktualny USOS, uzupełnia strukturę DATA i synchronizuje katalog menu z obrazami, unattended oraz icon.png. Nie formatuje nośnika i nie usuwa danych użytkownika.", updateButton),
		widget.NewCard("Naprawa", "Wykrywa istniejący USOS i odtwarza pliki na ESP. DATA i WORK pozostają bez zmian.", repairButton),
		widget.NewCard("Deinstalacja", "Pokazuje tylko poprawnie rozpoznane nośniki USOS i przywraca je do jednej partycji exFAT.", uninstallButton),
	)
	return container.NewBorder(container.NewVBox(title, description, s.status, refreshButton), nil, nil, nil, cards)
}
