package prefs

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/i18n"
)

func TestSaveAndLoadLanguage(t *testing.T) {
	path := filepath.Join(t.TempDir(), "USOS", FileName)
	if _, ok := LoadLanguage(path); ok {
		t.Fatal("missing file must not yield a language")
	}
	if got := StartupLanguage(path); got != i18n.SystemLanguage() {
		t.Fatalf("first run language = %q, want system %q", got, i18n.SystemLanguage())
	}
	if err := SaveLanguage(path, "pl"); err != nil {
		t.Fatal(err)
	}
	if got, ok := LoadLanguage(path); !ok || got != "pl" {
		t.Fatalf("LoadLanguage = %q, %v", got, ok)
	}
	if got := StartupLanguage(path); got != "pl" {
		t.Fatalf("StartupLanguage = %q, want saved pl", got)
	}
	if err := SaveLanguage(path, "en"); err != nil {
		t.Fatal(err)
	}
	if got := StartupLanguage(path); got != "en" {
		t.Fatalf("StartupLanguage after change = %q", got)
	}
}

func TestUnknownSavedLanguageFallsBackToSystem(t *testing.T) {
	path := filepath.Join(t.TempDir(), FileName)
	if err := os.WriteFile(path, []byte("[ui]\r\nlanguage=xx\r\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, ok := LoadLanguage(path); ok {
		t.Fatal("unknown language must be ignored")
	}
	if got := StartupLanguage(path); got != i18n.SystemLanguage() {
		t.Fatalf("got %q", got)
	}
}
