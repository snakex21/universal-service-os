//go:build windows

package main

import (
	"time"

	"github.com/snakex21/universal-service-os/installer/internal/mokenroll"
)

// fakeMokFirmware stands in for the UEFI variable store so the demo's
// "prepare key enrollment" never writes this computer's NVRAM.
type fakeMokFirmware struct {
	vars map[string][]byte
}

func (f *fakeMokFirmware) UEFI() (bool, error) { return true, nil }

func (f *fakeMokFirmware) Get(name string, vendor mokenroll.GUID) ([]byte, uint32, error) {
	if name == mokenroll.VarSecureBoot {
		return []byte{1}, mokenroll.AttrBootServiceAccess | mokenroll.AttrRuntimeAccess, nil
	}
	v, ok := f.vars[vendor.String()+name]
	if !ok {
		return nil, 0, mokenroll.ErrNotFound
	}
	return v, mokenroll.MokAttributes, nil
}

func (f *fakeMokFirmware) Set(name string, vendor mokenroll.GUID, data []byte, _ uint32) error {
	time.Sleep(300 * time.Millisecond) // NVRAM writes are not instant
	if len(data) == 0 {
		delete(f.vars, vendor.String()+name)
		return nil
	}
	f.vars[vendor.String()+name] = append([]byte(nil), data...)
	return nil
}
