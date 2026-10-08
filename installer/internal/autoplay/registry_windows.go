//go:build windows

package autoplay

import (
	"errors"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

// CurrentUser is the Store for HKEY_CURRENT_USER.
type CurrentUser struct{}

func (CurrentUser) GetDWORD(key, name string) (uint32, bool, error) {
	k, err := registry.OpenKey(registry.CURRENT_USER, key, registry.QUERY_VALUE)
	if errors.Is(err, windows.ERROR_FILE_NOT_FOUND) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	defer k.Close()
	value, _, err := k.GetIntegerValue(name)
	if errors.Is(err, windows.ERROR_FILE_NOT_FOUND) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	return uint32(value), true, nil
}

func (CurrentUser) SetDWORD(key, name string, value uint32) error {
	k, _, err := registry.CreateKey(registry.CURRENT_USER, key, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	return k.SetDWordValue(name, value)
}

func (CurrentUser) DeleteValue(key, name string) error {
	k, err := registry.OpenKey(registry.CURRENT_USER, key, registry.SET_VALUE)
	if errors.Is(err, windows.ERROR_FILE_NOT_FOUND) {
		return nil
	}
	if err != nil {
		return err
	}
	defer k.Close()
	if err := k.DeleteValue(name); err != nil && !errors.Is(err, windows.ERROR_FILE_NOT_FOUND) {
		return err
	}
	return nil
}
