//go:build windows

package winhost

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/workboot"
	"golang.org/x/sys/windows"
)

// MigrateWORKBootPath moves a WORK \EFI\BOOT boot chain written by older
// preparation builds to \EFI\USOS-WORK, so the firmware stops listing WORK as
// a removable-media boot option. WORK is accessed through its volume GUID path
// (no drive letter needed); the caller has already revalidated its identity.
func (Backend) MigrateWORKBootPath(media install.MediaLayout) (workboot.Migration, error) {
	root := strings.TrimSpace(media.WORK.VolumePath)
	if root == "" {
		return workboot.Migration{}, fmt.Errorf("WORK volume path is empty")
	}
	if err := refuseRunningFromTarget(media.DiskNumber); err != nil {
		return workboot.Migration{}, err
	}
	if info, err := os.Stat(filepath.Join(root, ".usos-work")); err != nil || !info.Mode().IsRegular() {
		return workboot.Migration{}, fmt.Errorf("refusing WORK boot path migration: .usos-work marker is missing: %v", err)
	}
	migration, err := workboot.Migrate(root)
	if err != nil {
		return migration, err
	}
	if migration.Action != workboot.ActionNone {
		if err := flushVolume(root); err != nil {
			return migration, fmt.Errorf("flush WORK after boot path migration: %w", err)
		}
	}
	left, err := workboot.RemovableEntries(root)
	if err != nil {
		return migration, fmt.Errorf("re-read WORK EFI/BOOT: %w", err)
	}
	if len(left) != 0 {
		return migration, fmt.Errorf("removable-media entries still on WORK: %v", left)
	}
	return migration, nil
}

// flushVolume flushes a mounted volume given as \?\Volume{...}\ or X:\.
func flushVolume(root string) error {
	device := strings.TrimRight(root, `\`)
	if len(device) == 2 && device[1] == ':' {
		device = `\.\` + device
	}
	ptr, err := windows.UTF16PtrFromString(device)
	if err != nil {
		return err
	}
	handle, err := windows.CreateFile(ptr, windows.GENERIC_READ|windows.GENERIC_WRITE, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, 0, 0)
	if err != nil {
		return fmt.Errorf("open %s: %w", device, err)
	}
	defer windows.CloseHandle(handle)
	return windows.FlushFileBuffers(handle)
}
