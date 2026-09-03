package ui

import (
	"fmt"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
)

type InstalledUSOSSource interface {
	ListInstalledUSOS() ([]installed.Target, error)
}

type InstalledDeviceScreen struct {
	title       string
	description string
	source      InstalledUSOSSource
	targets     []installed.Target
	rows        []domain.DeviceRow
	selected    int
	table       *widget.Table
	status      *widget.Label
	refresh     *widget.Button
	back        *widget.Button
	next        *widget.Button
	onSelected  func(installed.Target)
}

func NewInstalledDeviceScreen(title, description string, source InstalledUSOSSource, onBack func(), onSelected func(installed.Target)) *InstalledDeviceScreen {
	s := &InstalledDeviceScreen{title: title, description: description, source: source, selected: -1, onSelected: onSelected}
	s.status = widget.NewLabel("Wyszukiwanie poprawnych nośników USOS...")
	s.refresh = widget.NewButton("Odśwież", s.Refresh)
	s.back = widget.NewButton("Wstecz", onBack)
	s.next = widget.NewButton("Dalej", s.continueWithSelected)
	s.next.Importance = widget.HighImportance
	s.next.Disable()
	s.table = s.newTable()
	s.Refresh()
	return s
}

func (s *InstalledDeviceScreen) Content() fyne.CanvasObject {
	heading := widget.NewLabelWithStyle(s.title, fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	description := widget.NewLabel(s.description)
	description.Wrapping = fyne.TextWrapWord
	return container.NewBorder(
		container.NewVBox(heading, description, s.status),
		container.NewHBox(s.back, s.refresh, s.next),
		nil,
		nil,
		s.table,
	)
}

func (s *InstalledDeviceScreen) Refresh() {
	s.refresh.Disable()
	s.next.Disable()
	s.selected = -1
	s.status.Importance = widget.MediumImportance
	s.status.SetText("Wyszukiwanie poprawnych nośników USOS...")
	go func() {
		targets, err := s.source.ListInstalledUSOS()
		fyne.Do(func() {
			s.refresh.Enable()
			if err != nil {
				s.targets = nil
				s.rows = nil
				s.table.Refresh()
				s.status.Importance = widget.DangerImportance
				s.status.SetText("Błąd skanowania: " + err.Error())
				return
			}
			s.targets = targets
			s.rows = make([]domain.DeviceRow, len(targets))
			for i, target := range targets {
				s.rows[i] = domain.BuildDeviceRow(target.Disk)
				s.rows[i].Selectable = true
				s.rows[i].Reason = ""
			}
			s.table.UnselectAll()
			s.table.Refresh()
			s.status.SetText(installedFoundNote(len(targets)))
		})
	}()
}

func installedFoundNote(count int) string {
	if count <= 0 {
		return "Nie wykryto zainstalowanego USOS. Podłącz nośnik z USOS albo wróć i użyj instalacji."
	}
	if count == 1 {
		return "Wykryto USOS na 1 nośniku. Wybierz go z listy, aby kontynuować."
	}
	return fmt.Sprintf("Wykryto USOS na %d nośnikach. Wybierz go z listy, aby kontynuować.", count)
}

func (s *InstalledDeviceScreen) newTable() *widget.Table {
	table := widget.NewTable(
		func() (int, int) { return len(s.rows), len(deviceHeaders) },
		func() fyne.CanvasObject {
			label := widget.NewLabel("")
			label.Truncation = fyne.TextTruncateEllipsis
			return label
		},
		func(id widget.TableCellID, object fyne.CanvasObject) {
			object.(*widget.Label).SetText(deviceCell(s.rows[id.Row], id.Col))
		},
	)
	table.ShowHeaderRow = true
	table.CreateHeader = func() fyne.CanvasObject {
		return widget.NewLabelWithStyle("", fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	}
	table.UpdateHeader = func(id widget.TableCellID, object fyne.CanvasObject) {
		if id.Row == -1 && id.Col >= 0 && id.Col < len(deviceHeaders) {
			object.(*widget.Label).SetText(deviceHeaders[id.Col])
		}
	}
	table.SetColumnWidth(0, 220)
	table.SetColumnWidth(1, 90)
	table.SetColumnWidth(2, 100)
	table.SetColumnWidth(3, 160)
	table.SetColumnWidth(4, 120)
	table.SetColumnWidth(5, 90)
	table.SetColumnWidth(6, 360)
	table.SetColumnWidth(7, 220)
	table.OnSelected = func(id widget.TableCellID) {
		if id.Row < 0 || id.Row >= len(s.targets) {
			table.Unselect(id)
			return
		}
		s.selected = id.Row
		s.next.Enable()
	}
	table.OnUnselected = func(id widget.TableCellID) {
		if s.selected == id.Row {
			s.selected = -1
			s.next.Disable()
		}
	}
	return table
}

func (s *InstalledDeviceScreen) continueWithSelected() {
	if s.selected < 0 || s.selected >= len(s.targets) || s.onSelected == nil {
		return
	}
	s.onSelected(s.targets[s.selected])
}
