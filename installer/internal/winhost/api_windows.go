//go:build windows

package winhost

import (
	"fmt"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	kernel32 = windows.NewLazySystemDLL("kernel32.dll")

	procQueryDosDeviceW                   = kernel32.NewProc("QueryDosDeviceW")
	procFindFirstVolumeW                  = kernel32.NewProc("FindFirstVolumeW")
	procFindNextVolumeW                   = kernel32.NewProc("FindNextVolumeW")
	procFindVolumeClose                   = kernel32.NewProc("FindVolumeClose")
	procGetVolumePathNamesForVolumeNameW  = kernel32.NewProc("GetVolumePathNamesForVolumeNameW")
	procGetVolumeInformationW             = kernel32.NewProc("GetVolumeInformationW")
	procGetDiskFreeSpaceExW               = kernel32.NewProc("GetDiskFreeSpaceExW")
	procGetWindowsDirectoryW              = kernel32.NewProc("GetWindowsDirectoryW")
	procGetVolumePathNameW                = kernel32.NewProc("GetVolumePathNameW")
	procGetVolumeNameForVolumeMountPointW = kernel32.NewProc("GetVolumeNameForVolumeMountPointW")
	procDeleteVolumeMountPointW           = kernel32.NewProc("DeleteVolumeMountPointW")
)

const (
	ioctlStorageQueryProperty              = 0x002D1400
	ioctlStorageGetDeviceNumber            = 0x002D1080
	ioctlDiskGetDriveGeometryEx            = 0x000700A0
	ioctlVolumeGetVolumeDiskExtents        = 0x00560000
	ioctlDiskGetDriveLayoutEx              = 0x00070050
	ioctlDiskSetDriveLayoutEx              = 0x0007C054
	ioctlDiskCreateDisk                    = 0x0007C058
	ioctlDiskDeleteDriveLayout             = 0x0007C100
	ioctlDiskUpdateProperties              = 0x00070140
	fsctlLockVolume                        = 0x00090018
	fsctlDismountVolume                    = 0x00090020
	storageDeviceProperty           uint32 = 0
	propertyStandardQuery           uint32 = 0
	fileDeviceDisk                  uint32 = 0x00000007
)

func boolResult(r1 uintptr, callErr error) error {
	if r1 != 0 {
		return nil
	}
	if callErr == nil || callErr == syscall.Errno(0) {
		return windows.ERROR_GEN_FAILURE
	}
	return callErr
}

func utf16Ptr(value string) (*uint16, error) {
	ptr, err := windows.UTF16PtrFromString(value)
	if err != nil {
		return nil, fmt.Errorf("invalid Windows path %q: %w", value, err)
	}
	return ptr, nil
}

func ptrToFirst[T any](values []T) uintptr {
	if len(values) == 0 {
		return 0
	}
	return uintptr(unsafe.Pointer(&values[0]))
}
