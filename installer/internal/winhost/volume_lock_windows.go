//go:build windows

package winhost

import (
	"fmt"
	"strings"

	"golang.org/x/sys/windows"
)

type lockedVolume struct {
	name   string
	handle windows.Handle
}

func lockVolumesForDisk(diskNumber uint32) ([]lockedVolume, error) {
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

		volume, lockErr := lockAndDismountVolume(name)
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
		return lockedVolume{}, fmt.Errorf("open volume %s for lock: %w", volumeName, err)
	}

	if err := deviceIoControlNoBuffer(handle, fsctlLockVolume); err != nil {
		windows.CloseHandle(handle)
		return lockedVolume{}, fmt.Errorf("FSCTL_LOCK_VOLUME %s: %w", volumeName, err)
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
