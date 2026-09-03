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
	onRepair        func()
	onUninstall     func()
	installedSource InstalledUSOSSource
	status          *widget.Label
}

func NewModeScreen(onInstall, onRepair, onUninstall func()) *ModeScreen {
	return NewModeScreenWithDetection(onInstall, onRepair, onUninstall, nil)
}

func NewModeScreenWithDetection(onInstall, onRepair, onUninstall func(), installedSource InstalledUSOSSource) *ModeScreen {
	s := &ModeScreen{onInstall: onInstall, onRepair: onRepair, onUninstall: onUninstall, installedSource: installedSource}
	s.status = widget.NewLabel("Sprawdzanie, czy podlaczony jest nosnik z USOS...")
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
		s.status.SetText("Podlacz nosnik i wybierz operacje. Stan USOS sprawdzisz na ekranach naprawy i deinstalacji.")
		return
	}
	s.status.Importance = widget.MediumImportance
	s.status.SetText("Sprawdzanie, czy podlaczony jest nosnik z USOS...")
	s.status.Refresh()
	go func() {
		targets, err := s.installedSource.ListInstalledUSOS()
		fyne.Do(func() {
			if err != nil {
				s.status.Importance = widget.DangerImportance
				s.status.SetText("Nie udalo sie sprawdzic zainstalowanego USOS: " + err.Error())
				s.status.Refresh()
				return
			}
			if len(targets) == 0 {
				s.status.Importance = widget.MediumImportance
				s.status.SetText("Nie wykryto zainstalowanego USOS. Instalacja utworzy nowy nosnik.")
			} else {
				s.status.Importance = widget.HighImportance
				names := make([]string, 0, len(targets))
				for _, t := range targets {
					names = append(names, t.Disk.DisplayName())
				}
				label := "Wykryto USOS na: " + strings.Join(names, ", ")
				if len(targets) == 1 {
					label += ". Ten nosnik jest ukryty przed instalacja - uzyj naprawy albo deinstalacji."
				} else if len(targets) >= 2 && len(targets) <= 4 {
					label += fmt.Sprintf(". Te %d nosniki sa ukryte przed instalacja - uzyj naprawy albo deinstalacji.", len(targets))
				} else {
					label += fmt.Sprintf(". Tych %d nosnikow jest ukrytych przed instalacja - uzyj naprawy albo deinstalacji.", len(targets))
				}
				s.status.SetText(label)
			}
			s.status.Refresh()
		})
	}()
}

func (s *ModeScreen) Content() fyne.CanvasObject {
	title := widget.NewLabelWithStyle("Universal Service OS Installer", fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	description := widget.NewLabel("Wybierz operacje. Instalacja przygotowuje nowy nosnik, naprawa odtwarza wylacznie ESP istniejacego USOS, a deinstalacja przywraca nosnik do jednej zwyklej partycji exFAT.")
	description.Wrapping = fyne.TextWrapWord

	installButton := widget.NewButton("Zainstaluj USOS", s.onInstall)
	installButton.Importance = widget.HighImportance
	repairButton := widget.NewButton("Napraw USOS", s.onRepair)
	uninstallButton := widget.NewButton("Odinstaluj USOS", s.onUninstall)
	uninstallButton.Importance = widget.DangerImportance
	refreshButton := widget.NewButton("Odswiez stan USOS", s.Refresh)

	cards := container.NewGridWithColumns(1,
		widget.NewCard("Instalacja", "Tworzy ESP, DATA i WORK. Wszystkie dane na wybranym nosniku zostana usuniete. Nosniki z wykrytym USOS sa tu ukryte.", installButton),
		widget.NewCard("Naprawa", "Wykrywa istniejacy USOS i odtwarza pliki na ESP. DATA i WORK pozostaja bez zmian.", repairButton),
		widget.NewCard("Deinstalacja", "Pokazuje tylko poprawnie rozpoznane nosniki USOS i przywraca je do jednej partycji exFAT.", uninstallButton),
	)
	return container.NewBorder(container.NewVBox(title, description, s.status, refreshButton), nil, nil, nil, cards)
}
