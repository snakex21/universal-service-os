//go:build windows

package ui

import (
	"fmt"
	"os"
	"unsafe"

	"github.com/snakex21/universal-service-os/installer/internal/i18n"
)

// offersDrivers: "Open drivers folder" follows a successful install or update.
func (s *finalScreen) offersDrivers() bool {
	return (s.op == opInstall || s.op == opUpdate) && s.err == nil && s.report.OK()
}

// resolveDrivers finds the DATA drive letter of the finished disk in the
// background (a fresh, read-only drive listing: install assigns the letters).
func (s *finalScreen) resolveDrivers(disk uint32) {
	source := s.f.cfg.Installed
	go func() {
		targets, err := source.ListInstalledUSOS()
		if err != nil {
			return
		}
		path, ok := driversFolderForDisk(targets, disk)
		if !ok {
			return
		}
		s.f.w.post(func() {
			s.drivers = path
			s.f.w.invalidate()
		})
	}()
}

func (s *finalScreen) openDrivers() {
	if s.drivers == "" {
		return
	}
	open := s.f.cfg.OpenDriversFolder
	if open == nil {
		open = openFolderInExplorer
	}
	if err := open(s.drivers); err != nil {
		s.f.showToast(i18n.T("installer.final.open_drivers_failed", err.Error()))
	}
}

// openFolderInExplorer creates path when it is missing (only the folder
// itself, never anything inside it) and opens it in Explorer.
func openFolderInExplorer(path string) error {
	info, err := os.Stat(path)
	if os.IsNotExist(err) {
		err = os.MkdirAll(path, 0o755)
	} else if err == nil && !info.IsDir() {
		err = fmt.Errorf("%s is not a folder", path)
	}
	if err != nil {
		return err
	}
	const swShowNormal = 1
	r, _, callErr := procShellExecuteW.Call(0, uintptr(unsafe.Pointer(utf16Ptr("open"))), uintptr(unsafe.Pointer(utf16Ptr(path))), 0, 0, swShowNormal)
	if r <= 32 {
		return fmt.Errorf("ShellExecute %s: code %d: %v", path, r, callErr)
	}
	return nil
}
