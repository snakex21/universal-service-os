package domain

import (
	"fmt"
	"strings"
)

type LossItem struct {
	Volume      string
	FileSystem  string
	Capacity    string
	Used        string
	RootContent string
}

type Confirmation struct {
	DiskModel    string
	DiskNumber   uint32
	DiskSerial   string
	DiskCapacity string
	ExpectedText string
	Losses       []LossItem
}

func BuildConfirmation(d Disk) Confirmation {
	losses := make([]LossItem, 0, len(d.Volumes))
	for _, volume := range d.Volumes {
		name := strings.Join(volume.MountPaths, ", ")
		if strings.TrimSpace(name) == "" {
			name = volume.GUIDPath
		}
		if volume.Label != "" {
			name += " [" + volume.Label + "]"
		}
		root := "-"
		if len(volume.RootEntries) > 0 {
			root = strings.Join(volume.RootEntries, ", ")
		} else if volume.RootScanError != "" {
			root = "odczyt niedostępny: " + volume.RootScanError
		}
		losses = append(losses, LossItem{
			Volume:      name,
			FileSystem:  emptyAsDash(volume.FileSystem),
			Capacity:    FormatBytes(volume.TotalBytes),
			Used:        FormatBytes(volume.UsedBytes),
			RootContent: root,
		})
	}
	return Confirmation{
		DiskModel:    d.DisplayName(),
		DiskNumber:   d.Number,
		DiskSerial:   displaySerialOrDash(d),
		DiskCapacity: FormatBytes(d.SizeBytes),
		ExpectedText: d.ConfirmationValue(),
		Losses:       losses,
	}
}

func (c Confirmation) Accepts(input string) bool {
	return input == c.ExpectedText
}

func displaySerialOrDash(d Disk) string {
	if s := d.DisplaySerial(); s != "" {
		return s
	}
	return "-"
}

func (c Confirmation) DestructiveSummary() string {
	return fmt.Sprintf("PhysicalDrive%d - %s - %s - serial %s", c.DiskNumber, c.DiskModel, c.DiskCapacity, c.DiskSerial)
}
