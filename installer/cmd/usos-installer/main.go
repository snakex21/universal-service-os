package main

import (
	"fmt"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/widget"
	"github.com/snakex21/universal-service-os/installer/internal/buildinfo"
	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/localupdate"
	"github.com/snakex21/universal-service-os/installer/internal/repair"
	"github.com/snakex21/universal-service-os/installer/internal/ui"
	"github.com/snakex21/universal-service-os/installer/internal/uninstall"
	"github.com/snakex21/universal-service-os/installer/internal/winhost"
)

func main() {
	// Preselect the host Windows UI language; the first screen lets the user change it.
	i18n.SetLanguage(i18n.SystemLanguage())
	application := app.NewWithID("com.snakex21.usos.installer")
	window := application.NewWindow(i18n.T("installer.window.title"))
	logger, err := install.NewOperationLogger()
	if err != nil {
		showStartupError(window, i18n.T("installer.startup.log_failed", err.Error()))
		window.ShowAndRun()
		return
	}
	defer logger.Close()
	linkedBuild := buildinfo.Current()
	_ = logger.WriteLine(fmt.Sprintf("INSTALLER BUILD id=%s epoch=%d source_sha256=%s", linkedBuild.Display(), linkedBuild.Epoch, linkedBuild.SourceSHA256))

	backend := winhost.Backend{}
	installEngine, err := install.NewEngine(backend, logger)
	if err != nil {
		showStartupError(window, i18n.T("installer.startup.install_engine_failed", err.Error()))
		window.ShowAndRun()
		return
	}
	updateEngine, err := localupdate.NewEngine(backend, logger)
	if err != nil {
		showStartupError(window, i18n.T("installer.startup.update_engine_failed", err.Error()))
		window.ShowAndRun()
		return
	}
	repairEngine, err := repair.NewEngine(backend, logger)
	if err != nil {
		showStartupError(window, i18n.T("installer.startup.repair_engine_failed", err.Error()))
		window.ShowAndRun()
		return
	}
	uninstallEngine, err := uninstall.NewEngine(backend, logger)
	if err != nil {
		showStartupError(window, i18n.T("installer.startup.uninstall_engine_failed", err.Error()))
		window.ShowAndRun()
		return
	}

	flow := ui.NewFlow(
		application,
		window,
		winhost.Enumerator{},
		winhost.InstalledUSOSSource{},
		installEngine,
		updateEngine,
		repairEngine,
		uninstallEngine,
	)
	flow.Start()
	window.ShowAndRun()
}

func showStartupError(window interface {
	SetContent(fyne.CanvasObject)
}, message string) {
	label := widget.NewLabel(message)
	label.Wrapping = 1
	window.SetContent(label)
}
