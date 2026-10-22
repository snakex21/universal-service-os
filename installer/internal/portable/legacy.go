package portable

import (
	"os"
	"path/filepath"
)

// LegacyDirName is the folder under %APPDATA% used by older installers.
const LegacyDirName = "USOS"

// LegacyDir returns %APPDATA%\USOS ("" when unknown). It is the only place
// that resolves a user-profile directory, and callers only READ from it
// (one-time copy into data\); nothing is ever created, changed or deleted
// there. TestNoProfileOrTempDirectoryUse enforces this.
func LegacyDir() string {
	base, err := os.UserConfigDir()
	if err != nil || base == "" {
		return ""
	}
	return filepath.Join(base, LegacyDirName)
}

// LegacyPath returns name inside LegacyDir ("" when unknown), for reading.
func LegacyPath(name string) string {
	dir := LegacyDir()
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, name)
}
