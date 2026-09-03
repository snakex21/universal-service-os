package ui

import (
	"fyne.io/fyne/v2"
	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
	"github.com/snakex21/universal-service-os/installer/internal/repair"
	"github.com/snakex21/universal-service-os/installer/internal/uninstall"
)

type Flow struct {
	app             fyne.App
	window          fyne.Window
	installSource   DiskSource
	installedSource InstalledUSOSSource
	installEngine   *install.Engine
	repairEngine    *repair.Engine
	uninstallEngine *uninstall.Engine
	busy            bool
}

func NewFlow(
	application fyne.App,
	window fyne.Window,
	installSource DiskSource,
	installedSource InstalledUSOSSource,
	installEngine *install.Engine,
	repairEngine *repair.Engine,
	uninstallEngine *uninstall.Engine,
) *Flow {
	flow := &Flow{
		app:             application,
		window:          window,
		installSource:   installSource,
		installedSource: installedSource,
		installEngine:   installEngine,
		repairEngine:    repairEngine,
		uninstallEngine: uninstallEngine,
	}
	window.SetCloseIntercept(flow.closeRequested)
	return flow
}

func (f *Flow) Start() { f.showModes() }

func (f *Flow) showModes() {
	f.busy = false
	screen := NewModeScreenWithDetection(f.showInstallDevices, f.showRepairDevices, f.showUninstallDevices, f.installedSource)
	ConfigureWindow(f.window, screen.Content())
}

func (f *Flow) showInstallDevices() {
	f.busy = false
	screen := NewDeviceScreenWithBackAndDetection(f.installSource, f.installedSource, f.showModes, f.showInstallConfirmation)
	ConfigureWindow(f.window, screen.Content())
}

func (f *Flow) showInstallConfirmation(disk domain.Disk) {
	screen := NewConfirmationScreen(disk, f.showInstallDevices, func() { f.showInstallProgress(disk) })
	ConfigureWindow(f.window, screen.Content())
}

func (f *Flow) showInstallProgress(disk domain.Disk) {
	f.busy = true
	events := f.installEngine.RunAsync(disk)
	screen := NewProgressScreen(events, func(report *install.VerificationReport, err error) {
		f.busy = false
		finalScreen := NewOperationFinalScreen("Instalacja", report, err, f.showModes)
		ConfigureWindow(f.window, finalScreen.Content())
	})
	ConfigureWindow(f.window, screen.Content())
}

func (f *Flow) showRepairDevices() {
	f.busy = false
	screen := NewInstalledCardScreen(
		"Wybierz nosnik USOS do naprawy",
		"Lista zawiera wylacznie nosniki z wykrytym USOS. Wybierz nosnik, aby kontynuowac.",
		f.installedSource,
		f.showModes,
		f.showRepairConfirmation,
	)
	ConfigureWindow(f.window, screen.Content())
}

func (f *Flow) showRepairConfirmation(target installed.Target) {
	screen := NewRepairConfirmationScreen(target, f.showRepairDevices, func() { f.showRepairProgress(target) })
	ConfigureWindow(f.window, screen.Content())
}

func (f *Flow) showRepairProgress(target installed.Target) {
	f.busy = true
	events := f.repairEngine.RunAsync(target)
	screen := NewRepairProgressScreen(events, func(report *install.VerificationReport, err error) {
		f.busy = false
		finalScreen := NewOperationFinalScreen("Naprawa", report, err, f.showModes)
		ConfigureWindow(f.window, finalScreen.Content())
	})
	ConfigureWindow(f.window, screen.Content())
}

func (f *Flow) showUninstallDevices() {
	f.busy = false
	screen := NewInstalledCardScreen(
		"Wybierz nosnik USOS do deinstalacji",
		"Lista zawiera wylacznie nosniki z wykrytym USOS. Zwykle pendrive bez USOS nie pojawiaja sie na tej liscie.",
		f.installedSource,
		f.showModes,
		f.showUninstallConfirmation,
	)
	ConfigureWindow(f.window, screen.Content())
}

func (f *Flow) showUninstallConfirmation(target installed.Target) {
	screen := NewUninstallConfirmationScreen(target, f.showUninstallDevices, func() { f.showUninstallProgress(target) })
	ConfigureWindow(f.window, screen.Content())
}

func (f *Flow) showUninstallProgress(target installed.Target) {
	f.busy = true
	events := f.uninstallEngine.RunAsync(target)
	screen := NewUninstallProgressScreen(events, func(report *install.VerificationReport, err error) {
		f.busy = false
		finalScreen := NewOperationFinalScreen("Deinstalacja", report, err, f.showModes)
		ConfigureWindow(f.window, finalScreen.Content())
	})
	ConfigureWindow(f.window, screen.Content())
}

func (f *Flow) closeRequested() {
	if f.busy {
		return
	}
	f.window.SetCloseIntercept(nil)
	f.app.Quit()
}
