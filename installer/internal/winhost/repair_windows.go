//go:build windows

package winhost

import (
	"fmt"

	"github.com/snakex21/universal-service-os/installer/internal/install"
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
	if !sameDeviceIdentity(current.Identity, expected.Identity) {
		return installed.Target{}, fmt.Errorf("usos-device.ini changed since selection")
	}
	if !equalGUIDText(current.Media.DiskPTUUID, expected.Media.DiskPTUUID) ||
		!equalGUIDText(current.Media.ESP.PartUUID, expected.Media.ESP.PartUUID) ||
		!equalGUIDText(current.Media.DATA.PartUUID, expected.Media.DATA.PartUUID) ||
		!equalGUIDText(current.Media.WORK.PartUUID, expected.Media.WORK.PartUUID) ||
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

func sameDeviceIdentity(a, b install.DeviceINI) bool {
	return a.Nonce == b.Nonce &&
		equalGUIDText(a.DiskPTUUID, b.DiskPTUUID) &&
		equalGUIDText(a.ESPPartUUID, b.ESPPartUUID) &&
		equalGUIDText(a.DataPartUUID, b.DataPartUUID) &&
		equalGUIDText(a.WorkPartUUID, b.WorkPartUUID) &&
		a.WorkLabel == b.WorkLabel &&
		a.DataLabel == b.DataLabel &&
		a.WorkBytes == b.WorkBytes
}
