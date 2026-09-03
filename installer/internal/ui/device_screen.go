package ui

import (
	"fmt"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/snakex21/universal-service-os/installer/internal/domain"
)

type DiskSource interface {
	ListDisks() ([]domain.Disk, error)
}

type DeviceScreen struct {
	source      DiskSource
	installed   InstalledUSOSSource
	hiddenNote  *widget.Label
	hiddenCount int
	disks       []domain.Disk
	rows        []domain.DeviceRow
	selected    int
	listBox     *fyne.Container
	detailsBox  *fyne.Container
	status      *widget.Label
	refresh     *widget.Button
	back        *widget.Button
	next        *widget.Button
	onSelected  func(domain.Disk)
}

func NewDeviceScreen(source DiskSource, onSelected func(domain.Disk)) *DeviceScreen {
	return NewDeviceScreenWithBack(source, nil, onSelected)
}

var deviceHeaders = []string{
	"Model",
	"Pojemnosc",
	"Litery",
	"Etykiety",
	"System plikow",
	"Zajete",
	"Zawartosc korzenia",
	"Stan",
}

func NewDeviceScreenWithBack(source DiskSource, onBack func(), onSelected func(domain.Disk)) *DeviceScreen {
	s := &DeviceScreen{source: source, selected: -1, onSelected: onSelected}
	s.hiddenNote = widget.NewLabel("")
	s.hiddenNote.Wrapping = fyne.TextWrapWord
	s.status = widget.NewLabel("Wyszukiwanie urzadzen...")
	s.listBox = container.NewVBox()
	s.detailsBox = container.NewVBox()
	s.refresh = widget.NewButton("Odswiez", s.Refresh)
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

func NewDeviceScreenWithBackAndDetection(source DiskSource, installed InstalledUSOSSource, onBack func(), onSelected func(domain.Disk)) *DeviceScreen {
	s := &DeviceScreen{source: source, installed: installed, selected: -1, onSelected: onSelected}
	s.status = widget.NewLabel("Wyszukiwanie urzadzen...")
	s.listBox = container.NewVBox()
	s.detailsBox = container.NewVBox()
	s.hiddenNote = widget.NewLabel("")
	s.hiddenNote.Wrapping = fyne.TextWrapWord
	s.refresh = widget.NewButton("Odswiez", s.Refresh)
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

func (s *DeviceScreen) Content() fyne.CanvasObject {
	heading := widget.NewLabelWithStyle(
		"Wybierz nosnik dla Universal Service OS",
		fyne.TextAlignLeading,
		fyne.TextStyle{Bold: true},
	)
	description := widget.NewLabel("Kliknij caly wiersz dysku, aby go wybrac. Dyski odrzucone przez polityke bezpieczenstwa pozostaja widoczne i sa oznaczone powodem odrzucenia.")
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
		container.NewVBox(heading, description, s.hiddenNote, s.status),
		buttons,
		nil,
		nil,
		split,
	)
}

func (s *DeviceScreen) Refresh() {
	s.refresh.Disable()
	s.next.Disable()
	s.status.SetText("Wyszukiwanie urzadzen...")
	s.selected = -1
	go func() {
		disks, err := s.source.ListDisks()
		fyne.Do(func() {
			s.refresh.Enable()
			if err != nil {
				s.disks = nil
				s.rows = nil
				s.rebuildList()
				s.refreshDetails()
				s.status.Importance = widget.DangerImportance
				s.status.SetText("Blad skanowania: " + err.Error())
				return
			}
			if s.installed != nil {
				if targets, tErr := s.installed.ListInstalledUSOS(); tErr == nil && len(targets) > 0 {
					hide := map[uint32]string{}
					for _, t := range targets {
						hide[t.Disk.Number] = t.Disk.DisplayName()
					}
					kept := make([]domain.Disk, 0, len(disks))
					for _, d := range disks {
						if _, ok := hide[d.Number]; ok {
							continue
						}
						kept = append(kept, d)
					}
					s.hiddenCount = len(disks) - len(kept)
					disks = kept
				} else {
					s.hiddenCount = 0
				}
			}
			s.disks = disks
			s.rows = make([]domain.DeviceRow, len(disks))
			eligible := 0
			for i, disk := range disks {
				s.rows[i] = domain.BuildDeviceRow(disk)
				if disk.Eligible {
					eligible++
				}
			}
			s.status.Importance = widget.MediumImportance
			s.status.SetText(fmt.Sprintf("Znaleziono %d dyskow, %d spelnia polityke instalatora.", len(disks), eligible))
			if s.hiddenNote != nil {
				if s.hiddenCount > 0 {
					s.hiddenNote.Importance = widget.HighImportance
					s.hiddenNote.SetText(hiddenUSOSNote(s.hiddenCount))
				} else {
					s.hiddenNote.Importance = widget.MediumImportance
					s.hiddenNote.SetText("Nie wykryto zainstalowanego USOS.")
				}
				s.hiddenNote.Refresh()
			}
			s.rebuildList()
			s.refreshDetails()
		})
	}()
}

func hiddenUSOSNote(count int) string {
	if count == 1 {
		return "Wykryto USOS na 1 nosniku - ukryto go przed instalacja. Uzyj naprawy albo deinstalacji."
	}
	return fmt.Sprintf("Wykryto USOS na %d nosnikach - ukryto je przed instalacja. Uzyj naprawy albo deinstalacji.", count)
}

func (s *DeviceScreen) rebuildList() {
	if s.listBox == nil {
		return
	}
	s.listBox.Objects = nil
	if len(s.rows) == 0 {
		s.listBox.Add(widget.NewLabel("Brak dyskow do wyswietlenia."))
		s.listBox.Refresh()
		return
	}
	for i, row := range s.rows {
		idx := i
		state := "Gotowy do uzycia"
		if !row.Selectable {
			state = "Odrzucony: " + row.Reason
		}
		label := fmt.Sprintf("%s  -  %s\n%s", row.Model, row.Capacity, state)
		btn := widget.NewButton(label, func() { s.selectDisk(idx) })
		btn.Alignment = widget.ButtonAlignLeading
		if !row.Selectable {
			btn.Disable()
		} else if s.selected == idx {
			btn.Importance = widget.HighImportance
		} else {
			btn.Importance = widget.MediumImportance
		}
		s.listBox.Add(btn)
	}
	s.listBox.Refresh()
}

func (s *DeviceScreen) selectDisk(idx int) {
	if idx < 0 || idx >= len(s.rows) || !s.rows[idx].Selectable {
		return
	}
	s.selected = idx
	s.next.Enable()
	s.rebuildList()
	s.refreshDetails()
}

func (s *DeviceScreen) refreshDetails() {
	if s.detailsBox == nil {
		return
	}
	s.detailsBox.Objects = nil
	if s.selected < 0 || s.selected >= len(s.rows) {
		info := widget.NewLabel("Wybierz dysk z listy po lewej, aby zobaczyc szczegoly.")
		info.Wrapping = fyne.TextWrapWord
		s.detailsBox.Add(info)
		s.detailsBox.Refresh()
		return
	}
	row := s.rows[s.selected]
	title := widget.NewLabelWithStyle("Wybrano: "+row.Model, fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	title.Wrapping = fyne.TextWrapWord
	state := "Gotowy do uzycia"
	if !row.Selectable {
		state = "Odrzucony: " + row.Reason
	}
	form := widget.NewForm(
		widget.NewFormItem("Pojemnosc", widget.NewLabel(row.Capacity)),
		widget.NewFormItem("Litery", widget.NewLabel(row.Letters)),
		widget.NewFormItem("Etykiety", widget.NewLabel(row.Labels)),
		widget.NewFormItem("System plikow", widget.NewLabel(row.FileSystems)),
		widget.NewFormItem("Zajete", widget.NewLabel(row.Used)),
		widget.NewFormItem("Stan", widget.NewLabel(state)),
	)
	rootTitle := widget.NewLabelWithStyle("Zawartosc korzenia", fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	root := widget.NewLabel(row.RootContents)
	root.Wrapping = fyne.TextWrapWord
	s.detailsBox.Add(title)
	s.detailsBox.Add(form)
	s.detailsBox.Add(rootTitle)
	s.detailsBox.Add(root)
	s.detailsBox.Refresh()
}

func (s *DeviceScreen) continueWithSelected() {
	if s.selected < 0 || s.selected >= len(s.disks) || !s.disks[s.selected].Eligible || s.onSelected == nil {
		return
	}
	s.onSelected(s.disks[s.selected])
}

func deviceCell(row domain.DeviceRow, column int) string {
	switch column {
	case 0:
		return row.Model
	case 1:
		return row.Capacity
	case 2:
		return row.Letters
	case 3:
		return row.Labels
	case 4:
		return row.FileSystems
	case 5:
		return row.Used
	case 6:
		return row.RootContents
	case 7:
		if row.Selectable {
			return "Gotowy do uzycia"
		}
		return "Odrzucony: " + row.Reason
	default:
		return ""
	}
}
