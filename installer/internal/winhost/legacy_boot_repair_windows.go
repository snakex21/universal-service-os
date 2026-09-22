//go:build windows

package winhost

import (
	"fmt"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
	"github.com/snakex21/universal-service-os/installer/internal/legacyboot"
	"github.com/snakex21/universal-service-os/installer/internal/payload"
	"golang.org/x/sys/windows"
)

func (b Backend) RestoreLegacyBoot(expected installed.Target) (legacyboot.Audit, error) {
	if err := refuseRunningFromTarget(expected.Disk.Number); err != nil {
		return legacyboot.Audit{}, err
	}
	path := fmt.Sprintf(`\\.\PhysicalDrive%d`, expected.Disk.Number)
	pathPtr, err := utf16Ptr(path)
	if err != nil {
		return legacyboot.Audit{}, err
	}
	handle, err := windows.CreateFile(
		pathPtr,
		windows.GENERIC_READ|windows.GENERIC_WRITE,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE,
		nil,
		windows.OPEN_EXISTING,
		0,
		0,
	)
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("open %s for Legacy repair: %w", path, err)
	}
	defer windows.CloseHandle(handle)

	current, err := inspectPhysicalDiskHandle(expected.Disk.Number, handle)
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("pre-lock Legacy repair inspection: %w", err)
	}
	if err := validateApprovedDisk(expected.Disk, current); err != nil {
		return legacyboot.Audit{}, err
	}
	actual, err := readDriveLayout(handle)
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("pre-lock Legacy repair GPT read: %w", err)
	}
	verified, err := verifyMediaLayout(expected.Media, actual)
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("pre-lock Legacy repair GPT mismatch: %w", err)
	}

	locked, err := lockVolumesForDisk(expected.Disk.Number)
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("lock target volumes for Legacy repair: %w", err)
	}
	defer closeLockedVolumes(locked)

	current, err = inspectPhysicalDiskHandle(expected.Disk.Number, handle)
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("post-lock Legacy repair inspection: %w", err)
	}
	if err := validateApprovedDisk(expected.Disk, current); err != nil {
		return legacyboot.Audit{}, fmt.Errorf("post-lock Legacy repair revalidation: %w", err)
	}
	actual, err = readDriveLayout(handle)
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("post-lock Legacy repair GPT read: %w", err)
	}
	verified, err = verifyMediaLayout(expected.Media, actual)
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("post-lock Legacy repair GPT mismatch: %w", err)
	}
	boot, err := payload.LegacyBoot()
	if err != nil {
		return legacyboot.Audit{}, err
	}
	if len(b.LegacyCoreOverride) != 0 {
		boot.Core = append([]byte(nil), b.LegacyCoreOverride...)
		if err := boot.Validate(); err != nil {
			return legacyboot.Audit{}, fmt.Errorf("validate Legacy rollback override: %w", err)
		}
	}
	audit, err := applyLegacyBootArea(handle, current.SizeBytes, current.SectorBytes, actual.Header.StartingUsableOffset, verified.ESP.StartBytes, boot.Stage1, boot.Core)
	if err != nil {
		return audit, err
	}
	finalLayout, err := readDriveLayout(handle)
	if err != nil {
		return audit, fmt.Errorf("read GPT after Legacy repair: %w", err)
	}
	if _, err := verifyMediaLayout(expected.Media, finalLayout); err != nil {
		return audit, fmt.Errorf("GPT changed during Legacy repair: %w", err)
	}
	return audit, nil
}

func verifyLegacyBootForMedia(media install.MediaLayout) error {
	disk, err := inspectPhysicalDisk(media.DiskNumber)
	if err != nil {
		return err
	}
	path := fmt.Sprintf(`\\.\PhysicalDrive%d`, media.DiskNumber)
	pathPtr, err := utf16Ptr(path)
	if err != nil {
		return err
	}
	handle, err := windows.CreateFile(pathPtr, windows.GENERIC_READ, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, 0, 0)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(handle)
	actual, err := readDriveLayout(handle)
	if err != nil {
		return err
	}
	verified, err := verifyMediaLayout(media, actual)
	if err != nil {
		return err
	}
	boot, err := payload.LegacyBoot()
	if err != nil {
		return err
	}
	return verifyLegacyBootArea(handle, disk.SizeBytes, disk.SectorBytes, actual.Header.StartingUsableOffset, verified.ESP.StartBytes, boot.Stage1, boot.Core)
}
