//go:build windows

package winhost

import (
	"fmt"
	"time"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/layout"
	"golang.org/x/sys/windows"
)

func createGPT(handle windows.Handle, ids gptIDs) (gptHeader, error) {
	buffer, err := buildCreateDiskBuffer(ids.Disk)
	if err != nil {
		return gptHeader{}, err
	}
	if err := deviceIoControlInput(handle, ioctlDiskCreateDisk, buffer); err != nil {
		return gptHeader{}, fmt.Errorf("IOCTL_DISK_CREATE_DISK: %w", err)
	}
	if err := deviceIoControlNoBuffer(handle, ioctlDiskUpdateProperties); err != nil {
		return gptHeader{}, fmt.Errorf("IOCTL_DISK_UPDATE_PROPERTIES after CREATE_DISK: %w", err)
	}
	return waitForGPTHeader(handle, ids.Disk, 5*time.Second)
}

func setGPTLayout(handle windows.Handle, plan layout.Plan, header gptHeader, ids gptIDs) (install.MediaLayout, error) {
	buffer, err := buildDriveLayoutBuffer(plan, header, ids)
	if err != nil {
		return install.MediaLayout{}, err
	}
	if err := deviceIoControlInput(handle, ioctlDiskSetDriveLayoutEx, buffer); err != nil {
		return install.MediaLayout{}, fmt.Errorf("IOCTL_DISK_SET_DRIVE_LAYOUT_EX: %w", err)
	}
	if err := deviceIoControlNoBuffer(handle, ioctlDiskUpdateProperties); err != nil {
		return install.MediaLayout{}, fmt.Errorf("IOCTL_DISK_UPDATE_PROPERTIES after SET_DRIVE_LAYOUT_EX: %w", err)
	}

	readBack, err := readDriveLayout(handle)
	if err != nil {
		return install.MediaLayout{}, fmt.Errorf("read back GPT layout: %w", err)
	}
	return verifyReadBack(plan, ids, readBack)
}

func readDriveLayout(handle windows.Handle) (parsedLayout, error) {
	bufferSize := 16 * 1024
	for bufferSize <= 1024*1024 {
		buffer := make([]byte, bufferSize)
		var returned uint32
		err := windows.DeviceIoControl(
			handle,
			ioctlDiskGetDriveLayoutEx,
			nil,
			0,
			&buffer[0],
			uint32(len(buffer)),
			&returned,
			nil,
		)
		if err == nil {
			return parseDriveLayout(buffer[:returned])
		}
		if err != windows.ERROR_INSUFFICIENT_BUFFER && err != windows.ERROR_MORE_DATA {
			return parsedLayout{}, err
		}
		bufferSize *= 2
	}
	return parsedLayout{}, fmt.Errorf("DRIVE_LAYOUT_INFORMATION_EX exceeds 1 MiB")
}

func waitForGPTHeader(handle windows.Handle, expectedDiskID windows.GUID, timeout time.Duration) (gptHeader, error) {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for {
		layoutInfo, err := readDriveLayout(handle)
		if err == nil {
			if guidString(layoutInfo.Header.DiskID) == guidString(expectedDiskID) &&
				layoutInfo.Header.StartingUsableOffset > 0 &&
				layoutInfo.Header.UsableLength > 0 {
				return layoutInfo.Header, nil
			}
			lastErr = fmt.Errorf("GPT header does not match requested disk GUID or usable range is empty")
		} else {
			lastErr = err
		}
		if !time.Now().Before(deadline) {
			return gptHeader{}, fmt.Errorf("GPT header did not become ready: %w", lastErr)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func deviceIoControlInput(handle windows.Handle, code uint32, input []byte) error {
	if len(input) == 0 {
		return fmt.Errorf("empty DeviceIoControl input")
	}
	var returned uint32
	return windows.DeviceIoControl(handle, code, &input[0], uint32(len(input)), nil, 0, &returned, nil)
}
