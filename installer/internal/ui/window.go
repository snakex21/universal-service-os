package ui

import (
	"fyne.io/fyne/v2"
	"github.com/snakex21/universal-service-os/installer/internal/i18n"
)

func ConfigureWindow(window fyne.Window, screen fyne.CanvasObject) {
	window.SetTitle(i18n.T("installer.window.title"))
	window.Resize(fyne.NewSize(1420, 760))
	window.SetContent(screen)
}
