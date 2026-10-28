//go:build windows

package winhost

import (
	"encoding/binary"
	"fmt"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"golang.org/x/sys/windows"
)

// EnsureWORKVisible clears the GPT NoDriveLetter attribute on WORK. Windows
// Setup/WinPE must be allowed to mount WORK during the installation handoff.
// Older USOS media may still carry bit 63 from the previous hidden-WORK policy,
// so update/repair paths use the same operation to migrate them in place.
// It also brings DATA/WORK GPT bit 1 in line with hideDataWorkFromFirmwareMenu
// (set it, or clear it when the option is off), so an update gives existing
// media the single firmware boot-menu entry too.
func (b Backend) EnsureWORKVisible(media install.MediaLayout) error {
	return b.applyInstalledDataWorkAttributes(media, "DATA/WORK")
}

// installedDataWorkAttributeChange: bits cleared and set on DATA/WORK of an
// installed medium: NoDriveLetter always cleared, GPT bit 1 set or cleared
// by hideDataWorkFromFirmwareMenu.
func installedDataWorkAttributeChange() (clear, set uint64) {
	clear = gptBasicDataAttributeNoDriveLetter
	if !hideDataWorkFromFirmwareMenu {
		clear |= gptAttributeNoBlockIOProtocol
	}
	return clear, installedDataWorkAttributes()
}

// applyInstalledDataWorkAttributes gives DATA and WORK the attributes of an
// installed medium (installedDataWorkAttributeChange).
func (b Backend) applyInstalledDataWorkAttributes(media install.MediaLayout, what string) error {
	clear, set := installedDataWorkAttributeChange()
	return b.updateBasicDataAttributes(media, what, clear, set, media.DATA, media.WORK)
}

// clearNoDriveLetter clears GPT bit 63 (NoDriveLetter) on the given basic
// data partitions of the target disk and verifies that nothing else changed.
func (b Backend) clearNoDriveLetter(media install.MediaLayout, what string, targets ...install.PartitionRef) error {
	return b.updateBasicDataAttributes(media, what, gptBasicDataAttributeNoDriveLetter, 0, targets...)
}

// updateBasicDataAttributes clears `clear` and sets `set` in the GPT
// attributes of the given basic data partitions of the target disk and
// verifies that nothing else changed.
func (b Backend) updateBasicDataAttributes(media install.MediaLayout, what string, clear, set uint64, targets ...install.PartitionRef) error {
	for _, target := range targets {
		if strings.TrimSpace(target.PartUUID) == "" {
			return fmt.Errorf("refusing to expose %s with empty PARTUUID", what)
		}
	}
	if err := refuseRunningFromTarget(media.DiskNumber); err != nil {
		return err
	}
	systemDisks, err := systemDiskNumbers()
	if err != nil {
		return fmt.Errorf("identify Windows system disk before exposing %s: %w", what, err)
	}
	if _, isSystem := systemDisks[media.DiskNumber]; isSystem {
		return fmt.Errorf("refusing %s GPT update on Windows system PhysicalDrive%d", what, media.DiskNumber)
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
		return fmt.Errorf("open %s to expose %s: %w", path, what, err)
	}
	defer windows.CloseHandle(disk)

	locked, err := b.lockVolumesForDisk(media.DiskNumber)
	if err != nil {
		return fmt.Errorf("lock target volumes before %s GPT update: %w", what, err)
	}
	locksClosed := false
	defer func() {
		if !locksClosed {
			_ = closeLockedVolumes(locked)
		}
	}()

	raw, before, err := readDriveLayoutRaw(disk)
	if err != nil {
		return fmt.Errorf("read GPT before exposing %s: %w", what, err)
	}
	if !strings.EqualFold(guidString(before.Header.DiskID), strings.TrimSpace(media.DiskPTUUID)) {
		return fmt.Errorf("refusing %s GPT update: disk GUID changed: got %s want %s", what, guidString(before.Header.DiskID), media.DiskPTUUID)
	}
	changed, oldAttributes, err := applyAttributesInLayout(raw, targets, clear, set)
	if err != nil {
		return err
	}
	if changed {
		if err := deviceIoControlInput(disk, ioctlDiskSetDriveLayoutEx, raw); err != nil {
			return fmt.Errorf("IOCTL_DISK_SET_DRIVE_LAYOUT_EX while exposing %s: %w", what, err)
		}
		if err := deviceIoControlNoBuffer(disk, ioctlDiskUpdateProperties); err != nil {
			return fmt.Errorf("IOCTL_DISK_UPDATE_PROPERTIES after exposing %s: %w", what, err)
		}
	}

	after, err := readDriveLayout(disk)
	if err != nil {
		return fmt.Errorf("read GPT after exposing %s: %w", what, err)
	}
	if err := verifyOnlyAttributesChanged(before, after, oldAttributes, clear, set); err != nil {
		return err
	}

	if err := closeLockedVolumes(locked); err != nil {
		return fmt.Errorf("release target volume locks after %s GPT update: %w", what, err)
	}
	locksClosed = true
	return nil
}

func clearWorkNoDriveLetterInLayout(raw []byte, media install.MediaLayout) (bool, uint64, error) {
	changed, old, err := clearNoDriveLetterInLayout(raw, []install.PartitionRef{media.WORK})
	if err != nil {
		return false, 0, err
	}
	return changed, old[guidTextKey(media.WORK.PartUUID)], nil
}

// clearNoDriveLetterInLayout clears bit 63 on each target in a raw
// DRIVE_LAYOUT_INFORMATION_EX buffer. It reports whether any target had the
// bit set and returns the old attributes keyed by guidTextKey(PARTUUID).
func clearNoDriveLetterInLayout(raw []byte, targets []install.PartitionRef) (bool, map[string]uint64, error) {
	return applyAttributesInLayout(raw, targets, gptBasicDataAttributeNoDriveLetter, 0)
}

// applyAttributesInLayout sets attributes = (old &^ clear) | set on each
// target in a raw DRIVE_LAYOUT_INFORMATION_EX buffer. It reports whether any
// target changed and returns the old attributes keyed by
// guidTextKey(PARTUUID).
func applyAttributesInLayout(raw []byte, targets []install.PartitionRef, clear, set uint64) (bool, map[string]uint64, error) {
	if len(raw) < driveLayoutHeaderSize {
		return false, nil, fmt.Errorf("GPT layout buffer is too short: %d", len(raw))
	}
	count := int(binary.LittleEndian.Uint32(raw[4:8]))
	if count < 1 || driveLayoutHeaderSize+count*partitionEntrySize > len(raw) {
		return false, nil, fmt.Errorf("invalid GPT partition count=%d buffer=%d", count, len(raw))
	}
	oldAttributes := make(map[string]uint64, len(targets))
	changed := false
	for _, target := range targets {
		matches := 0
		for index := 0; index < count; index++ {
			offset := driveLayoutHeaderSize + index*partitionEntrySize
			entry := raw[offset : offset+partitionEntrySize]
			if binary.LittleEndian.Uint32(entry[0:4]) != partitionStyleGPT {
				continue
			}
			partID, err := readGUID(entry, gptInfoOffset+16)
			if err != nil {
				return false, nil, err
			}
			if !strings.EqualFold(guidString(partID), strings.TrimSpace(target.PartUUID)) {
				continue
			}
			if binary.LittleEndian.Uint64(entry[8:16]) != target.StartBytes || binary.LittleEndian.Uint64(entry[16:24]) != target.SizeBytes {
				return false, nil, fmt.Errorf("partition %s GPT geometry changed before attribute update", target.PartUUID)
			}
			typeID, err := readGUID(entry, gptInfoOffset)
			if err != nil {
				return false, nil, err
			}
			if !strings.EqualFold(guidString(typeID), guidString(basicDataPartitionType)) {
				return false, nil, fmt.Errorf("partition %s GPT type changed before attribute update: %s", target.PartUUID, guidString(typeID))
			}
			matches++
			old := binary.LittleEndian.Uint64(entry[gptInfoOffset+32 : gptInfoOffset+40])
			oldAttributes[guidTextKey(target.PartUUID)] = old
			updated := old&^clear | set
			if updated != old {
				changed = true
			}
			binary.LittleEndian.PutUint64(entry[gptInfoOffset+32:gptInfoOffset+40], updated)
		}
		if matches != 1 {
			return false, nil, fmt.Errorf("PARTUUID %s match count=%d in raw GPT layout", target.PartUUID, matches)
		}
	}
	return changed, oldAttributes, nil
}

func verifyOnlyWorkNoDriveLetterCleared(before, after parsedLayout, workPartUUID string, oldAttributes uint64) error {
	return verifyOnlyNoDriveLetterCleared(before, after, map[string]uint64{guidTextKey(workPartUUID): oldAttributes})
}

// verifyOnlyNoDriveLetterCleared checks that the only GPT change is bit 63
// cleared on the partitions in oldAttributes (keyed by guidTextKey).
func verifyOnlyNoDriveLetterCleared(before, after parsedLayout, oldAttributes map[string]uint64) error {
	return verifyOnlyAttributesChanged(before, after, oldAttributes, gptBasicDataAttributeNoDriveLetter, 0)
}

// verifyOnlyAttributesChanged checks that the only GPT change is
// (old &^ clear) | set on the partitions in oldAttributes (keyed by
// guidTextKey).
func verifyOnlyAttributesChanged(before, after parsedLayout, oldAttributes map[string]uint64, clear, set uint64) error {
	if !equalGUIDText(guidString(before.Header.DiskID), guidString(after.Header.DiskID)) ||
		before.Header.StartingUsableOffset != after.Header.StartingUsableOffset ||
		before.Header.UsableLength != after.Header.UsableLength ||
		before.Header.MaxPartitionCount != after.Header.MaxPartitionCount {
		return fmt.Errorf("GPT header changed while updating GPT attributes")
	}
	if len(before.Partitions) != len(after.Partitions) {
		return fmt.Errorf("GPT partition count changed while updating GPT attributes: before=%d after=%d", len(before.Partitions), len(after.Partitions))
	}
	for i := range before.Partitions {
		want := before.Partitions[i]
		got := after.Partitions[i]
		if want.Ordinal != got.Ordinal || want.Number != got.Number || want.StartBytes != got.StartBytes || want.SizeBytes != got.SizeBytes ||
			!equalGUIDText(guidString(want.PartitionType), guidString(got.PartitionType)) || !equalGUIDText(guidString(want.PartitionID), guidString(got.PartitionID)) || want.Name != got.Name {
			return fmt.Errorf("GPT partition %d metadata changed while updating GPT attributes", i+1)
		}
		wantAttributes := want.Attributes
		if old, ok := oldAttributes[guidTextKey(guidString(want.PartitionID))]; ok {
			wantAttributes = old&^clear | set
		}
		if got.Attributes != wantAttributes {
			return fmt.Errorf("GPT partition %d attributes changed unexpectedly: got 0x%016X want 0x%016X", i+1, got.Attributes, wantAttributes)
		}
	}
	return nil
}
