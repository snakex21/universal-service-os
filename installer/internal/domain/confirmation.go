package domain

import (
	"fmt"
	"strings"
	"time"

	"github.com/snakex21/universal-service-os/installer/internal/i18n"
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
			root = i18n.T("installer.reason.unreadable_detail", volume.RootScanError)
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
		Losses:       losses,
	}
}

// DestructiveConfirmDelay is how long the erase screen must be on display
// before its start button can be used, so a double click or a held Enter
// from the previous screen cannot start the erase.
const DestructiveConfirmDelay = 3 * time.Second

// DestructiveGate is the state of the erase confirmation: the user ticks
// "I understand that everything on this drive will be erased" and the
// screen must have been shown for DestructiveConfirmDelay.
type DestructiveGate struct {
	shownAt      time.Time
	acknowledged bool
}

func NewDestructiveGate(shownAt time.Time) DestructiveGate {
	return DestructiveGate{shownAt: shownAt}
}

func (g *DestructiveGate) Toggle() { g.acknowledged = !g.acknowledged }

func (g DestructiveGate) Acknowledged() bool { return g.acknowledged }

// Remaining is the part of the delay still to wait (0 once it has passed).
func (g DestructiveGate) Remaining(now time.Time) time.Duration {
	if g.shownAt.IsZero() {
		return DestructiveConfirmDelay
	}
	return max(0, DestructiveConfirmDelay-now.Sub(g.shownAt))
}

// RemainingSeconds rounds Remaining up to whole seconds for the countdown.
func (g DestructiveGate) RemainingSeconds(now time.Time) int {
	left := g.Remaining(now)
	return int((left + time.Second - 1) / time.Second)
}

// Ready reports whether the start button may be enabled.
func (g DestructiveGate) Ready(now time.Time) bool {
	return g.acknowledged && !g.shownAt.IsZero() && g.Remaining(now) == 0
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
