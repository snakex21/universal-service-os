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

// MachineUUID is only implemented on Windows.
func MachineUUID() (string, error) { return "", ErrUnsupported }

// AppDataDir is only implemented on Windows.
func AppDataDir() string { return "" }

// RestartToFirmware is only implemented on Windows.
func RestartToFirmware() error { return ErrUnsupported }

// Restart is only implemented on Windows.
func Restart() error { return ErrUnsupported }
