package ui

import (
	"strings"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/snakex21/universal-service-os/installer/internal/i18n"
)

type ModeScreen struct {
	onInstall       func()
	onUpdate        func()
	onRepair        func()
	onUninstall     func()
	installedSource InstalledUSOSSource
	status          *widget.Label
	onLanguage      func()
}

func NewModeScreen(onInstall, onUpdate, onRepair, onUninstall func()) *ModeScreen {
	return NewModeScreenWithDetection(onInstall, onUpdate, onRepair, onUninstall, nil)
}

func NewModeScreenWithDetection(onInstall, onUpdate, onRepair, onUninstall func(), installedSource InstalledUSOSSource) *ModeScreen {
	s := &ModeScreen{onInstall: onInstall, onUpdate: onUpdate, onRepair: onRepair, onUninstall: onUninstall, installedSource: installedSource}
	s.status = widget.NewLabel(i18n.T("installer.mode.checking"))
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
		s.status.SetText(i18n.T("installer.mode.no_source"))
		return
	}
	s.status.Importance = widget.MediumImportance
	s.status.SetText(i18n.T("installer.mode.checking"))
	s.status.Refresh()
	go func() {
		targets, err := s.installedSource.ListInstalledUSOS()
		fyne.Do(func() {
			if err != nil {
				s.status.Importance = widget.DangerImportance
				s.status.SetText(i18n.T("installer.mode.check_failed", err.Error()))
				s.status.Refresh()
				return
			}
			if len(targets) == 0 {
				s.status.Importance = widget.MediumImportance
				s.status.SetText(i18n.T("installer.mode.none_detected"))
			} else {
				s.status.Importance = widget.HighImportance
				names := make([]string, 0, len(targets))
				for _, t := range targets {
					names = append(names, t.Disk.DisplayName())
				}
				label := i18n.T("installer.mode.detected", strings.Join(names, ", ")) + i18n.N("installer.mode.detected_hidden", len(targets))
				s.status.SetText(label)
			}
			s.status.Refresh()
		})
	}()
}

func (s *ModeScreen) Content() fyne.CanvasObject {
	title := widget.NewLabelWithStyle(i18n.T("installer.window.title"), fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	description := widget.NewLabel(i18n.T("installer.mode.description"))
	description.Wrapping = fyne.TextWrapWord

	installButton := widget.NewButton(i18n.T("installer.mode.install.button"), s.onInstall)
	installButton.Importance = widget.HighImportance
	updateButton := widget.NewButton(i18n.T("installer.mode.update.button"), s.onUpdate)
	updateButton.Importance = widget.HighImportance
	repairButton := widget.NewButton(i18n.T("installer.mode.repair.button"), s.onRepair)
	uninstallButton := widget.NewButton(i18n.T("installer.mode.uninstall.button"), s.onUninstall)
	uninstallButton.Importance = widget.DangerImportance
	refreshButton := widget.NewButton(i18n.T("installer.mode.refresh"), s.Refresh)

	cards := container.NewGridWithColumns(1,
		widget.NewCard(i18n.T("installer.mode.install.title"), i18n.T("installer.mode.install.description"), installButton),
		widget.NewCard(i18n.T("installer.mode.update.title"), i18n.T("installer.mode.update.description"), updateButton),
		widget.NewCard(i18n.T("installer.mode.repair.title"), i18n.T("installer.mode.repair.description"), repairButton),
		widget.NewCard(i18n.T("installer.mode.uninstall.title"), i18n.T("installer.mode.uninstall.description"), uninstallButton),
	)
	top := container.NewHBox(refreshButton)
	if s.onLanguage != nil {
		top.Add(widget.NewButton(i18n.T("installer.language.change", languageName(i18n.Current())), s.onLanguage))
	}
	return container.NewBorder(container.NewVBox(title, description, s.status, top), nil, nil, nil, cards)
}
