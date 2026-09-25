package winhost

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// ensureXPSettingsFile creates the inactive usos-xp.ini when it is missing
// and never touches an existing one.
func ensureXPSettingsFile(dataRoot string) error {
	path := filepath.Join(dataRoot, xpSettingsDirectory, xpSettingsFileName)
	if _, err := os.Stat(path); err == nil {
		return nil
	} else if !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("check %s: %w", xpSettingsFileName, err)
	}
	if err := writeFileSync(path, xpSettingsExample.contents); err != nil {
		return fmt.Errorf("create %s: %w", xpSettingsFileName, err)
	}
	return verifyFileMatchesBytes(path, xpSettingsExample.contents)
}
