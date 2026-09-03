//go:build windows

package winhost

import (
	"encoding/binary"
	"fmt"
	"strings"
	"time"
	"unsafe"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"golang.org/x/sys/windows"
)

func (Backend) EnsureWORKHidden(media install.MediaLayout) error {
	if strings.TrimSpace(media.WORK.PartUUID) == "" {
		return fmt.Errorf("refusing to hide WORK with empty PARTUUID")
	}
	if err := refuseRunningFromTarget(media.DiskNumber); err != nil {
		return err
	}
	systemDisks, err := systemDiskNumbers()
	if err != nil {
		return fmt.Errorf("identify Windows system disk before hiding WORK: %w", err)
	}
	if _, isSystem := systemDisks[media.DiskNumber]; isSystem {
		return fmt.Errorf("refusing WORK GPT update on Windows system PhysicalDrive%d", media.DiskNumber)
	}

	path := fmt.Sprintf(`\\.\PhysicalDrive%d`, media.DiskNumber)
	pathPtr, err := utf16Ptr(path)
	if err != nil {
		return err
	}
	disk, err := windows.CreateFile(
		pathPtr,
		windows.GENERIC_READ|windows.GENERIC_WRITE,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE,
		nil,
		windows.OPEN_EXISTING,
		0,
		0,
	)
	if err != nil {
		return fmt.Errorf("open %s to hide WORK: %w", path, err)
	}
	defer windows.CloseHandle(disk)

	locked, err := lockVolumesForDisk(media.DiskNumber)
	if err != nil {
		return fmt.Errorf("lock target volumes before WORK GPT update: %w", err)
	}
	locksClosed := false
	defer func() {
		if !locksClosed {
			_ = closeLockedVolumes(locked)
		}
	}()

	raw, before, err := readDriveLayoutRaw(disk)
	if err != nil {
		return fmt.Errorf("read GPT before hiding WORK: %w", err)
	}
	if !strings.EqualFold(guidString(before.Header.DiskID), strings.TrimSpace(media.DiskPTUUID)) {
		return fmt.Errorf("refusing WORK GPT update: disk GUID changed: got %s want %s", guidString(before.Header.DiskID), media.DiskPTUUID)
	}
	changed, oldAttributes, err := setWorkNoDriveLetterInLayout(raw, media)
	if err != nil {
		return err
	}
	if changed {
		if err := deviceIoControlInput(disk, ioctlDiskSetDriveLayoutEx, raw); err != nil {
			return fmt.Errorf("IOCTL_DISK_SET_DRIVE_LAYOUT_EX while hiding WORK: %w", err)
		}
		if err := deviceIoControlNoBuffer(disk, ioctlDiskUpdateProperties); err != nil {
			return fmt.Errorf("IOCTL_DISK_UPDATE_PROPERTIES after hiding WORK: %w", err)
		}
	}

	after, err := readDriveLayout(disk)
	if err != nil {
		return fmt.Errorf("read GPT after hiding WORK: %w", err)
	}
	if err := verifyOnlyWorkNoDriveLetterChanged(before, after, media.WORK.PartUUID, oldAttributes); err != nil {
		return err
	}

	if err := closeLockedVolumes(locked); err != nil {
		return fmt.Errorf("release target volume locks after WORK GPT update: %w", err)
	}
	locksClosed = true

	if err := removeWorkDriveLetters(media, 10*time.Second); err != nil {
		return err
	}
	return nil
}

func setWorkNoDriveLetterInLayout(raw []byte, media install.MediaLayout) (bool, uint64, error) {
	if len(raw) < driveLayoutHeaderSize {
		return false, 0, fmt.Errorf("GPT layout buffer is too short: %d", len(raw))
	}
	count := int(binary.LittleEndian.Uint32(raw[4:8]))
	if count < 1 || driveLayoutHeaderSize+count*partitionEntrySize > len(raw) {
		return false, 0, fmt.Errorf("invalid GPT partition count=%d buffer=%d", count, len(raw))
	}
	matches := 0
	var oldAttributes uint64
	for index := 0; index < count; index++ {
		offset := driveLayoutHeaderSize + index*partitionEntrySize
		entry := raw[offset : offset+partitionEntrySize]
		if binary.LittleEndian.Uint32(entry[0:4]) != partitionStyleGPT {
			continue
		}
		partID, err := readGUID(entry, gptInfoOffset+16)
		if err != nil {
			return false, 0, err
		}
		if !strings.EqualFold(guidString(partID), strings.TrimSpace(media.WORK.PartUUID)) {
			continue
		}
		if binary.LittleEndian.Uint64(entry[8:16]) != media.WORK.StartBytes || binary.LittleEndian.Uint64(entry[16:24]) != media.WORK.SizeBytes {
			return false, 0, fmt.Errorf("WORK GPT geometry changed before attribute update")
		}
		typeID, err := readGUID(entry, gptInfoOffset)
		if err != nil {
			return false, 0, err
		}
		if !strings.EqualFold(guidString(typeID), guidString(basicDataPartitionType)) {
			return false, 0, fmt.Errorf("WORK GPT type changed before attribute update: %s", guidString(typeID))
		}
		matches++
		oldAttributes = binary.LittleEndian.Uint64(entry[gptInfoOffset+32 : gptInfoOffset+40])
		binary.LittleEndian.PutUint64(entry[gptInfoOffset+32:gptInfoOffset+40], oldAttributes|gptBasicDataAttributeNoDriveLetter)
	}
	if matches != 1 {
		return false, 0, fmt.Errorf("WORK PARTUUID %s match count=%d in raw GPT layout", media.WORK.PartUUID, matches)
	}
	return oldAttributes&gptBasicDataAttributeNoDriveLetter == 0, oldAttributes, nil
}

func verifyOnlyWorkNoDriveLetterChanged(before, after parsedLayout, workPartUUID string, oldAttributes uint64) error {
	if guidString(before.Header.DiskID) != guidString(after.Header.DiskID) ||
		before.Header.StartingUsableOffset != after.Header.StartingUsableOffset ||
		before.Header.UsableLength != after.Header.UsableLength ||
		before.Header.MaxPartitionCount != after.Header.MaxPartitionCount {
		return fmt.Errorf("GPT header changed while hiding WORK")
	}
	if len(before.Partitions) != len(after.Partitions) {
		return fmt.Errorf("GPT partition count changed while hiding WORK: before=%d after=%d", len(before.Partitions), len(after.Partitions))
	}
	for i := range before.Partitions {
		want := before.Partitions[i]
		got := after.Partitions[i]
		if want.Ordinal != got.Ordinal || want.Number != got.Number || want.StartBytes != got.StartBytes || want.SizeBytes != got.SizeBytes ||
			guidString(want.PartitionType) != guidString(got.PartitionType) || guidString(want.PartitionID) != guidString(got.PartitionID) || want.Name != got.Name {
			return fmt.Errorf("GPT partition %d metadata changed while hiding WORK", i+1)
		}
		wantAttributes := want.Attributes
		if strings.EqualFold(guidString(want.PartitionID), strings.TrimSpace(workPartUUID)) {
			wantAttributes = oldAttributes | gptBasicDataAttributeNoDriveLetter
		}
		if got.Attributes != wantAttributes {
			return fmt.Errorf("GPT partition %d attributes changed unexpectedly: got 0x%016X want 0x%016X", i+1, got.Attributes, wantAttributes)
		}
	}
	return nil
}

func removeWorkDriveLetters(media install.MediaLayout, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for {
		record, err := findVolumeByExtent(media.DiskNumber, media.WORK.StartBytes, media.WORK.SizeBytes)
		if err == nil {
			for _, mountPath := range record.Info.MountPaths {
				if !isDriveLetterMountPath(mountPath) {
					continue
				}
				pathPtr, ptrErr := utf16Ptr(mountPath)
				if ptrErr != nil {
					return ptrErr
				}
				r1, _, callErr := procDeleteVolumeMountPointW.Call(uintptr(unsafe.Pointer(pathPtr)))
				if deleteErr := boolResult(r1, callErr); deleteErr != nil {
					return fmt.Errorf("DeleteVolumeMountPointW %s: %w", mountPath, deleteErr)
				}
			}
			refreshed, refreshErr := findVolumeByExtent(media.DiskNumber, media.WORK.StartBytes, media.WORK.SizeBytes)
			if refreshErr == nil && !hasDriveLetter(refreshed.Info.MountPaths) {
				return nil
			}
			if refreshErr != nil {
				lastErr = refreshErr
			} else {
				lastErr = fmt.Errorf("WORK still has a drive-letter mount path: %v", refreshed.Info.MountPaths)
			}
		} else {
			lastErr = err
		}
		if !time.Now().Before(deadline) {
			return fmt.Errorf("WORK did not become hidden before timeout: %w", lastErr)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func isDriveLetterMountPath(path string) bool {
	return len(path) == 3 && path[1] == ':' && (path[2] == '\\' || path[2] == '/')
}
