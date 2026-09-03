package ui

import (
	"fmt"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
)

// InstalledCardScreen to ten sam układ Karty + szczegóły co DeviceScreen,
// ale lista zawiera wyłącznie nośniki z wykrytym USOS.
type InstalledCardScreen struct {
	title       string
	description string
	source      InstalledUSOSSource
	targets     []installed.Target
	rows        []domain.DeviceRow
	selected    int
	listBox     *fyne.Container
	detailsBox  *fyne.Container
	status      *widget.Label
	refresh     *widget.Button
	back        *widget.Button
	next        *widget.Button
	onSelected  func(installed.Target)
}

func NewInstalledCardScreen(title, description string, source InstalledUSOSSource, onBack func(), onSelected func(installed.Target)) *InstalledCardScreen {
	s := &InstalledCardScreen{title: title, description: description, source: source, selected: -1, onSelected: onSelected}
	s.status = widget.NewLabel("Wyszukiwanie poprawnych nośników USOS...")
	s.status.Wrapping = fyne.TextWrapWord
	s.listBox = container.NewVBox()
	s.detailsBox = container.NewVBox()
	s.refresh = widget.NewButton("Odśwież", s.Refresh)
	if onBack != nil {
		s.back = widget.NewButton("Wstecz", onBack)
	}
	s.next = widget.NewButton("Dalej", s.continueWithSelected)
	s.next.Importance = widget.HighImportance
	s.next.Disable()
	s.refreshDetails()
	s.Refresh()
	return s
}

func (s *InstalledCardScreen) Content() fyne.CanvasObject {
	heading := widget.NewLabelWithStyle(s.title, fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	description := widget.NewLabel(s.description)
	description.Wrapping = fyne.TextWrapWord
	buttons := container.NewHBox()
	if s.back != nil {
		buttons.Add(s.back)
	}
	buttons.Add(s.refresh)
	buttons.Add(s.next)
	listScroll := container.NewVScroll(s.listBox)
	listScroll.SetMinSize(fyne.NewSize(460, 380))
	split := container.NewHSplit(listScroll, container.NewVScroll(s.detailsBox))
	split.SetOffset(0.45)
	return container.NewBorder(
		container.NewVBox(heading, description, s.status),
		buttons,
		nil,
		nil,
		split,
	)
}

func (s *InstalledCardScreen) Refresh() {
	if s.refresh != nil {
		s.refresh.Disable()
	}
	if s.next != nil {
		s.next.Disable()
	}
	s.selected = -1
	if s.status != nil {
		s.status.Importance = widget.MediumImportance
		s.status.SetText("Wyszukiwanie poprawnych nośników USOS...")
	}
	go func() {
		targets, err := s.source.ListInstalledUSOS()
		fyne.Do(func() {
			if s.refresh != nil {
				s.refresh.Enable()
			}
			if err != nil {
				s.targets = nil
				s.rows = nil
				s.rebuildList()
				s.refreshDetails()
				if s.status != nil {
					s.status.Importance = widget.DangerImportance
					s.status.SetText("Błąd skanowania: " + err.Error())
				}
				return
			}
			s.targets = targets
			s.rows = make([]domain.DeviceRow, len(targets))
			for i, target := range targets {
				s.rows[i] = domain.BuildDeviceRow(target.Disk)
				s.rows[i].Selectable = true
				s.rows[i].Reason = ""
			}
			if s.status != nil {
				if len(targets) == 0 {
					s.status.Importance = widget.MediumImportance
					s.status.SetText("Nie wykryto zainstalowanego USOS. Podłącz nośnik z USOS albo wróć i użyj instalacji.")
				} else {
					s.status.Importance = widget.HighImportance
					s.status.SetText(installedFoundNote(len(targets)))
				}
			}
			s.rebuildList()
			s.refreshDetails()
		})
	}()
}

func (s *InstalledCardScreen) rebuildList() {
	if s.listBox == nil {
		return
	}
	s.listBox.Objects = nil
	if len(s.rows) == 0 {
		s.listBox.Add(widget.NewLabel("Brak nośników USOS do wyświetlenia."))
		s.listBox.Refresh()
		return
	}
	for i, row := range s.rows {
		idx := i
		label := fmt.Sprintf("%s - %s\nUSOS wykryty - gotowy do aktualizacji / naprawy / deinstalacji", row.Model, row.Capacity)
		btn := widget.NewButton(label, func() { s.selectTarget(idx) })
		btn.Alignment = widget.ButtonAlignLeading
		if s.selected == idx {
			btn.Importance = widget.HighImportance
		} else {
			btn.Importance = widget.MediumImportance
		}
		s.listBox.Add(btn)
	}
	s.listBox.Refresh()
}

func (s *InstalledCardScreen) selectTarget(idx int) {
	if idx < 0 || idx >= len(s.rows) {
		return
	}
	s.selected = idx
	if s.next != nil {
		s.next.Enable()
	}
	s.rebuildList()
	s.refreshDetails()
}

func (s *InstalledCardScreen) refreshDetails() {
	if s.detailsBox == nil {
		return
	}
	s.detailsBox.Objects = nil
	if s.selected < 0 || s.selected >= len(s.rows) || s.selected >= len(s.targets) {
		info := widget.NewLabel("Wybierz nośnik USOS z listy po lewej, aby zobaczyć szczegóły.")
		info.Wrapping = fyne.TextWrapWord
		s.detailsBox.Add(info)
		s.detailsBox.Refresh()
		return
	}
	row := s.rows[s.selected]
	title := widget.NewLabelWithStyle("Wybrano: "+row.Model, fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	title.Wrapping = fyne.TextWrapWord
	form := widget.NewForm(
		widget.NewFormItem("Pojemność", widget.NewLabel(row.Capacity)),
		widget.NewFormItem("Litery", widget.NewLabel(row.Letters)),
		widget.NewFormItem("Etykiety", widget.NewLabel(row.Labels)),
		widget.NewFormItem("System plików", widget.NewLabel(row.FileSystems)),
		widget.NewFormItem("Zajęte", widget.NewLabel(row.Used)),
		widget.NewFormItem("Stan", widget.NewLabel("USOS wykryty")),
	)
	rootTitle := widget.NewLabelWithStyle("Zawartość korzenia", fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	root := widget.NewLabel(row.RootContents)
	root.Wrapping = fyne.TextWrapWord
	s.detailsBox.Add(title)
	s.detailsBox.Add(form)
	s.detailsBox.Add(rootTitle)
	s.detailsBox.Add(root)
	s.detailsBox.Refresh()
}

func (s *InstalledCardScreen) continueWithSelected() {
	if s.selected < 0 || s.selected >= len(s.targets) || s.onSelected == nil {
		return
	}
	s.onSelected(s.targets[s.selected])
}
