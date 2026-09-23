//go:build windows

package winhost

import (
	"fmt"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/uninstall"
	"golang.org/x/sys/windows"
)

func (b Backend) BeginUSOSDestructive(expected uninstall.Target) (uninstall.DestructiveSession, domain.Disk, error) {
	if err := refuseRunningFromTarget(expected.Disk.Number); err != nil {
		return nil, domain.Disk{}, err
	}
	path := fmt.Sprintf(`\\.\PhysicalDrive%d`, expected.Disk.Number)
	pathPtr, err := utf16Ptr(path)
	if err != nil {
		return nil, domain.Disk{}, err
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
		return nil, domain.Disk{}, fmt.Errorf("open %s for USOS destructive session: %w", path, err)
	}
	session := &destructiveSession{diskNumber: expected.Disk.Number, disk: handle}
	fail := func(cause error) (uninstall.DestructiveSession, domain.Disk, error) {
		_ = session.Close()
		return nil, domain.Disk{}, cause
	}

	preLock, err := inspectPhysicalDiskHandle(expected.Disk.Number, handle)
	if err != nil {
		return fail(fmt.Errorf("pre-lock disk inspection: %w", err))
	}
	if err := validateApprovedDisk(expected.Disk, preLock); err != nil {
		return fail(err)
	}
	if err := validateExpectedUSOSOnOpenHandle(expected, handle, true); err != nil {
		return fail(fmt.Errorf("pre-lock USOS identity validation: %w", err))
	}

	systemDisks, err := systemDiskNumbers()
	if err != nil {
		return fail(fmt.Errorf("identify Windows system disk: %w", err))
	}
	if _, isSystem := systemDisks[expected.Disk.Number]; isSystem {
		return fail(fmt.Errorf("refusing uninstall destructive session: PhysicalDrive%d contains the running Windows system volume", expected.Disk.Number))
	}

	locked, err := b.lockVolumesForDisk(expected.Disk.Number)
	if err != nil {
		return fail(fmt.Errorf("lock target volumes: %w", err))
	}
	session.volumes = locked

	current, err := inspectPhysicalDiskHandle(expected.Disk.Number, handle)
	if err != nil {
		return fail(fmt.Errorf("post-lock disk inspection: %w", err))
	}
	if err := validateApprovedDisk(expected.Disk, current); err != nil {
		return fail(fmt.Errorf("post-lock hardware revalidation: %w", err))
	}
	if err := validateExpectedUSOSOnOpenHandle(expected, handle, false); err != nil {
		return fail(fmt.Errorf("post-lock GPT revalidation: %w", err))
	}
	session.sectorBytes = current.SectorBytes
	session.diskBytes = current.SizeBytes
	return session, current, nil
}

func validateExpectedUSOSOnOpenHandle(expected uninstall.Target, handle windows.Handle, verifyFiles bool) error {
	actual, err := readDriveLayout(handle)
	if err != nil {
		return err
	}
	if verifyFiles {
		current, err := validateInstalledUSOSLayout(expected.Disk, actual)
		if err != nil {
			return err
		}
		if current.Identity != expected.Identity {
			return fmt.Errorf("usos-device.ini changed since selection")
		}
	}
	if !strings.EqualFold(guidString(actual.Header.DiskID), expected.Media.DiskPTUUID) {
		return fmt.Errorf("disk GUID changed since selection")
	}
	if len(actual.Partitions) != 3 {
		return fmt.Errorf("partition count changed since selection: got %d want 3", len(actual.Partitions))
	}
	checks := []struct {
		name   string
		ref    install.PartitionRef
		typeID string
	}{
		{"ESP", expected.Media.ESP, guidString(efiSystemPartitionType)},
		{"DATA", expected.Media.DATA, guidString(basicDataPartitionType)},
		{"WORK", expected.Media.WORK, guidString(basicDataPartitionType)},
	}
	for _, check := range checks {
		partition, err := partitionByID(actual, check.ref.PartUUID)
		if err != nil {
			return fmt.Errorf("%s: %w", check.name, err)
		}
		if !strings.EqualFold(guidString(partition.PartitionType), check.typeID) {
			return fmt.Errorf("%s GPT type changed", check.name)
		}
		if partition.StartBytes != check.ref.StartBytes || partition.SizeBytes != check.ref.SizeBytes {
			return fmt.Errorf("%s extent changed", check.name)
		}
	}
	return nil
}

func (s *destructiveSession) CreateSingleDataPartition() (uninstall.MediaLayout, error) {
	if s.closed {
		return uninstall.MediaLayout{}, fmt.Errorf("destructive session is closed")
	}
	if !s.cleaned {
		return uninstall.MediaLayout{}, fmt.Errorf("refusing uninstall CREATE_DISK before DELETE_DRIVE_LAYOUT")
	}
	if s.created {
		return uninstall.MediaLayout{}, fmt.Errorf("GPT layout was already created in this session")
	}
	media, err := createSingleDataLayout(s.disk, s.diskNumber, s.sectorBytes)
	if err != nil {
		return uninstall.MediaLayout{}, err
	}
	s.created = true
	return media, nil
}

func (s *destructiveSession) VerifyUninstallLayoutUnchanged(expected uninstall.MediaLayout) (uninstall.MediaLayout, error) {
	if s.closed {
		return uninstall.MediaLayout{}, fmt.Errorf("destructive session is closed")
	}
	if !s.created {
		return uninstall.MediaLayout{}, fmt.Errorf("cannot verify uninstall GPT layout before it is created")
	}
	actual, err := readDriveLayout(s.disk)
	if err != nil {
		return uninstall.MediaLayout{}, fmt.Errorf("IOCTL_DISK_GET_DRIVE_LAYOUT_EX uninstall: %w", err)
	}
	verified, err := verifySingleDataLayout(expected, actual)
	if err != nil {
		return uninstall.MediaLayout{}, err
	}
	verified.DiskNumber = s.diskNumber
	return verified, nil
}

// VerifyLayoutUnchanged satisfies uninstall.DestructiveSession without changing
// the installer's stricter three-partition verification method.
func (s *destructiveSession) VerifyLayoutUnchangedSingle(expected uninstall.MediaLayout) (uninstall.MediaLayout, error) {
	return s.VerifyUninstallLayoutUnchanged(expected)
}
