//go:build windows

package winhost

import (
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
)

// ValidateBackupDirectory checks an existing local directory before even the
// operation logger is created. Evidence and logs must not write to the target.
func ValidateBackupDirectory(directory string, targetDisk uint32) error {
	info, err := os.Stat(directory)
	if err != nil || !info.IsDir() {
		return fmt.Errorf("backup directory must already exist: %s", directory)
	}
	resolved, err := filepath.EvalSymlinks(directory)
	if err != nil {
		return err
	}
	volumePath, err := volumePathName(resolved)
	if err != nil {
		return err
	}
	volume, err := volumeNameForMountPoint(volumePath)
	if err != nil {
		return err
	}
	numbers, err := volumeDiskNumbers(volume)
	if err != nil {
		return err
	}
	if len(numbers) == 0 {
		return fmt.Errorf("backup directory has no local physical disk")
	}
	for _, n := range numbers {
		if n == targetDisk {
			return fmt.Errorf("logs and backups cannot reside on update target PhysicalDrive%d", targetDisk)
		}
	}
	return nil
}

type bootBackupReader struct{ handle windows.Handle }

func (r bootBackupReader) ReadAt(p []byte, offset int64) (int, error) {
	if offset < 0 {
		return 0, fmt.Errorf("negative backup offset")
	}
	data, err := readDiskExact(r.handle, uint64(offset), len(p))
	if err != nil {
		return 0, err
	}
	return copy(p, data), nil
}
