package ui

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/i18n"
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
	title := widget.NewLabelWithStyle(i18n.T("installer.update.title"), fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	description := widget.NewLabel(i18n.T("installer.update.description"))
	description.Wrapping = fyne.TextWrapWord
	serial := s.target.Disk.DisplaySerial()
	if serial == "" {
		serial = "-"
	}
	identity := widget.NewLabel(i18n.T(
		"installer.common.target_identity",
		s.target.Disk.DisplayName(),
		s.target.Disk.Number,
		domain.FormatBytes(s.target.Disk.SizeBytes),
		serial,
	))
	identity.Wrapping = fyne.TextWrapWord

	payloadInfo, payloadErr := localupdate.PayloadBuildInfo()
	versionText := i18n.T("installer.update.media_version", s.target.BuildInfo.Display())
	if payloadErr != nil {
		versionText += "\n" + i18n.T("installer.update.installer_version_error")
	} else {
		versionText += "\n" + i18n.T("installer.update.installer_version", payloadInfo.Display())
	}
	versions := widget.NewLabel(versionText)
	versions.Wrapping = fyne.TextWrapWord

	back := widget.NewButton(i18n.T("installer.common.back"), func() {
		if s.onCancel != nil {
			s.onCancel()
		}
	})
	start := widget.NewButton(i18n.T("installer.mode.update.button"), nil)
	start.Importance = widget.HighImportance

	middle := container.NewVBox(identity, widget.NewSeparator(), versions)
	allowDowngrade := false
	if payloadErr != nil {
		warning := widget.NewLabel(i18n.T("installer.update.payload_unverified", payloadErr.Error()))
		warning.Wrapping = fyne.TextWrapWord
		middle.Add(widget.NewSeparator())
		middle.Add(warning)
		start.Disable()
	} else if localupdate.IsDowngrade(s.target.BuildInfo, payloadInfo) {
		warning := widget.NewLabelWithStyle(
			i18n.T("installer.update.downgrade_warning", s.target.BuildInfo.Display(), payloadInfo.Display()),
			fyne.TextAlignLeading,
			fyne.TextStyle{Bold: true},
		)
		warning.Wrapping = fyne.TextWrapWord
		confirm := widget.NewCheck(i18n.T("installer.update.downgrade_confirm"), func(checked bool) {
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
		start.SetText(i18n.T("installer.update.downgrade_button", payloadInfo.Display()))
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
