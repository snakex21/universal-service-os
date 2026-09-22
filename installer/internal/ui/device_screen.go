package ui

import (
	"fmt"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/i18n"
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

func deviceHeaders() []string {
	return []string{
		i18n.T("installer.field.model"),
		i18n.T("installer.field.capacity"),
		i18n.T("installer.field.letters"),
		i18n.T("installer.field.labels"),
		i18n.T("installer.field.filesystem"),
		i18n.T("installer.field.used"),
		i18n.T("installer.field.root_contents"),
		i18n.T("installer.field.state"),
	}
}

func NewDeviceScreenWithBack(source DiskSource, onBack func(), onSelected func(domain.Disk)) *DeviceScreen {
	s := &DeviceScreen{source: source, selected: -1, onSelected: onSelected}
	s.hiddenNote = widget.NewLabel("")
	s.hiddenNote.Wrapping = fyne.TextWrapWord
	s.status = widget.NewLabel(i18n.T("installer.device.searching"))
	s.listBox = container.NewVBox()
	s.detailsBox = container.NewVBox()
	s.refresh = widget.NewButton(i18n.T("installer.common.refresh"), s.Refresh)
	if onBack != nil {
		s.back = widget.NewButton(i18n.T("installer.common.back"), onBack)
	}
	s.next = widget.NewButton(i18n.T("installer.common.next"), s.continueWithSelected)
	s.next.Importance = widget.HighImportance
	s.next.Disable()
	s.refreshDetails()
	s.Refresh()
	return s
}

func NewDeviceScreenWithBackAndDetection(source DiskSource, installed InstalledUSOSSource, onBack func(), onSelected func(domain.Disk)) *DeviceScreen {
	s := &DeviceScreen{source: source, installed: installed, selected: -1, onSelected: onSelected}
	s.status = widget.NewLabel(i18n.T("installer.device.searching"))
	s.listBox = container.NewVBox()
	s.detailsBox = container.NewVBox()
	s.hiddenNote = widget.NewLabel("")
	s.hiddenNote.Wrapping = fyne.TextWrapWord
	s.refresh = widget.NewButton(i18n.T("installer.common.refresh"), s.Refresh)
	if onBack != nil {
		s.back = widget.NewButton(i18n.T("installer.common.back"), onBack)
	}
	s.next = widget.NewButton(i18n.T("installer.common.next"), s.continueWithSelected)
	s.next.Importance = widget.HighImportance
	s.next.Disable()
	s.refreshDetails()
	s.Refresh()
	return s
}

func (s *DeviceScreen) Content() fyne.CanvasObject {
	heading := widget.NewLabelWithStyle(
		i18n.T("installer.device.heading"),
		fyne.TextAlignLeading,
		fyne.TextStyle{Bold: true},
	)
	description := widget.NewLabel(i18n.T("installer.device.description"))
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
	s.status.SetText(i18n.T("installer.device.searching"))
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
				s.status.SetText(i18n.T("installer.common.scan_error", err.Error()))
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
			s.status.SetText(i18n.T("installer.device.found", len(disks), eligible))
			if s.hiddenNote != nil {
				if s.hiddenCount > 0 {
					s.hiddenNote.Importance = widget.HighImportance
					s.hiddenNote.SetText(hiddenUSOSNote(s.hiddenCount))
				} else {
					s.hiddenNote.Importance = widget.MediumImportance
					s.hiddenNote.SetText(i18n.T("installer.device.none_installed"))
				}
				s.hiddenNote.Refresh()
			}
			s.rebuildList()
			s.refreshDetails()
		})
	}()
}

func hiddenUSOSNote(count int) string {
	return i18n.N("installer.device.hidden", count)
}

func (s *DeviceScreen) rebuildList() {
	if s.listBox == nil {
		return
	}
	s.listBox.Objects = nil
	if len(s.rows) == 0 {
		s.listBox.Add(widget.NewLabel(i18n.T("installer.device.empty")))
		s.listBox.Refresh()
		return
	}
	for i, row := range s.rows {
		idx := i
		state := deviceState(row)
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
		info := widget.NewLabel(i18n.T("installer.device.pick_hint"))
		info.Wrapping = fyne.TextWrapWord
		s.detailsBox.Add(info)
		s.detailsBox.Refresh()
		return
	}
	row := s.rows[s.selected]
	title := widget.NewLabelWithStyle(i18n.T("installer.common.selected", row.Model), fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	title.Wrapping = fyne.TextWrapWord
	state := deviceState(row)
	form := widget.NewForm(
		widget.NewFormItem(i18n.T("installer.field.capacity"), widget.NewLabel(row.Capacity)),
		widget.NewFormItem(i18n.T("installer.field.letters"), widget.NewLabel(row.Letters)),
		widget.NewFormItem(i18n.T("installer.field.labels"), widget.NewLabel(row.Labels)),
		widget.NewFormItem(i18n.T("installer.field.filesystem"), widget.NewLabel(row.FileSystems)),
		widget.NewFormItem(i18n.T("installer.field.used"), widget.NewLabel(row.Used)),
		widget.NewFormItem(i18n.T("installer.field.state"), widget.NewLabel(state)),
	)
	rootTitle := widget.NewLabelWithStyle(i18n.T("installer.field.root_contents"), fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
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
		return deviceState(row)
	default:
		return ""
	}
}

func deviceState(row domain.DeviceRow) string {
	if row.Selectable {
		return i18n.T("installer.device.ready")
	}
	return i18n.T("installer.device.rejected", row.Reason)
}
