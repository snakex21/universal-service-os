//go:build windows

package mokenroll

import (
	"errors"
	"fmt"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	kernel32                              = windows.NewLazySystemDLL("kernel32.dll")
	advapi32                              = windows.NewLazySystemDLL("advapi32.dll")
	procGetFirmwareType                   = kernel32.NewProc("GetFirmwareType")
	procGetFirmwareEnvironmentVariableExW = kernel32.NewProc("GetFirmwareEnvironmentVariableExW")
	procSetFirmwareEnvironmentVariableExW = kernel32.NewProc("SetFirmwareEnvironmentVariableExW")
	procAdjustTokenPrivileges             = advapi32.NewProc("AdjustTokenPrivileges")
)

const (
	firmwareTypeBios = 1
	firmwareTypeUefi = 2

	errEnvvarNotFound     = windows.Errno(203)  // ERROR_ENVVAR_NOT_FOUND
	errInsufficientBuffer = windows.Errno(122)  // ERROR_INSUFFICIENT_BUFFER
	errInvalidFunction    = windows.Errno(1)    // ERROR_INVALID_FUNCTION (legacy BIOS)
	errPrivilegeNotHeld   = windows.Errno(1314) // ERROR_PRIVILEGE_NOT_HELD
	errNotAllAssigned     = windows.Errno(1300) // ERROR_NOT_ALL_ASSIGNED
)

type systemFirmware struct {
	once    sync.Once
	privErr error
}

// System returns the firmware of the running Windows. Every call enables
// SeSystemEnvironmentPrivilege for the process first (once).
func System() Firmware { return &systemFirmware{} }

func (f *systemFirmware) privilege() error {
	f.once.Do(func() { f.privErr = enableSystemEnvironmentPrivilege() })
	return f.privErr
}

func enableSystemEnvironmentPrivilege() error {
	var token windows.Token
	if err := windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_ADJUST_PRIVILEGES|windows.TOKEN_QUERY, &token); err != nil {
		return fmt.Errorf("OpenProcessToken: %w", err)
	}
	defer token.Close()
	var luid windows.LUID
	if err := windows.LookupPrivilegeValue(nil, windows.StringToUTF16Ptr("SeSystemEnvironmentPrivilege"), &luid); err != nil {
		return fmt.Errorf("LookupPrivilegeValue: %w", err)
	}
	privileges := windows.Tokenprivileges{PrivilegeCount: 1}
	privileges.Privileges[0] = windows.LUIDAndAttributes{Luid: luid, Attributes: windows.SE_PRIVILEGE_ENABLED}
	// Called directly: AdjustTokenPrivileges "succeeds" with
	// ERROR_NOT_ALL_ASSIGNED when the token lacks the privilege.
	r, _, lastErr := procAdjustTokenPrivileges.Call(uintptr(token), 0, uintptr(unsafe.Pointer(&privileges)), 0, 0, 0)
	if r == 0 {
		return fmt.Errorf("AdjustTokenPrivileges: %w", lastErr)
	}
	if errors.Is(lastErr, errNotAllAssigned) {
		return ErrPrivilege
	}
	return nil
}

func (f *systemFirmware) UEFI() (bool, error) {
	if procGetFirmwareType.Find() == nil {
		var kind uint32
		if r, _, _ := procGetFirmwareType.Call(uintptr(unsafe.Pointer(&kind))); r != 0 {
			switch kind {
			case firmwareTypeUefi:
				return true, nil
			case firmwareTypeBios:
				return false, nil
			}
		}
	}
	// Fallback: on legacy BIOS every firmware variable call fails with
	// ERROR_INVALID_FUNCTION.
	if err := f.privilege(); err != nil {
		return false, err
	}
	_, _, err := f.Get(VarSecureBoot, GlobalVariableGUID)
	if errors.Is(err, errInvalidFunction) {
		return false, nil
	}
	return true, nil
}

func (f *systemFirmware) Get(name string, vendor GUID) ([]byte, uint32, error) {
	if err := f.privilege(); err != nil {
		return nil, 0, err
	}
	namePtr, guidPtr, err := names(name, vendor)
	if err != nil {
		return nil, 0, err
	}
	for size := 4096; size <= 1<<20; size *= 4 {
		buf := make([]byte, size)
		var attrs uint32
		n, _, lastErr := procGetFirmwareEnvironmentVariableExW.Call(uintptr(unsafe.Pointer(namePtr)), uintptr(unsafe.Pointer(guidPtr)),
			uintptr(unsafe.Pointer(&buf[0])), uintptr(size), uintptr(unsafe.Pointer(&attrs)))
		if n != 0 {
			return buf[:n], attrs, nil
		}
		switch {
		case errors.Is(lastErr, errInsufficientBuffer):
			continue
		case errors.Is(lastErr, errEnvvarNotFound):
			return nil, 0, ErrNotFound
		case errors.Is(lastErr, errPrivilegeNotHeld):
			return nil, 0, ErrPrivilege
		}
		return nil, 0, fmt.Errorf("GetFirmwareEnvironmentVariableEx(%s): %w", name, lastErr)
	}
	return nil, 0, fmt.Errorf("GetFirmwareEnvironmentVariableEx(%s): variable larger than 1 MiB", name)
}

func (f *systemFirmware) Set(name string, vendor GUID, data []byte, attributes uint32) error {
	if err := f.privilege(); err != nil {
		return err
	}
	namePtr, guidPtr, err := names(name, vendor)
	if err != nil {
		return err
	}
	var ptr unsafe.Pointer
	if len(data) > 0 {
		ptr = unsafe.Pointer(&data[0])
	}
	r, _, lastErr := procSetFirmwareEnvironmentVariableExW.Call(uintptr(unsafe.Pointer(namePtr)), uintptr(unsafe.Pointer(guidPtr)),
		uintptr(ptr), uintptr(len(data)), uintptr(attributes))
	if r != 0 {
		return nil
	}
	switch {
	case len(data) == 0 && errors.Is(lastErr, errEnvvarNotFound):
		return nil // deleting a variable that is not there
	case errors.Is(lastErr, errPrivilegeNotHeld):
		return ErrPrivilege
	case errors.Is(lastErr, errInvalidFunction):
		return ErrNotUEFI
	}
	return fmt.Errorf("SetFirmwareEnvironmentVariableEx(%s): %w", name, lastErr)
}

func names(name string, vendor GUID) (*uint16, *uint16, error) {
	namePtr, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return nil, nil, err
	}
	guidPtr, err := windows.UTF16PtrFromString(vendor.String())
	if err != nil {
		return nil, nil, err
	}
	return namePtr, guidPtr, nil
}
