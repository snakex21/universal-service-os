package domain

import (
	"fmt"
	"sort"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/i18n"
)

type DeviceRow struct {
	DiskNumber   uint32
	Model        string
	Capacity     string
	Letters      string
	Labels       string
	FileSystems  string
	Used         string
	RootContents string
	Selectable   bool
	Reason       string
}

func BuildDeviceRow(d Disk) DeviceRow {
	letters := make([]string, 0)
	labels := make([]string, 0)
	fileSystems := make([]string, 0)
	roots := make([]string, 0)
	var used uint64

	for _, volume := range d.Volumes {
		for _, mount := range volume.MountPaths {
			letters = append(letters, strings.TrimSpace(mount))
		}
		if strings.TrimSpace(volume.Label) != "" {
			labels = append(labels, volume.Label)
		}
		if strings.TrimSpace(volume.FileSystem) != "" {
			fileSystems = append(fileSystems, volume.FileSystem)
		}
		used += volume.UsedBytes
		if len(volume.RootEntries) > 0 {
			prefix := volume.Label
			if prefix == "" {
				prefix = volume.GUIDPath
			}
			roots = append(roots, prefix+": "+strings.Join(volume.RootEntries, ", "))
		} else if volume.RootScanError != "" {
			roots = append(roots, i18n.T("installer.reason.unreadable"))
		}
	}

	sort.Strings(letters)
	sort.Strings(labels)
	sort.Strings(fileSystems)

	return DeviceRow{
		DiskNumber:   d.Number,
		Model:        d.DisplayName(),
		Capacity:     FormatBytes(d.SizeBytes),
		Letters:      emptyAsDash(strings.Join(uniqueStrings(letters), ", ")),
		Labels:       emptyAsDash(strings.Join(uniqueStrings(labels), ", ")),
		FileSystems:  emptyAsDash(strings.Join(uniqueStrings(fileSystems), ", ")),
		Used:         FormatBytes(used),
		RootContents: emptyAsDash(strings.Join(roots, " | ")),
		Selectable:   d.Eligible,
		Reason:       d.Reason,
	}
}

func FormatBytes(bytes uint64) string {
	const unit = uint64(1024)
	if bytes < unit {
		return fmt.Sprintf("%d B", bytes)
	}
	div := unit
	exp := 0
	for n := bytes / unit; n >= unit && exp < 5; n /= unit {
		div *= unit
		exp++
	}
	units := "KMGTPE"
	return fmt.Sprintf("%.1f %ciB", float64(bytes)/float64(div), units[exp])
}

func uniqueStrings(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func emptyAsDash(value string) string {
	if strings.TrimSpace(value) == "" {
		return "-"
	}
	return value
}
