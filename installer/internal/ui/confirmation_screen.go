package ui

import (
	"strings"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/i18n"
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
	s.confirm = widget.NewButton(i18n.T("installer.confirm.button"), s.confirmDestructive)
	s.confirm.Importance = widget.DangerImportance
	s.confirm.Disable()
	s.cancel = widget.NewButton(i18n.T("installer.common.cancel"), func() {
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
	title := widget.NewLabelWithStyle(i18n.T("installer.confirm.title"), fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	title.Importance = widget.DangerImportance
	warning := widget.NewLabel(i18n.T("installer.confirm.warning"))
	warning.Wrapping = fyne.TextWrapWord
	warning.Importance = widget.DangerImportance

	disk := widget.NewLabel(i18n.T(
		"installer.common.target_identity",
		s.model.DiskModel,
		s.model.DiskNumber,
		s.model.DiskCapacity,
		s.model.DiskSerial,
	))

	lossHeader := widget.NewLabelWithStyle(i18n.T("installer.confirm.losses_header"), fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	lossObjects := make([]fyne.CanvasObject, 0, len(s.model.Losses)+1)
	lossObjects = append(lossObjects, lossHeader)
	if len(s.model.Losses) == 0 {
		lossObjects = append(lossObjects, widget.NewLabel(i18n.T("installer.confirm.no_volumes")))
	}
	for _, item := range s.model.Losses {
		root := strings.TrimSpace(item.RootContent)
		if root == "" {
			root = "-"
		}
		label := widget.NewLabel(i18n.T(
			"installer.confirm.volume",
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

	prompt := widget.NewLabel(i18n.T("installer.confirm.prompt"))
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
