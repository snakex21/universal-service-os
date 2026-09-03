package ui

import (
	"fyne.io/fyne/v2"
)

func ConfigureWindow(window fyne.Window, screen fyne.CanvasObject) {
	window.SetTitle("Universal Service OS Installer")
	window.Resize(fyne.NewSize(1420, 760))
	window.SetContent(screen)
}
