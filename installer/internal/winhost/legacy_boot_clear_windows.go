//go:build windows

package winhost

import (
	"fmt"

	"github.com/snakex21/universal-service-os/installer/internal/installed"
	"github.com/snakex21/universal-service-os/installer/internal/legacyboot"
	"golang.org/x/sys/windows"
)

func (b Backend) ClearInstalledLegacyBoot(expected installed.Target) (legacyboot.Audit, error) {
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
		return legacyboot.Audit{}, fmt.Errorf("open %s for Legacy clear: %w", path, err)
	}
	defer windows.CloseHandle(handle)

	current, err := inspectPhysicalDiskHandle(expected.Disk.Number, handle)
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("pre-lock Legacy clear inspection: %w", err)
	}
	if err := validateApprovedDisk(expected.Disk, current); err != nil {
		return legacyboot.Audit{}, err
	}
	actual, err := readDriveLayout(handle)
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("pre-lock Legacy clear GPT read: %w", err)
	}
	verified, err := verifyMediaLayout(expected.Media, actual)
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("pre-lock Legacy clear GPT mismatch: %w", err)
	}

	locked, err := b.lockVolumesForDisk(expected.Disk.Number)
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("lock target volumes for Legacy clear: %w", err)
	}
	defer closeLockedVolumes(locked)

	current, err = inspectPhysicalDiskHandle(expected.Disk.Number, handle)
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("post-lock Legacy clear inspection: %w", err)
	}
	if err := validateApprovedDisk(expected.Disk, current); err != nil {
		return legacyboot.Audit{}, fmt.Errorf("post-lock Legacy clear revalidation: %w", err)
	}
	actual, err = readDriveLayout(handle)
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("post-lock Legacy clear GPT read: %w", err)
	}
	verified, err = verifyMediaLayout(expected.Media, actual)
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("post-lock Legacy clear GPT mismatch: %w", err)
	}

	zeroStage1 := legacyboot.ZeroBytes(legacyboot.Stage1CodeBytes)
	zeroCore := legacyboot.ZeroBytes(int(legacyboot.CoreSlotBytes))
	audit, err := applyLegacyBootArea(
		handle,
		current.SizeBytes,
		current.SectorBytes,
		actual.Header.StartingUsableOffset,
		verified.ESP.StartBytes,
		zeroStage1,
		zeroCore,
	)
	if err != nil {
		return audit, err
	}
	finalLayout, err := readDriveLayout(handle)
	if err != nil {
		return audit, fmt.Errorf("read GPT after Legacy clear: %w", err)
	}
	if _, err := verifyMediaLayout(expected.Media, finalLayout); err != nil {
		return audit, fmt.Errorf("GPT changed during Legacy clear: %w", err)
	}
	return audit, nil
}

func (Backend) VerifyInstalledLegacyBootCleared(expected installed.Target) error {
	if err := refuseRunningFromTarget(expected.Disk.Number); err != nil {
		return err
	}
	path := fmt.Sprintf(`\\.\PhysicalDrive%d`, expected.Disk.Number)
	pathPtr, err := utf16Ptr(path)
	if err != nil {
		return err
	}
	handle, err := windows.CreateFile(
		pathPtr,
		windows.GENERIC_READ,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE,
		nil,
		windows.OPEN_EXISTING,
		0,
		0,
	)
	if err != nil {
		return fmt.Errorf("open %s to verify Legacy clear: %w", path, err)
	}
	defer windows.CloseHandle(handle)
	current, err := inspectPhysicalDiskHandle(expected.Disk.Number, handle)
	if err != nil {
		return err
	}
	if err := validateApprovedDisk(expected.Disk, current); err != nil {
		return err
	}
	actual, err := readDriveLayout(handle)
	if err != nil {
		return err
	}
	verified, err := verifyMediaLayout(expected.Media, actual)
	if err != nil {
		return fmt.Errorf("GPT mismatch while verifying Legacy clear: %w", err)
	}
	return verifyLegacyBootClearedArea(
		handle,
		current.SizeBytes,
		current.SectorBytes,
		actual.Header.StartingUsableOffset,
		verified.ESP.StartBytes,
	)
}
