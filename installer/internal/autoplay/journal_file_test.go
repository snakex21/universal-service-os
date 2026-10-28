package autoplay

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFileJournalSurvivesRestartAndClears(t *testing.T) {
	path := filepath.Join(t.TempDir(), "data", "autoplay-journal.json")
	first := fileJournal{path}
	if err := first.set(journalExisted, 1); err != nil {
		t.Fatal(err)
	}
	if err := first.set(journalValue, 0); err != nil {
		t.Fatal(err)
	}
	if err := first.set(journalPending, 1); err != nil {
		t.Fatal(err)
	}
	second := fileJournal{path}
	if v, ok, err := second.get(journalPending); err != nil || !ok || v != 1 {
		t.Fatalf("%d %v %v", v, ok, err)
	}
	for _, name := range []string{journalPending, journalExisted, journalValue} {
		if err := second.remove(name); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("journal remains: %v", err)
	}
	if _, ok, err := second.get(journalPending); err != nil || ok {
		t.Fatalf("missing journal: %v %v", ok, err)
	}
}

func TestCorruptFileJournalIsNotSilentlyOverwritten(t *testing.T) {
	path := filepath.Join(t.TempDir(), "journal.json")
	original := []byte("corrupt pending journal")
	if err := os.WriteFile(path, original, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := (fileJournal{path}).set(journalPending, 1); err == nil {
		t.Fatal("corrupt journal accepted")
	}
	data, _ := os.ReadFile(path)
	if string(data) != string(original) {
		t.Fatal("lost pending journal")
	}
}
