//go:build windows

package winhost

import (
	"encoding/binary"
	"fmt"
	"os"
	"sort"
	"strings"
	"syscall"
	"unsafe"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"golang.org/x/sys/windows"
)

type diskExtent struct {
	DiskNumber     uint32
	StartingOffset uint64
	ExtentLength   uint64
}

type volumeRecord struct {
	Info        domain.Volume
	DiskNumbers []uint32
	Extents     []diskExtent
}

func enumerateVolumes() ([]volumeRecord, error) {
	names, err := volumeNames()
	if err != nil {
		return nil, err
	}
	result := make([]volumeRecord, 0, len(names))
	for _, volumeName := range names {
		record, inspectErr := inspectVolume(volumeName)
		if inspectErr == nil {
			result = append(result, record)
		}
	}
	return result, nil
}

func inspectVolume(volumeName string) (volumeRecord, error) {
	extents, err := volumeDiskExtents(volumeName)
	if err != nil {
		return volumeRecord{}, err
	}
	disks := diskNumbersFromExtents(extents)
	mountPaths, _ := volumeMountPaths(volumeName)
	label, fileSystem, _ := volumeInformation(volumeName)
	totalBytes, usedBytes, _ := volumeUsage(volumeName)
	rootEntries, rootErr := rootEntries(volumeName)

	info := domain.Volume{
		GUIDPath:    volumeName,
		MountPaths:  mountPaths,
		Label:       label,
		FileSystem:  fileSystem,
		UsedBytes:   usedBytes,
		TotalBytes:  totalBytes,
		RootEntries: rootEntries,
	}
	if rootErr != nil {
		info.RootScanError = rootErr.Error()
	}
	return volumeRecord{Info: info, DiskNumbers: disks, Extents: extents}, nil
}

func volumeDiskNumbers(volumeName string) ([]uint32, error) {
	extents, err := volumeDiskExtents(volumeName)
	if err != nil {
		return nil, err
	}
	return diskNumbersFromExtents(extents), nil
}

func volumeDiskExtents(volumeName string) ([]diskExtent, error) {
	openName := strings.TrimSuffix(volumeName, `\`)
	namePtr, err := utf16Ptr(openName)
	if err != nil {
		return nil, err
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
		return nil, fmt.Errorf("open volume %s: %w", volumeName, err)
	}
	defer windows.CloseHandle(handle)

	bufferSize := 32
	for bufferSize <= 64*1024 {
		buffer := make([]byte, bufferSize)
		var returned uint32
		err = windows.DeviceIoControl(
			handle,
			ioctlVolumeGetVolumeDiskExtents,
			nil,
			0,
			&buffer[0],
			uint32(len(buffer)),
			&returned,
			nil,
		)
		if err == nil {
			return parseDiskExtents(buffer[:returned])
		}
		if err != windows.ERROR_MORE_DATA && err != windows.ERROR_INSUFFICIENT_BUFFER {
			return nil, fmt.Errorf("IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS for %s: %w", volumeName, err)
		}
		bufferSize *= 2
	}
	return nil, fmt.Errorf("volume extent list exceeds 64 KiB for %s", volumeName)
}

func parseDiskExtents(buffer []byte) ([]diskExtent, error) {
	if len(buffer) < 8 {
		return nil, fmt.Errorf("VOLUME_DISK_EXTENTS is too short: %d bytes", len(buffer))
	}
	count := int(binary.LittleEndian.Uint32(buffer[0:4]))
	const (
		firstExtentOffset = 8
		extentSize        = 24
	)
	required := firstExtentOffset + count*extentSize
	if count < 1 || required > len(buffer) {
		return nil, fmt.Errorf("invalid VOLUME_DISK_EXTENTS count=%d size=%d", count, len(buffer))
	}
	extents := make([]diskExtent, 0, count)
	for i := 0; i < count; i++ {
		offset := firstExtentOffset + i*extentSize
		extents = append(extents, diskExtent{
			DiskNumber:     binary.LittleEndian.Uint32(buffer[offset : offset+4]),
			StartingOffset: binary.LittleEndian.Uint64(buffer[offset+8 : offset+16]),
			ExtentLength:   binary.LittleEndian.Uint64(buffer[offset+16 : offset+24]),
		})
	}
	return extents, nil
}

func diskNumbersFromExtents(extents []diskExtent) []uint32 {
	numbers := make([]uint32, 0, len(extents))
	seen := make(map[uint32]struct{}, len(extents))
	for _, extent := range extents {
		if _, exists := seen[extent.DiskNumber]; exists {
			continue
		}
		seen[extent.DiskNumber] = struct{}{}
		numbers = append(numbers, extent.DiskNumber)
	}
	sort.Slice(numbers, func(i, j int) bool { return numbers[i] < numbers[j] })
	return numbers
}

func volumeMountPaths(volumeName string) ([]string, error) {
	namePtr, err := utf16Ptr(volumeName)
	if err != nil {
		return nil, err
	}
	bufferSize := uint32(512)
	for bufferSize <= 64*1024 {
		buffer := make([]uint16, bufferSize)
		var required uint32
		r1, _, callErr := procGetVolumePathNamesForVolumeNameW.Call(
			uintptr(unsafe.Pointer(namePtr)),
			ptrToFirst(buffer),
			uintptr(bufferSize),
			uintptr(unsafe.Pointer(&required)),
		)
		if r1 != 0 {
			return parseMultiSZ(buffer), nil
		}
		if callErr != windows.ERROR_MORE_DATA && callErr != windows.ERROR_INSUFFICIENT_BUFFER {
			return nil, callErr
		}
		if required > bufferSize {
			bufferSize = required
		} else {
			bufferSize *= 2
		}
	}
	return nil, fmt.Errorf("mount path list exceeds 64 Ki UTF-16 code units")
}

func volumeInformation(volumeName string) (string, string, error) {
	namePtr, err := utf16Ptr(volumeName)
	if err != nil {
		return "", "", err
	}
	label := make([]uint16, 256)
	fileSystem := make([]uint16, 64)
	r1, _, callErr := procGetVolumeInformationW.Call(
		uintptr(unsafe.Pointer(namePtr)),
		ptrToFirst(label),
		uintptr(len(label)),
		0,
		0,
		0,
		ptrToFirst(fileSystem),
		uintptr(len(fileSystem)),
	)
	if err := boolResult(r1, callErr); err != nil {
		return "", "", err
	}
	return windows.UTF16ToString(label), windows.UTF16ToString(fileSystem), nil
}

func volumeUsage(volumeName string) (uint64, uint64, error) {
	namePtr, err := utf16Ptr(volumeName)
	if err != nil {
		return 0, 0, err
	}
	var total uint64
	var free uint64
	r1, _, callErr := procGetDiskFreeSpaceExW.Call(
		uintptr(unsafe.Pointer(namePtr)),
		0,
		uintptr(unsafe.Pointer(&total)),
		uintptr(unsafe.Pointer(&free)),
	)
	if err := boolResult(r1, callErr); err != nil {
		return 0, 0, err
	}
	if free > total {
		return total, 0, nil
	}
	return total, total - free, nil
}

func rootEntries(volumeName string) ([]string, error) {
	entries, err := os.ReadDir(volumeName)
	if err != nil {
		return nil, err
	}
	result := make([]string, 0, len(entries))
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() {
			name += `\`
		}
		result = append(result, name)
	}
	sort.Strings(result)
	return result, nil
}

func systemDiskNumbers() (map[uint32]struct{}, error) {
	windowsDirectory, err := windowsDirectoryPath()
	if err != nil {
		return nil, err
	}
	volumePath, err := volumePathName(windowsDirectory)
	if err != nil {
		return nil, err
	}
	volumeName, err := volumeNameForMountPoint(volumePath)
	if err != nil {
		return nil, err
	}
	numbers, err := volumeDiskNumbers(volumeName)
	if err != nil {
		return nil, err
	}
	result := make(map[uint32]struct{}, len(numbers))
	for _, number := range numbers {
		result[number] = struct{}{}
	}
	return result, nil
}

func executableDiskNumbers() (map[uint32]struct{}, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, fmt.Errorf("locate running executable: %w", err)
	}
	volumePath, err := volumePathName(executable)
	if err != nil {
		return nil, fmt.Errorf("resolve running executable volume path: %w", err)
	}
	volumeName, err := volumeNameForMountPoint(volumePath)
	if err != nil {
		return nil, fmt.Errorf("resolve running executable volume name: %w", err)
	}
	numbers, err := volumeDiskNumbers(volumeName)
	if err != nil {
		return nil, fmt.Errorf("resolve running executable physical disk: %w", err)
	}
	result := make(map[uint32]struct{}, len(numbers))
	for _, number := range numbers {
		result[number] = struct{}{}
	}
	return result, nil
}

func refuseRunningFromTarget(diskNumber uint32) error {
	numbers, err := executableDiskNumbers()
	if err != nil {
		return err
	}
	if _, sameDisk := numbers[diskNumber]; sameDisk {
		return fmt.Errorf("refusing operation: USOS Installer is running from PhysicalDrive%d; copy the EXE to the computer disk and run it there", diskNumber)
	}
	return nil
}

func windowsDirectoryPath() (string, error) {
	buffer := make([]uint16, windows.MAX_PATH)
	r1, _, callErr := procGetWindowsDirectoryW.Call(ptrToFirst(buffer), uintptr(len(buffer)))
	if r1 == 0 {
		return "", callErr
	}
	if r1 >= uintptr(len(buffer)) {
		buffer = make([]uint16, r1+1)
		r1, _, callErr = procGetWindowsDirectoryW.Call(ptrToFirst(buffer), uintptr(len(buffer)))
		if r1 == 0 {
			return "", callErr
		}
	}
	return windows.UTF16ToString(buffer), nil
}

func volumePathName(path string) (string, error) {
	pathPtr, err := utf16Ptr(path)
	if err != nil {
		return "", err
	}
	buffer := make([]uint16, windows.MAX_PATH)
	r1, _, callErr := procGetVolumePathNameW.Call(
		uintptr(unsafe.Pointer(pathPtr)),
		ptrToFirst(buffer),
		uintptr(len(buffer)),
	)
	if err := boolResult(r1, callErr); err != nil {
		return "", err
	}
	return windows.UTF16ToString(buffer), nil
}

func volumeNameForMountPoint(mountPoint string) (string, error) {
	if !strings.HasSuffix(mountPoint, `\`) {
		mountPoint += `\`
	}
	mountPtr, err := utf16Ptr(mountPoint)
	if err != nil {
		return "", err
	}
	buffer := make([]uint16, 1024)
	r1, _, callErr := procGetVolumeNameForVolumeMountPointW.Call(
		uintptr(unsafe.Pointer(mountPtr)),
		ptrToFirst(buffer),
		uintptr(len(buffer)),
	)
	if err := boolResult(r1, callErr); err != nil {
		return "", err
	}
	return windows.UTF16ToString(buffer), nil
}

func isNoMoreFiles(err error) bool {
	return err == syscall.ERROR_NO_MORE_FILES
}
