//go:build windows

package winhost

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
	"golang.org/x/sys/windows"
)

type InstalledUSOSSource struct{}

// InspectInstalledUSOSReadOnly validates an installed layout on one already
// enumerated disk without applying destructive-target eligibility rules. It is
// intended for diagnostic inspection of read-only mounted virtual disks, which
// Windows does not report as removable media.
func InspectInstalledUSOSReadOnly(disk domain.Disk) (installed.Target, error) {
	return inspectInstalledUSOSWithApproval(disk, false)
}

func (InstalledUSOSSource) ListInstalledUSOS() ([]installed.Target, error) {
	disks, err := (Enumerator{}).ListDisks()
	if err != nil {
		return nil, err
	}
	result := make([]installed.Target, 0)
	for _, disk := range disks {
		if !disk.Removable || disk.SystemDisk || disk.InspectionError != "" || strings.TrimSpace(disk.Model) == "" || strings.TrimSpace(disk.Serial) == "" {
			continue
		}
		target, err := inspectInstalledUSOS(disk)
		if err != nil {
			continue
		}
		result = append(result, target)
	}
	return result, nil
}

func inspectInstalledUSOS(expected domain.Disk) (installed.Target, error) {
	return inspectInstalledUSOSWithApproval(expected, true)
}

func inspectInstalledUSOSWithApproval(expected domain.Disk, requireApprovedTarget bool) (installed.Target, error) {
	path := fmt.Sprintf(`\\.\PhysicalDrive%d`, expected.Number)
	pathPtr, err := utf16Ptr(path)
	if err != nil {
		return installed.Target{}, err
	}
	handle, err := windows.CreateFile(pathPtr, 0, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, 0, 0)
	if err != nil {
		return installed.Target{}, fmt.Errorf("open %s read-only: %w", path, err)
	}
	defer windows.CloseHandle(handle)

	current, err := inspectPhysicalDiskHandle(expected.Number, handle)
	if err != nil {
		return installed.Target{}, err
	}
	if requireApprovedTarget {
		if err := validateApprovedDisk(expected, current); err != nil {
			return installed.Target{}, err
		}
	}
	layout, err := readDriveLayout(handle)
	if err != nil {
		return installed.Target{}, err
	}
	return validateInstalledUSOSLayout(current, layout)
}

func validateInstalledUSOSLayout(disk domain.Disk, actual parsedLayout) (installed.Target, error) {
	if len(actual.Partitions) != 3 {
		return installed.Target{}, fmt.Errorf("USOS requires exactly 3 GPT partitions, got %d", len(actual.Partitions))
	}
	var espCandidates []parsedPartition
	for _, partition := range actual.Partitions {
		if strings.EqualFold(guidString(partition.PartitionType), guidString(efiSystemPartitionType)) {
			espCandidates = append(espCandidates, partition)
		}
	}
	if len(espCandidates) != 1 {
		return installed.Target{}, fmt.Errorf("expected exactly one ESP, got %d", len(espCandidates))
	}
	espVolume, err := findVolumeByExtent(disk.Number, espCandidates[0].StartBytes, espCandidates[0].SizeBytes)
	if err != nil {
		return installed.Target{}, fmt.Errorf("resolve ESP: %w", err)
	}
	if !strings.EqualFold(espVolume.Info.FileSystem, "FAT32") || espVolume.Info.Label != "USOS_ESP" {
		return installed.Target{}, fmt.Errorf("ESP filesystem/label mismatch")
	}
	iniPath := filepath.Join(espVolume.Info.GUIDPath, "EFI", "USOS", "usos-device.ini")
	file, err := os.Open(iniPath)
	if err != nil {
		return installed.Target{}, fmt.Errorf("open usos-device.ini: %w", err)
	}
	identity, parseErr := install.ParseDeviceINI(file)
	closeErr := file.Close()
	if parseErr != nil {
		return installed.Target{}, fmt.Errorf("parse usos-device.ini: %w", parseErr)
	}
	if closeErr != nil {
		return installed.Target{}, fmt.Errorf("close usos-device.ini: %w", closeErr)
	}
	if !strings.EqualFold(identity.DiskPTUUID, guidString(actual.Header.DiskID)) {
		return installed.Target{}, fmt.Errorf("disk GUID does not match usos-device.ini")
	}

	esp, err := partitionByID(actual, identity.ESPPartUUID)
	if err != nil {
		return installed.Target{}, fmt.Errorf("ESP identity: %w", err)
	}
	data, err := partitionByID(actual, identity.DataPartUUID)
	if err != nil {
		return installed.Target{}, fmt.Errorf("DATA identity: %w", err)
	}
	work, err := partitionByID(actual, identity.WorkPartUUID)
	if err != nil {
		return installed.Target{}, fmt.Errorf("WORK identity: %w", err)
	}
	if !strings.EqualFold(guidString(esp.PartitionType), guidString(efiSystemPartitionType)) ||
		!strings.EqualFold(guidString(data.PartitionType), guidString(basicDataPartitionType)) ||
		!strings.EqualFold(guidString(work.PartitionType), guidString(basicDataPartitionType)) {
		return installed.Target{}, fmt.Errorf("GPT partition types do not match USOS layout")
	}
	if work.SizeBytes != identity.WorkBytes {
		return installed.Target{}, fmt.Errorf("WORK size mismatch: layout=%d ini=%d", work.SizeBytes, identity.WorkBytes)
	}

	dataVolume, err := findVolumeByExtent(disk.Number, data.StartBytes, data.SizeBytes)
	if err != nil {
		return installed.Target{}, fmt.Errorf("resolve DATA: %w", err)
	}
	workVolume, err := findVolumeByExtent(disk.Number, work.StartBytes, work.SizeBytes)
	if err != nil {
		return installed.Target{}, fmt.Errorf("resolve WORK: %w", err)
	}
	if !strings.EqualFold(dataVolume.Info.FileSystem, "NTFS") || dataVolume.Info.Label != identity.DataLabel {
		return installed.Target{}, fmt.Errorf("DATA filesystem/label mismatch")
	}
	if !strings.EqualFold(workVolume.Info.FileSystem, "NTFS") || workVolume.Info.Label != identity.WorkLabel {
		return installed.Target{}, fmt.Errorf("WORK filesystem/label mismatch")
	}
	markerNonce, err := readMarkerNonce(filepath.Join(workVolume.Info.GUIDPath, ".usos-work"))
	if err != nil {
		return installed.Target{}, err
	}
	if markerNonce != identity.Nonce {
		return installed.Target{}, fmt.Errorf("WORK marker nonce mismatch")
	}

	media := install.MediaLayout{
		DiskNumber: disk.Number,
		DiskPTUUID: guidString(actual.Header.DiskID),
		ESP:        install.PartitionRef{Number: esp.Number, StartBytes: esp.StartBytes, SizeBytes: esp.SizeBytes, PartUUID: guidString(esp.PartitionID), VolumePath: espVolume.Info.GUIDPath},
		DATA:       install.PartitionRef{Number: data.Number, StartBytes: data.StartBytes, SizeBytes: data.SizeBytes, PartUUID: guidString(data.PartitionID), VolumePath: dataVolume.Info.GUIDPath},
		WORK:       install.PartitionRef{Number: work.Number, StartBytes: work.StartBytes, SizeBytes: work.SizeBytes, PartUUID: guidString(work.PartitionID), VolumePath: workVolume.Info.GUIDPath},
	}
	return installed.Target{Disk: disk, Identity: identity, Media: media}, nil
}

func partitionByID(actual parsedLayout, id string) (parsedPartition, error) {
	var matches []parsedPartition
	for _, partition := range actual.Partitions {
		if strings.EqualFold(guidString(partition.PartitionID), strings.TrimSpace(id)) {
			matches = append(matches, partition)
		}
	}
	if len(matches) != 1 {
		return parsedPartition{}, fmt.Errorf("PARTUUID %s match count=%d", id, len(matches))
	}
	return matches[0], nil
}

func findVolumeByExtent(diskNumber uint32, start, size uint64) (volumeRecord, error) {
	names, err := volumeNames()
	if err != nil {
		return volumeRecord{}, err
	}
	matches := make([]volumeRecord, 0, 1)
	for _, name := range names {
		record, inspectErr := inspectVolume(name)
		if inspectErr != nil || len(record.Extents) != 1 {
			continue
		}
		extent := record.Extents[0]
		if extent.DiskNumber == diskNumber && extent.StartingOffset == start && extent.ExtentLength == size {
			matches = append(matches, record)
		}
	}
	if len(matches) != 1 {
		return volumeRecord{}, fmt.Errorf("volume match count=%d for PhysicalDrive%d offset=%d size=%d", len(matches), diskNumber, start, size)
	}
	return matches[0], nil
}
