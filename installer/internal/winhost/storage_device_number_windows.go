//go:build windows

package winhost

import (
	"encoding/binary"
	"fmt"
	"strings"

	"golang.org/x/sys/windows"
)

type storageDeviceNumber struct {
	DeviceType      uint32
	DeviceNumber    uint32
	PartitionNumber uint32
}

func volumeStorageDeviceNumber(volumeName string) (storageDeviceNumber, error) {
	openName := strings.TrimSuffix(volumeName, `\`)
	namePtr, err := utf16Ptr(openName)
	if err != nil {
		return storageDeviceNumber{}, err
	}
	handle, err := windows.CreateFile(
		namePtr,
		0,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE,
		nil,
		windows.OPEN_EXISTING,
		0,
		0,
	)
	if err != nil {
		return storageDeviceNumber{}, fmt.Errorf("open volume %s for device number: %w", volumeName, err)
	}
	defer windows.CloseHandle(handle)

	buffer := make([]byte, 12)
	var returned uint32
	if err := windows.DeviceIoControl(
		handle,
		ioctlStorageGetDeviceNumber,
		nil,
		0,
		&buffer[0],
		uint32(len(buffer)),
		&returned,
		nil,
	); err != nil {
		return storageDeviceNumber{}, fmt.Errorf("IOCTL_STORAGE_GET_DEVICE_NUMBER for %s: %w", volumeName, err)
	}
	if returned < 12 {
		return storageDeviceNumber{}, fmt.Errorf("STORAGE_DEVICE_NUMBER for %s is too short: %d", volumeName, returned)
	}
	return storageDeviceNumber{
		DeviceType:      binary.LittleEndian.Uint32(buffer[0:4]),
		DeviceNumber:    binary.LittleEndian.Uint32(buffer[4:8]),
		PartitionNumber: binary.LittleEndian.Uint32(buffer[8:12]),
	}, nil
}
