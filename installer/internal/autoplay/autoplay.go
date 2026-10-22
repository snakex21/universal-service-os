// Package autoplay turns Windows AutoPlay off while the installer creates
// and mounts volumes on the target, and always puts the user's setting back.
//
// It flips the same per-user switch as Settings > Devices > AutoPlay
// ("Use AutoPlay for all media and devices"):
// HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers
// DisableAutoplay. Before changing it, the previous state is written to a
// journal (data/autoplay-journal.json beside the EXE), so a crash or a killed process is
// repaired by RestorePending at the next installer start.
package autoplay

import (
	"fmt"
	"sync"
)

const (
	SettingKey   = `Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers`
	SettingValue = "DisableAutoplay"

	JournalKey = `Software\USOS\Installer`
	// journalPending = 1 while the setting is changed by the installer.
	journalPending = "AutoplayRestorePending"
	// journalExisted = 1 when DisableAutoplay existed before, then
	// journalValue holds its old data; 0 means the value is deleted again.
	journalExisted = "AutoplayPreviousExisted"
	journalValue   = "AutoplayPreviousValue"
)

// Store holds the OS setting and the portable restore journal; tests use a map.
type Store interface {
	GetDWORD(key, name string) (value uint32, exists bool, err error)
	SetDWORD(key, name string, value uint32) error
	DeleteValue(key, name string) error
}

var (
	mu     sync.Mutex
	active int    // nested Suppress calls
	cycle  uint64 // bumped by RestoreAtExit; older restore funcs then do nothing
	store  Store
)

// Suppress disables AutoPlay and returns the function that restores it.
// The restore function is safe to call more than once. Nested calls share
// one change; the setting comes back when the last one restores.
func Suppress(s Store) (func() error, error) {
	mu.Lock()
	defer mu.Unlock()
	if active == 0 {
		// A journal left by a crashed run holds the user's real setting.
		if err := restorePendingLocked(s); err != nil {
			return nil, err
		}
		value, exists, err := s.GetDWORD(SettingKey, SettingValue)
		if err != nil {
			return nil, fmt.Errorf("read AutoPlay setting: %w", err)
		}
		existed := uint32(0)
		if exists {
			existed = 1
		}
		if err := s.SetDWORD(JournalKey, journalExisted, existed); err != nil {
			return nil, fmt.Errorf("write AutoPlay restore journal: %w", err)
		}
		if err := s.SetDWORD(JournalKey, journalValue, value); err != nil {
			return nil, fmt.Errorf("write AutoPlay restore journal: %w", err)
		}
		if err := s.SetDWORD(JournalKey, journalPending, 1); err != nil {
			return nil, fmt.Errorf("write AutoPlay restore journal: %w", err)
		}
		if err := s.SetDWORD(SettingKey, SettingValue, 1); err != nil {
			_ = restorePendingLocked(s)
			return nil, fmt.Errorf("disable AutoPlay: %w", err)
		}
		store = s
	}
	active++
	myCycle := cycle
	var once sync.Once
	var restoreErr error
	return func() error {
		once.Do(func() {
			mu.Lock()
			defer mu.Unlock()
			if myCycle != cycle || active == 0 { // already restored by RestoreAtExit
				return
			}
			active--
			if active == 0 {
				restoreErr = restorePendingLocked(store)
				store = nil
			}
		})
		return restoreErr
	}, nil
}

// RestorePending puts back a setting left changed by an earlier run (crash,
// killed process, power loss). It does nothing while a Suppress is active
// in this process or when no journal exists.
func RestorePending(s Store) error {
	mu.Lock()
	defer mu.Unlock()
	if active > 0 {
		return nil
	}
	return restorePendingLocked(s)
}

func restorePendingLocked(s Store) error {
	pending, exists, err := s.GetDWORD(JournalKey, journalPending)
	if err != nil {
		return fmt.Errorf("read AutoPlay restore journal: %w", err)
	}
	if !exists || pending == 0 {
		return nil
	}
	existed, _, err := s.GetDWORD(JournalKey, journalExisted)
	if err != nil {
		return fmt.Errorf("read AutoPlay restore journal: %w", err)
	}
	value, _, err := s.GetDWORD(JournalKey, journalValue)
	if err != nil {
		return fmt.Errorf("read AutoPlay restore journal: %w", err)
	}
	if existed == 1 {
		err = s.SetDWORD(SettingKey, SettingValue, value)
	} else {
		err = s.DeleteValue(SettingKey, SettingValue)
	}
	if err != nil {
		return fmt.Errorf("restore AutoPlay setting: %w", err)
	}
	for _, name := range []string{journalPending, journalExisted, journalValue} {
		if err := s.DeleteValue(JournalKey, name); err != nil {
			return fmt.Errorf("clear AutoPlay restore journal: %w", err)
		}
	}
	return nil
}

// RestoreAtExit puts the setting back even while a suppression is still
// active (the window is closed before a session finished its delayed
// restore). Later calls of the returned restore functions do nothing.
func RestoreAtExit(s Store) error {
	mu.Lock()
	defer mu.Unlock()
	active, store = 0, nil
	cycle++
	return restorePendingLocked(s)
}
