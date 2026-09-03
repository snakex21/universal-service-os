//go:build windows

package winhost

import (
	"encoding/binary"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"unsafe"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"golang.org/x/sys/windows"
)

type storagePropertyQuery struct {
	PropertyID           uint32
	QueryType            uint32
	AdditionalParameters [1]byte
	Padding              [3]byte
}

func physicalDiskNumbers() ([]uint32, error) {
	bufferSize := uint32(4096)
	for {
		buffer := make([]uint16, bufferSize)
		r1, _, callErr := procQueryDosDeviceW.Call(0, ptrToFirst(buffer), uintptr(bufferSize))
		if r1 != 0 {
			names := parseMultiSZ(buffer[:r1])
			var numbers []uint32
			for _, name := range names {
				if !strings.HasPrefix(name, "PhysicalDrive") {
					continue
				}
				n, err := strconv.ParseUint(strings.TrimPrefix(name, "PhysicalDrive"), 10, 32)
				if err == nil {
					numbers = append(numbers, uint32(n))
				}
			}
			sort.Slice(numbers, func(i, j int) bool { return numbers[i] < numbers[j] })
			return numbers, nil
		}
		if callErr != windows.ERROR_INSUFFICIENT_BUFFER {
			return nil, fmt.Errorf("QueryDosDeviceW: %w", callErr)
		}
		bufferSize *= 2
		if bufferSize > 1<<20 {
			return nil, fmt.Errorf("QueryDosDeviceW device-name list exceeds 1 Mi UTF-16 code units")
		}
	}
}

func inspectPhysicalDisk(number uint32) (domain.Disk, error) {
	path := fmt.Sprintf(`\\.\PhysicalDrive%d`, number)
	pathPtr, err := utf16Ptr(path)
	if err != nil {
		return domain.Disk{}, err
	}
	handle, err := windows.CreateFile(
		pathPtr,
		0,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE,
		nil,
		windows.OPEN_EXISTING,
		0,
		0,
	)
	if err != nil {
		return domain.Disk{}, fmt.Errorf("open %s: %w", path, err)
	}
	defer windows.CloseHandle(handle)

	return inspectPhysicalDiskHandle(number, handle)
}

func inspectPhysicalDiskHandle(number uint32, handle windows.Handle) (domain.Disk, error) {
	descriptor, err := storageDescriptor(handle)
	if err != nil {
		return domain.Disk{}, err
	}
	sizeBytes, sectorBytes, err := diskGeometry(handle)
	if err != nil {
		return domain.Disk{}, err
	}

	vendor := descriptorString(descriptor, 12)
	product := descriptorString(descriptor, 16)
	serial := descriptorString(descriptor, 24)
	model := strings.TrimSpace(strings.Join(nonEmpty(vendor, product), " "))

	return domain.Disk{
		Number:      number,
		Model:       model,
		Vendor:      vendor,
		Product:     product,
		Serial:      serial,
		SizeBytes:   sizeBytes,
		SectorBytes: sectorBytes,
		Removable:   len(descriptor) > 10 && descriptor[10] != 0,
	}, nil
}

func storageDescriptor(handle windows.Handle) ([]byte, error) {
	query := storagePropertyQuery{
		PropertyID: storageDeviceProperty,
		QueryType:  propertyStandardQuery,
	}
	buffer := make([]byte, 4096)
	var returned uint32
	err := windows.DeviceIoControl(
		handle,
		ioctlStorageQueryProperty,
		(*byte)(unsafe.Pointer(&query)),
		uint32(unsafe.Sizeof(query)),
		&buffer[0],
		uint32(len(buffer)),
		&returned,
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("IOCTL_STORAGE_QUERY_PROPERTY: %w", err)
	}
	if returned < 36 {
		return nil, fmt.Errorf("storage descriptor is too short: %d bytes", returned)
	}
	return buffer[:returned], nil
}

func diskGeometry(handle windows.Handle) (uint64, uint32, error) {
	buffer := make([]byte, 256)
	var returned uint32
	err := windows.DeviceIoControl(
		handle,
		ioctlDiskGetDriveGeometryEx,
		nil,
		0,
		&buffer[0],
		uint32(len(buffer)),
		&returned,
		nil,
	)
	if err != nil {
		return 0, 0, fmt.Errorf("IOCTL_DISK_GET_DRIVE_GEOMETRY_EX: %w", err)
	}
	if returned < 32 {
		return 0, 0, fmt.Errorf("DISK_GEOMETRY_EX is too short: %d bytes", returned)
	}
	sectorBytes := binary.LittleEndian.Uint32(buffer[20:24])
	if sectorBytes == 0 {
		return 0, 0, fmt.Errorf("DISK_GEOMETRY_EX reports zero bytes per sector")
	}
	return binary.LittleEndian.Uint64(buffer[24:32]), sectorBytes, nil
}

func descriptorString(descriptor []byte, offsetField int) string {
	if offsetField+4 > len(descriptor) {
		return ""
	}
	offset := int(binary.LittleEndian.Uint32(descriptor[offsetField : offsetField+4]))
	if offset <= 0 || offset >= len(descriptor) {
		return ""
	}
	end := offset
	for end < len(descriptor) && descriptor[end] != 0 {
		end++
	}
	return strings.TrimSpace(string(descriptor[offset:end]))
}

func nonEmpty(values ...string) []string {
	result := make([]string, 0, len(values))
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			result = append(result, strings.TrimSpace(value))
		}
	}
	return result
}

func parseMultiSZ(buffer []uint16) []string {
	var result []string
	start := 0
	for index, value := range buffer {
		if value != 0 {
			continue
		}
		if index == start {
			break
		}
		result = append(result, windows.UTF16ToString(buffer[start:index]))
		start = index + 1
	}
	return result
}
