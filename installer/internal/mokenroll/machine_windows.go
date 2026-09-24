//go:build windows

package mokenroll

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"unsafe"
)

var procGetSystemFirmwareTable = kernel32.NewProc("GetSystemFirmwareTable")

// MachineUUID returns this computer's SMBIOS system UUID (the same value
// USOS writes into its per-machine Secure Boot report).
func MachineUUID() (string, error) {
	const rsmb = 'R'<<24 | 'S'<<16 | 'M'<<8 | 'B'
	size, _, err := procGetSystemFirmwareTable.Call(rsmb, 0, 0, 0)
	if size == 0 {
		return "", err
	}
	buf := make([]byte, size)
	n, _, err := procGetSystemFirmwareTable.Call(rsmb, 0, uintptr(unsafe.Pointer(&buf[0])), size)
	if n == 0 || n > size {
		return "", err
	}
	id, ok := ParseSMBIOSUUID(buf[:n])
	if !ok {
		return "", errors.New("SMBIOS has no system UUID")
	}
	return id, nil
}

// AppDataDir is %APPDATA%\USOS.
func AppDataDir() string {
	base := os.Getenv("APPDATA")
	if base == "" {
		return ""
	}
	return filepath.Join(base, "USOS")
}

// RestartToFirmware restarts Windows into the UEFI firmware settings
// (shutdown /r /fw /t 0, which sets OsIndications BOOT_TO_FW_UI).
func RestartToFirmware() error {
	return runShutdown("/r", "/fw", "/t", "0")
}

// Restart restarts Windows now.
func Restart() error {
	return runShutdown("/r", "/t", "0")
}

func runShutdown(args ...string) error {
	system, err := windowsSystemDir()
	if err != nil {
		return err
	}
	cmd := exec.Command(filepath.Join(system, "shutdown.exe"), args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000} // CREATE_NO_WINDOW
	out, err := cmd.CombinedOutput()
	if err != nil {
		if len(out) > 0 {
			return errors.New(string(out))
		}
		return err
	}
	return nil
}

func windowsSystemDir() (string, error) {
	root := os.Getenv("SystemRoot")
	if root == "" {
		return "", errors.New("SystemRoot is not set")
	}
	return filepath.Join(root, "System32"), nil
}
