// Package prefs stores per-user installer preferences in
// %APPDATA%\USOS\installer.ini (the same [ui] language= format the drive's
// usos-settings.ini uses). Nothing here is written to a USOS drive.
package prefs

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/snakex21/universal-service-os/installer/internal/i18n"
)

// FileName is the preferences file inside the per-user USOS directory.
const FileName = "installer.ini"

// DefaultPath returns %APPDATA%\USOS\installer.ini.
func DefaultPath() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "USOS", FileName), nil
}

// LoadLanguage returns the saved language code if the file exists and names a
// language with an embedded catalog.
func LoadLanguage(path string) (string, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	code, ok := i18n.ParseSettingsLanguage(data)
	if !ok || i18n.Normalize(code) != code {
		return "", false
	}
	return code, true
}

// SaveLanguage writes the language choice, creating the directory if needed.
func SaveLanguage(path, code string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create %s: %w", filepath.Dir(path), err)
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, i18n.SettingsINI(code), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// StartupLanguage picks the UI language: the saved choice, or on first run
// (no valid saved choice) the Windows display language.
func StartupLanguage(path string) string {
	if path != "" {
		if code, ok := LoadLanguage(path); ok {
			return code
		}
	}
	return i18n.SystemLanguage()
}
