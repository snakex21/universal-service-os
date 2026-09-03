//go:build windows

package winhost

import (
	"fmt"

	"github.com/snakex21/universal-service-os/installer/internal/installed"
)

func (Backend) RevalidateInstalledUSOS(expected installed.Target) (installed.Target, error) {
	if err := refuseRunningFromTarget(expected.Disk.Number); err != nil {
		return installed.Target{}, err
	}
	current, err := inspectInstalledUSOS(expected.Disk)
	if err != nil {
		return installed.Target{}, fmt.Errorf("revalidate installed USOS: %w", err)
	}
	if current.Identity != expected.Identity {
		return installed.Target{}, fmt.Errorf("usos-device.ini changed since selection")
	}
	if current.Media.DiskPTUUID != expected.Media.DiskPTUUID ||
		current.Media.ESP.PartUUID != expected.Media.ESP.PartUUID ||
		current.Media.DATA.PartUUID != expected.Media.DATA.PartUUID ||
		current.Media.WORK.PartUUID != expected.Media.WORK.PartUUID ||
		current.Media.ESP.StartBytes != expected.Media.ESP.StartBytes ||
		current.Media.DATA.StartBytes != expected.Media.DATA.StartBytes ||
		current.Media.WORK.StartBytes != expected.Media.WORK.StartBytes ||
		current.Media.ESP.SizeBytes != expected.Media.ESP.SizeBytes ||
		current.Media.DATA.SizeBytes != expected.Media.DATA.SizeBytes ||
		current.Media.WORK.SizeBytes != expected.Media.WORK.SizeBytes {
		return installed.Target{}, fmt.Errorf("GPT identity/layout changed since selection")
	}
	return current, nil
}
