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
	if key == JournalKey {
		journal, err := applicationJournal()
		if err != nil {
			return 0, false, err
		}
		return journal.get(name)
	}
	return registryGetDWORD(key, name)
}

func registryGetDWORD(key, name string) (uint32, bool, error) {
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
	if key == JournalKey {
		journal, err := applicationJournal()
		if err != nil {
			return err
		}
		return journal.set(name, value)
	}
	k, _, err := registry.CreateKey(registry.CURRENT_USER, key, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	return k.SetDWordValue(name, value)
}

func (CurrentUser) DeleteValue(key, name string) error {
	if key == JournalKey {
		journal, err := applicationJournal()
		if err != nil {
			return err
		}
		return journal.remove(name)
	}
	return registryDeleteValue(key, name)
}

func registryDeleteValue(key, name string) error {
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

// RestoreLegacyPending consumes a journal from an older installer. It can
// read/delete that old journal, but never writes application data to HKCU.
func RestoreLegacyPending() error { return RestorePending(legacyJournalStore{}) }

type legacyJournalStore struct{}

func (legacyJournalStore) GetDWORD(key, name string) (uint32, bool, error) {
	return registryGetDWORD(key, name)
}
func (legacyJournalStore) SetDWORD(key, name string, value uint32) error {
	if key == JournalKey {
		return errors.New("legacy restore journal is read-only")
	}
	return (CurrentUser{}).SetDWORD(key, name, value)
}
func (legacyJournalStore) DeleteValue(key, name string) error {
	return registryDeleteValue(key, name)
}
