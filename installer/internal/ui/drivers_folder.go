package ui

import (
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
)

// dataDriversFolder returns "<letter>:\Drivers" on the DATA volume of t, or
// false when the DATA volume has no drive letter. The DATA volume is the one
// whose GUID path is Media.DATA.VolumePath, else the one labelled like DATA.
func dataDriversFolder(t installed.Target) (string, bool) {
	data, ok := findVolume(t.Disk.Volumes, func(v domain.Volume) bool {
		return t.Media.DATA.VolumePath != "" && sameVolumePath(v.GUIDPath, t.Media.DATA.VolumePath)
	})
	if !ok {
		label := t.Identity.DataLabel
		if label == "" {
			label = "USOS_DATA"
		}
		data, ok = findVolume(t.Disk.Volumes, func(v domain.Volume) bool { return strings.EqualFold(v.Label, label) })
	}
	if !ok {
		return "", false
	}
	for _, mount := range data.MountPaths {
		if isDriveRoot(mount) {
			return strings.ToUpper(mount[:1]) + `:\Drivers`, true
		}
	}
	return "", false
}

// driversFolderForDisk picks the target on disk number and returns its
// DATA\Drivers folder.
func driversFolderForDisk(targets []installed.Target, disk uint32) (string, bool) {
	for _, t := range targets {
		if t.Disk.Number == disk {
			return dataDriversFolder(t)
		}
	}
	return "", false
}

func findVolume(volumes []domain.Volume, match func(domain.Volume) bool) (domain.Volume, bool) {
	for _, v := range volumes {
		if match(v) {
			return v, true
		}
	}
	return domain.Volume{}, false
}

func sameVolumePath(a, b string) bool {
	return strings.EqualFold(strings.TrimSuffix(a, `\`), strings.TrimSuffix(b, `\`))
}

// isDriveRoot accepts "X:\" (the form GetVolumePathNamesForVolumeNameW uses).
func isDriveRoot(path string) bool {
	if len(path) != 3 || path[1] != ':' || path[2] != '\\' {
		return false
	}
	c := path[0] | 0x20
	return c >= 'a' && c <= 'z'
}
