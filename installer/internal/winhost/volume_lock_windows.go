//go:build windows

package winhost

import (
	"errors"
	"fmt"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/volumelock"
	"golang.org/x/sys/windows"
)

type lockedVolume struct {
	name   string
	handle windows.Handle
}

// lockVolumesForDisk locks and dismounts every volume of the disk. A volume
// another program has open is retried (volumelock.DefaultDelays), then the
// user is asked through b.VolumeInUse; the holders are named by the Restart
// Manager. Dismount still happens only after the lock succeeded.
func (b Backend) lockVolumesForDisk(diskNumber uint32) ([]lockedVolume, error) {
	names, err := volumeNames()
	if err != nil {
		return nil, err
	}

	var locked []lockedVolume
	closeLocked := func() {
		for i := len(locked) - 1; i >= 0; i-- {
			windows.CloseHandle(locked[i].handle)
		}
	}

	for _, name := range names {
		extents, extentErr := volumeDiskExtents(name)
		if extentErr != nil {
			deviceNumber, numberErr := volumeStorageDeviceNumber(name)
			if numberErr != nil {
				closeLocked()
				return nil, fmt.Errorf("cannot classify unmappable volume %s before destructive operation: extents=%v; device-number=%w", name, extentErr, numberErr)
			}
			if deviceNumber.DeviceType != fileDeviceDisk || deviceNumber.DeviceNumber != diskNumber {
				continue
			}
			closeLocked()
			return nil, fmt.Errorf("target volume %s belongs to PhysicalDrive%d but disk extents cannot be read: %w", name, diskNumber, extentErr)
		}

		containsTarget := false
		for _, extent := range extents {
			if extent.DiskNumber == diskNumber {
				containsTarget = true
				break
			}
		}
		if !containsTarget {
			continue
		}
		for _, extent := range extents {
			if extent.DiskNumber != diskNumber {
				closeLocked()
				return nil, fmt.Errorf("volume %s spans PhysicalDrive%d and another disk", name, diskNumber)
			}
		}

		mount := ""
		if paths, pathErr := volumeMountPaths(name); pathErr == nil && len(paths) > 0 {
			mount = paths[0]
		}
		volumeName := name
		volume, lockErr := volumelock.Acquire(volumelock.Target[lockedVolume]{
			Volume:  volumeName,
			Mount:   mount,
			Lock:    func() (lockedVolume, error) { return lockAndDismountVolume(volumeName) },
			Holders: func() []string { return volumeHolders(mount) },
		}, volumelock.Options{Prompt: b.VolumeInUse, Log: b.VolumeLockLog})
		if lockErr != nil {
			closeLocked()
			return nil, lockErr
		}
		locked = append(locked, volume)
	}
	return locked, nil
}

func lockAndDismountVolume(volumeName string) (lockedVolume, error) {
	openName := strings.TrimSuffix(volumeName, `\`)
	namePtr, err := utf16Ptr(openName)
	if err != nil {
		return lockedVolume{}, err
	}
	handle, err := windows.CreateFile(
		namePtr,
		windows.GENERIC_READ|windows.GENERIC_WRITE,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE,
		nil,
		windows.OPEN_EXISTING,
		0,
		0,
	)
	if err != nil {
		return lockedVolume{}, fmt.Errorf("open volume %s for lock: %w", volumeName, busyError(err))
	}

	// The lock is the exclusive intent: it fails while any other handle is
	// open. Only after it succeeded is the dismount safe (no handle can be
	// invalidated), so a denied lock is never followed by a forced dismount.
	if err := deviceIoControlNoBuffer(handle, fsctlLockVolume); err != nil {
		windows.CloseHandle(handle)
		return lockedVolume{}, fmt.Errorf("FSCTL_LOCK_VOLUME %s: %w", volumeName, busyError(err))
	}
	if err := deviceIoControlNoBuffer(handle, fsctlDismountVolume); err != nil {
		windows.CloseHandle(handle)
		return lockedVolume{}, fmt.Errorf("FSCTL_DISMOUNT_VOLUME %s: %w", volumeName, err)
	}
	return lockedVolume{name: volumeName, handle: handle}, nil
}

func closeLockedVolumes(volumes []lockedVolume) error {
	var firstErr error
	for i := len(volumes) - 1; i >= 0; i-- {
		if err := windows.CloseHandle(volumes[i].handle); err != nil && firstErr == nil {
			firstErr = fmt.Errorf("close volume %s: %w", volumes[i].name, err)
		}
	}
	return firstErr
}

func deviceIoControlNoBuffer(handle windows.Handle, code uint32) error {
	var returned uint32
	return windows.DeviceIoControl(handle, code, nil, 0, nil, 0, &returned, nil)
}

// busyError marks the errors another program's open handle causes, so the
// lock is retried; any other failure stops at once.
func busyError(err error) error {
	if errors.Is(err, windows.ERROR_ACCESS_DENIED) || errors.Is(err, windows.ERROR_SHARING_VIOLATION) || errors.Is(err, windows.ERROR_LOCK_VIOLATION) {
		return fmt.Errorf("%w (%w)", err, volumelock.ErrBusy)
	}
	return err
}
