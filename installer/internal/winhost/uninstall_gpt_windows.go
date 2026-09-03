//go:build windows

package winhost

import (
	"encoding/binary"
	"fmt"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/layout"
	"github.com/snakex21/universal-service-os/installer/internal/uninstall"
	"golang.org/x/sys/windows"
)

func createSingleDataLayout(handle windows.Handle, diskNumber uint32, sectorBytes uint32) (uninstall.MediaLayout, error) {
	diskID, err := randomGUID()
	if err != nil {
		return uninstall.MediaLayout{}, fmt.Errorf("generate uninstall disk GUID: %w", err)
	}
	partID, err := randomGUID()
	if err != nil {
		return uninstall.MediaLayout{}, fmt.Errorf("generate uninstall partition GUID: %w", err)
	}
	header, err := createGPT(handle, gptIDs{Disk: diskID})
	if err != nil {
		return uninstall.MediaLayout{}, err
	}
	start := alignUp64(header.StartingUsableOffset, layout.AlignmentBytes)
	usableEnd := header.StartingUsableOffset + header.UsableLength
	end := alignDown64(usableEnd, uint64(sectorBytes))
	if start >= end {
		return uninstall.MediaLayout{}, fmt.Errorf("GPT usable range is too small for a data partition")
	}
	part := install.PartitionRef{
		Number:     1,
		StartBytes: start,
		SizeBytes:  end - start,
		PartUUID:   guidString(partID),
	}
	buffer, err := buildSingleDataLayoutBuffer(header, diskID, partID, part)
	if err != nil {
		return uninstall.MediaLayout{}, err
	}
	if err := deviceIoControlInput(handle, ioctlDiskSetDriveLayoutEx, buffer); err != nil {
		return uninstall.MediaLayout{}, fmt.Errorf("IOCTL_DISK_SET_DRIVE_LAYOUT_EX uninstall: %w", err)
	}
	if err := deviceIoControlNoBuffer(handle, ioctlDiskUpdateProperties); err != nil {
		return uninstall.MediaLayout{}, fmt.Errorf("IOCTL_DISK_UPDATE_PROPERTIES after uninstall layout: %w", err)
	}
	actual, err := readDriveLayout(handle)
	if err != nil {
		return uninstall.MediaLayout{}, fmt.Errorf("read back uninstall GPT layout: %w", err)
	}
	media := uninstall.MediaLayout{DiskNumber: diskNumber, DiskPTUUID: guidString(diskID), Data: part}
	return verifySingleDataLayout(media, actual)
}

func buildSingleDataLayoutBuffer(header gptHeader, diskID, partID windows.GUID, part install.PartitionRef) ([]byte, error) {
	if guidString(header.DiskID) != guidString(diskID) {
		return nil, fmt.Errorf("uninstall GPT disk GUID changed between CREATE_DISK and layout write")
	}
	buffer := make([]byte, driveLayoutHeaderSize+partitionEntrySize)
	binary.LittleEndian.PutUint32(buffer[0:4], partitionStyleGPT)
	binary.LittleEndian.PutUint32(buffer[4:8], 1)
	if err := putGUID(buffer, 8, header.DiskID); err != nil {
		return nil, err
	}
	binary.LittleEndian.PutUint64(buffer[24:32], header.StartingUsableOffset)
	binary.LittleEndian.PutUint64(buffer[32:40], header.UsableLength)
	binary.LittleEndian.PutUint32(buffer[40:44], header.MaxPartitionCount)
	planned := layout.Partition{StartBytes: part.StartBytes, SizeBytes: part.SizeBytes}
	if err := putPartitionEntry(buffer[driveLayoutHeaderSize:], 1, 1, planned, basicDataPartitionType, partID, 0, ""); err != nil {
		return nil, err
	}
	return buffer, nil
}

func verifySingleDataLayout(expected uninstall.MediaLayout, actual parsedLayout) (uninstall.MediaLayout, error) {
	if !equalGUIDText(guidString(actual.Header.DiskID), expected.DiskPTUUID) {
		return uninstall.MediaLayout{}, fmt.Errorf("uninstall disk GUID mismatch: got %s want %s", guidString(actual.Header.DiskID), expected.DiskPTUUID)
	}
	if len(actual.Partitions) != 1 {
		return uninstall.MediaLayout{}, fmt.Errorf("uninstall partition count=%d, want exactly 1", len(actual.Partitions))
	}
	got := actual.Partitions[0]
	if !equalGUIDText(guidString(got.PartitionType), guidString(basicDataPartitionType)) {
		return uninstall.MediaLayout{}, fmt.Errorf("uninstall GPT type mismatch: got %s", guidString(got.PartitionType))
	}
	if !equalGUIDText(guidString(got.PartitionID), expected.Data.PartUUID) {
		return uninstall.MediaLayout{}, fmt.Errorf("uninstall PARTUUID mismatch: got %s want %s", guidString(got.PartitionID), expected.Data.PartUUID)
	}
	if got.StartBytes != expected.Data.StartBytes || got.SizeBytes != expected.Data.SizeBytes {
		return uninstall.MediaLayout{}, fmt.Errorf("uninstall partition extent mismatch: got offset=%d size=%d want offset=%d size=%d", got.StartBytes, got.SizeBytes, expected.Data.StartBytes, expected.Data.SizeBytes)
	}
	if got.Attributes != 0 {
		return uninstall.MediaLayout{}, fmt.Errorf("uninstall partition GPT attributes=0x%016X, want 0", got.Attributes)
	}
	result := expected
	result.Data.Number = got.Number
	result.Data.PartUUID = guidString(got.PartitionID)
	return result, nil
}

func alignUp64(value, alignment uint64) uint64 {
	if alignment == 0 {
		return value
	}
	rem := value % alignment
	if rem == 0 {
		return value
	}
	return value + alignment - rem
}

func alignDown64(value, alignment uint64) uint64 {
	if alignment == 0 {
		return value
	}
	return value - value%alignment
}

func equalGUIDText(a, b string) bool {
	return strings.EqualFold(strings.TrimSpace(a), strings.TrimSpace(b))
}
