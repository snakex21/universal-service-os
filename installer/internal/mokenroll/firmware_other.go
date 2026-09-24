//go:build !windows

package mokenroll

type unsupportedFirmware struct{}

// System returns a Firmware whose calls all fail with ErrUnsupported.
func System() Firmware { return unsupportedFirmware{} }

func (unsupportedFirmware) UEFI() (bool, error) { return false, ErrUnsupported }

func (unsupportedFirmware) Get(string, GUID) ([]byte, uint32, error) {
	return nil, 0, ErrUnsupported
}

func (unsupportedFirmware) Set(string, GUID, []byte, uint32) error { return ErrUnsupported }
