package autoplay

import (
	"errors"
	"testing"
)

type mapStore struct {
	values  map[string]uint32
	failSet string
}

func newMapStore() *mapStore { return &mapStore{values: map[string]uint32{}} }

func (m *mapStore) GetDWORD(key, name string) (uint32, bool, error) {
	v, ok := m.values[key+`\`+name]
	return v, ok, nil
}

func (m *mapStore) SetDWORD(key, name string, value uint32) error {
	if m.failSet == name {
		return errors.New("access denied")
	}
	m.values[key+`\`+name] = value
	return nil
}

func (m *mapStore) DeleteValue(key, name string) error {
	delete(m.values, key+`\`+name)
	return nil
}

func (m *mapStore) setting() (uint32, bool) {
	v, ok := m.values[SettingKey+`\`+SettingValue]
	return v, ok
}

func (m *mapStore) journalEmpty() bool {
	for _, name := range []string{journalPending, journalExisted, journalValue} {
		if _, ok := m.values[JournalKey+`\`+name]; ok {
			return false
		}
	}
	return true
}

func TestSuppressRestoresMissingValue(t *testing.T) {
	s := newMapStore()
	restore, err := Suppress(s)
	if err != nil {
		t.Fatal(err)
	}
	if v, ok := s.setting(); !ok || v != 1 {
		t.Fatalf("AutoPlay not disabled: %v %v", v, ok)
	}
	if s.journalEmpty() {
		t.Fatal("no restore journal written before the change")
	}
	if err := restore(); err != nil {
		t.Fatal(err)
	}
	if _, ok := s.setting(); ok {
		t.Fatal("value that did not exist was left behind")
	}
	if !s.journalEmpty() {
		t.Fatal("journal not cleared")
	}
	if err := restore(); err != nil {
		t.Fatal("second restore must be a no-op")
	}
}

func TestSuppressRestoresUserChoice(t *testing.T) {
	for _, before := range []uint32{0, 1} {
		s := newMapStore()
		s.values[SettingKey+`\`+SettingValue] = before
		restore, err := Suppress(s)
		if err != nil {
			t.Fatal(err)
		}
		if err := restore(); err != nil {
			t.Fatal(err)
		}
		if v, ok := s.setting(); !ok || v != before {
			t.Fatalf("restored %v/%v, want %v", v, ok, before)
		}
	}
}

func TestCrashIsRepairedAtNextStart(t *testing.T) {
	s := newMapStore()
	s.values[SettingKey+`\`+SettingValue] = 0
	if _, err := Suppress(s); err != nil {
		t.Fatal(err)
	}
	// Simulate the process dying without restoring.
	mu.Lock()
	active, store = 0, nil
	mu.Unlock()
	if v, _ := s.setting(); v != 1 {
		t.Fatal("setup: AutoPlay should be disabled")
	}
	if err := RestorePending(s); err != nil {
		t.Fatal(err)
	}
	if v, ok := s.setting(); !ok || v != 0 {
		t.Fatalf("crash not repaired: %v/%v", v, ok)
	}
	if !s.journalEmpty() {
		t.Fatal("journal not cleared after repair")
	}
}

func TestSuppressAfterCrashKeepsTheRealOriginal(t *testing.T) {
	s := newMapStore()
	s.values[SettingKey+`\`+SettingValue] = 0
	if _, err := Suppress(s); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	active, store = 0, nil
	mu.Unlock()
	// Next run suppresses again without calling RestorePending first.
	restore, err := Suppress(s)
	if err != nil {
		t.Fatal(err)
	}
	if err := restore(); err != nil {
		t.Fatal(err)
	}
	if v, ok := s.setting(); !ok || v != 0 {
		t.Fatalf("original lost across a crash: %v/%v", v, ok)
	}
}

func TestNestedSuppressRestoresOnLast(t *testing.T) {
	s := newMapStore()
	r1, err := Suppress(s)
	if err != nil {
		t.Fatal(err)
	}
	r2, err := Suppress(s)
	if err != nil {
		t.Fatal(err)
	}
	if err := RestorePending(s); err != nil || s.journalEmpty() {
		t.Fatal("RestorePending must not undo an active suppression")
	}
	_ = r1()
	if v, _ := s.setting(); v != 1 {
		t.Fatal("restored while another suppression is active")
	}
	_ = r2()
	if _, ok := s.setting(); ok || !s.journalEmpty() {
		t.Fatal("not restored after the last suppression")
	}
}

func TestFailedDisableLeavesNothingChanged(t *testing.T) {
	s := newMapStore()
	s.failSet = SettingValue
	if _, err := Suppress(s); err == nil {
		t.Fatal("expected error")
	}
	if _, ok := s.setting(); ok || !s.journalEmpty() {
		t.Fatalf("partial change left behind: %v", s.values)
	}
	mu.Lock()
	defer mu.Unlock()
	if active != 0 {
		t.Fatalf("active=%d after failure", active)
	}
}

func TestRestoreAtExitWinsOverActiveSuppression(t *testing.T) {
	s := newMapStore()
	s.values[SettingKey+`\`+SettingValue] = 0
	restore, err := Suppress(s)
	if err != nil {
		t.Fatal(err)
	}
	if err := RestoreAtExit(s); err != nil {
		t.Fatal(err)
	}
	if v, ok := s.setting(); !ok || v != 0 || !s.journalEmpty() {
		t.Fatalf("not restored at exit: %v/%v", v, ok)
	}
	// A new suppression after that still works, and the stale restore
	// function of the old cycle cannot end it early.
	r, err := Suppress(s)
	if err != nil {
		t.Fatal(err)
	}
	_ = restore()
	if v, _ := s.setting(); v != 1 {
		t.Fatal("stale restore ended the new suppression")
	}
	_ = r()
	if v, _ := s.setting(); v != 0 {
		t.Fatal("second cycle lost the user choice")
	}
}
