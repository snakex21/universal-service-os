//go:build windows

package winhost

import (
	"fmt"
	"strings"
	"time"

	"github.com/snakex21/universal-service-os/installer/internal/install"
)

type formattedExpectation struct {
	name       string
	partition  install.PartitionRef
	fileSystem string
	label      string
}

func resolveFormattedMedia(media install.MediaLayout, timeout time.Duration) (install.MediaLayout, error) {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for {
		resolved, err := resolveFormattedMediaOnce(media)
		if err == nil {
			return resolved, nil
		}
		lastErr = err
		if !time.Now().Before(deadline) {
			return install.MediaLayout{}, fmt.Errorf("formatted volumes did not become ready: %w", lastErr)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func resolveFormattedMediaOnce(media install.MediaLayout) (install.MediaLayout, error) {
	names, err := volumeNames()
	if err != nil {
		return install.MediaLayout{}, err
	}
	expected := []formattedExpectation{
		{name: "ESP", partition: media.ESP, fileSystem: "FAT32", label: "USOS_ESP"},
		{name: "DATA", partition: media.DATA, fileSystem: "NTFS", label: "USOS_DATA"},
		{name: "WORK", partition: media.WORK, fileSystem: "NTFS", label: "USOS_WORK"},
	}
	result := media
	for _, want := range expected {
		matches := make([]volumeRecord, 0, 1)
		for _, name := range names {
			record, inspectErr := inspectVolume(name)
			if inspectErr != nil || len(record.Extents) != 1 {
				continue
			}
			extent := record.Extents[0]
			if extent.DiskNumber == media.DiskNumber && extent.StartingOffset == want.partition.StartBytes && extent.ExtentLength == want.partition.SizeBytes {
				matches = append(matches, record)
			}
		}
		if len(matches) != 1 {
			return install.MediaLayout{}, fmt.Errorf("%s volume match count=%d for PhysicalDrive%d offset=%d size=%d", want.name, len(matches), media.DiskNumber, want.partition.StartBytes, want.partition.SizeBytes)
		}
		match := matches[0]
		if !strings.EqualFold(match.Info.FileSystem, want.fileSystem) {
			return install.MediaLayout{}, fmt.Errorf("%s filesystem mismatch: got %q want %q", want.name, match.Info.FileSystem, want.fileSystem)
		}
		if match.Info.Label != want.label {
			return install.MediaLayout{}, fmt.Errorf("%s label mismatch: got %q want %q", want.name, match.Info.Label, want.label)
		}
		ref := want.partition
		ref.VolumePath = match.Info.GUIDPath
		switch want.name {
		case "ESP":
			result.ESP = ref
		case "DATA":
			result.DATA = ref
		case "WORK":
			result.WORK = ref
		}
	}
	return result, nil
}
