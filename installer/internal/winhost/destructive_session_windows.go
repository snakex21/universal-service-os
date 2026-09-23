//go:build windows

package winhost

import (
	"github.com/snakex21/universal-service-os/installer/internal/volumelock"
	"fmt"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/layout"
	"golang.org/x/sys/windows"
)

type Backend struct {
	InstallerExecutable string
	// LegacyCoreOverride is intentionally empty in normal install/update paths.
	// It exists only for an explicitly invoked physical rollback tool and still
	// goes through the same locked-disk/GPT/read-back safety path.
	LegacyCoreOverride []byte
	// VolumeInUse is asked when a volume of the target stays locked by
	// another program (an Explorer window) after the automatic retries:
	// true = Retry, false = Cancel. Nil means fail after the retries.
	VolumeInUse volumelock.Prompt
	// VolumeLockLog receives the retry log lines; nil discards them.
	VolumeLockLog func(string)
}

type destructiveSession struct {
	diskNumber  uint32
	sectorBytes uint32
	diskBytes   uint64
	disk        windows.Handle
	volumes     []lockedVolume
	cleaned          bool
	created          bool
	closed           bool
	legacyCleared    bool
	legacyCoreStart  uint64
	legacyCoreLength uint64
}

func (b Backend) BeginDestructive(expected domain.Disk) (install.DestructiveSession, domain.Disk, error) {
	if err := refuseRunningFromTarget(expected.Number); err != nil {
		return nil, domain.Disk{}, err
	}
	path := fmt.Sprintf(`\\.\PhysicalDrive%d`, expected.Number)
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
		return nil, domain.Disk{}, fmt.Errorf("open %s for destructive session: %w", path, err)
	}
	session := &destructiveSession{diskNumber: expected.Number, disk: handle}
	fail := func(cause error) (install.DestructiveSession, domain.Disk, error) {
		_ = session.Close()
		return nil, domain.Disk{}, cause
	}

	preLock, err := inspectPhysicalDiskHandle(expected.Number, handle)
	if err != nil {
		return fail(fmt.Errorf("pre-lock disk inspection: %w", err))
	}
	if err := validateApprovedDisk(expected, preLock); err != nil {
		return fail(err)
	}

	systemDisks, err := systemDiskNumbers()
	if err != nil {
		return fail(fmt.Errorf("identify Windows system disk: %w", err))
	}
	if _, isSystem := systemDisks[expected.Number]; isSystem {
		return fail(fmt.Errorf("refusing destructive session: PhysicalDrive%d contains the running Windows system volume", expected.Number))
	}

	locked, err := b.lockVolumesForDisk(expected.Number)
	if err != nil {
		return fail(fmt.Errorf("lock target volumes: %w", err))
	}
	session.volumes = locked

	current, err := inspectPhysicalDiskHandle(expected.Number, handle)
	if err != nil {
		return fail(fmt.Errorf("post-lock disk inspection: %w", err))
	}
	if err := validateApprovedDisk(expected, current); err != nil {
		return fail(fmt.Errorf("post-lock revalidation: %w", err))
	}
	session.sectorBytes = current.SectorBytes
	session.diskBytes = current.SizeBytes
	return session, current, nil
}

func validateApprovedDisk(expected, current domain.Disk) error {
	if !current.Removable {
		return fmt.Errorf("device no longer reports RemovableMedia")
	}
	approved := expected.Identity()
	observed := current.Identity()
	if !approved.MatchesApprovedHardware(observed) {
		return fmt.Errorf(
			"hardware identity mismatch: approved model=%q serial=%q size=%d, current model=%q serial=%q size=%d",
			approved.Model,
			approved.Serial,
			approved.SizeBytes,
			observed.Model,
			observed.Serial,
			observed.SizeBytes,
		)
	}
	if expected.SectorBytes != 0 && current.SectorBytes != expected.SectorBytes {
		return fmt.Errorf("logical sector size changed: approved=%d current=%d", expected.SectorBytes, current.SectorBytes)
	}
	return nil
}

func (s *destructiveSession) CleanPartitionTable() error {
	if s.closed {
		return fmt.Errorf("destructive session is closed")
	}
	if s.cleaned {
		return fmt.Errorf("partition table was already deleted in this session")
	}
	if err := deviceIoControlNoBuffer(s.disk, ioctlDiskDeleteDriveLayout); err != nil {
		return fmt.Errorf("IOCTL_DISK_DELETE_DRIVE_LAYOUT PhysicalDrive%d: %w", s.diskNumber, err)
	}
	if err := deviceIoControlNoBuffer(s.disk, ioctlDiskUpdateProperties); err != nil {
		return fmt.Errorf("IOCTL_DISK_UPDATE_PROPERTIES after DELETE_DRIVE_LAYOUT: %w", err)
	}
	if err := closeLockedVolumes(s.volumes); err != nil {
		return fmt.Errorf("release old volume locks after DELETE_DRIVE_LAYOUT: %w", err)
	}
	s.volumes = nil
	s.cleaned = true
	return nil
}

func (s *destructiveSession) CreateGPTAndPartitions(plan layout.Plan) (install.MediaLayout, error) {
	if s.closed {
		return install.MediaLayout{}, fmt.Errorf("destructive session is closed")
	}
	if !s.cleaned {
		return install.MediaLayout{}, fmt.Errorf("refusing CREATE_DISK before DELETE_DRIVE_LAYOUT")
	}
	if s.created {
		return install.MediaLayout{}, fmt.Errorf("GPT layout was already created in this session")
	}
	if err := plan.ValidateSectorSize(s.sectorBytes); err != nil {
		return install.MediaLayout{}, err
	}
	ids, err := newGPTIDs()
	if err != nil {
		return install.MediaLayout{}, fmt.Errorf("generate GPT GUIDs: %w", err)
	}
	header, err := createGPT(s.disk, ids)
	if err != nil {
		return install.MediaLayout{}, err
	}
	media, err := setGPTLayout(s.disk, plan, header, ids)
	if err != nil {
		return install.MediaLayout{}, err
	}
	media.DiskNumber = s.diskNumber
	s.created = true
	return media, nil
}

func (s *destructiveSession) VerifyLayoutUnchanged(expected install.MediaLayout) (install.MediaLayout, error) {
	if s.closed {
		return install.MediaLayout{}, fmt.Errorf("destructive session is closed")
	}
	if !s.created {
		return install.MediaLayout{}, fmt.Errorf("cannot verify GPT layout before it is created")
	}
	actual, err := readDriveLayout(s.disk)
	if err != nil {
		return install.MediaLayout{}, fmt.Errorf("post-format IOCTL_DISK_GET_DRIVE_LAYOUT_EX: %w", err)
	}
	verified, err := verifyMediaLayout(expected, actual)
	if err != nil {
		return install.MediaLayout{}, err
	}
	verified.DiskNumber = s.diskNumber
	return verified, nil
}

func (s *destructiveSession) Close() error {
	if s == nil || s.closed {
		return nil
	}
	s.closed = true
	volumeErr := closeLockedVolumes(s.volumes)
	diskErr := windows.CloseHandle(s.disk)
	if volumeErr != nil {
		return volumeErr
	}
	if diskErr != nil {
		return fmt.Errorf("close PhysicalDrive%d: %w", s.diskNumber, diskErr)
	}
	return nil
}
