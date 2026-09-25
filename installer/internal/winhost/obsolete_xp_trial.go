package winhost

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// obsoleteXPTrialDirectory is the per-ISO launcher folder the 2026-09-21 XP
// UEFI-CSM trial deploy (tools/deploy_xp_uefi_csm_trial.ps1, launcher mode)
// wrote to DATA and to the ESP. The unified menu starts EFI\USOS-XP itself,
// nothing reads the folder any more, and it only ever held generated
// launchers.
var obsoleteXPTrialDirectory = filepath.Join("Systems", "Windows", "Windows XP UEFI-CSM PAE")

var obsoleteXPTrialLauncher = regexp.MustCompile(`(?i)^XP-SP[23](-NiKKA)?-UEFI-CSM-PAE\.efi$`)

// A launcher was 57 344 bytes; anything much larger is not one of ours.
const obsoleteXPTrialLauncherMaxBytes = 1 << 20

// removeObsoleteXPTrialFolder deletes root\Systems\Windows\Windows XP
// UEFI-CSM PAE when it holds nothing but the generated launchers under
// Images (and empty folders). Any other file means the user put something
// there: the folder is left exactly as it is and kept=true is returned.
func removeObsoleteXPTrialFolder(root string) (removed bool, kept bool, err error) {
	dir := filepath.Join(root, obsoleteXPTrialDirectory)
	info, err := os.Lstat(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return false, false, nil
	}
	if err != nil {
		return false, false, fmt.Errorf("check %s: %w", obsoleteXPTrialDirectory, err)
	}
	if !info.IsDir() {
		return false, true, nil
	}
	userContent := false
	walkErr := filepath.WalkDir(dir, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if path == dir {
			return nil
		}
		rel, _ := filepath.Rel(dir, path)
		if entry.Type()&fs.ModeSymlink != 0 {
			userContent = true
			return filepath.SkipAll
		}
		if entry.IsDir() {
			if !strings.EqualFold(rel, "Images") {
				// Only Images\ was ever created; an empty extra folder still
				// counts as the user's.
				userContent = true
				return filepath.SkipAll
			}
			return nil
		}
		fileInfo, infoErr := entry.Info()
		if infoErr != nil {
			return infoErr
		}
		if !strings.EqualFold(filepath.Dir(rel), "Images") || !obsoleteXPTrialLauncher.MatchString(entry.Name()) || fileInfo.Size() > obsoleteXPTrialLauncherMaxBytes {
			userContent = true
			return filepath.SkipAll
		}
		return nil
	})
	if walkErr != nil {
		return false, false, fmt.Errorf("inspect %s: %w", obsoleteXPTrialDirectory, walkErr)
	}
	if userContent {
		return false, true, nil
	}
	if err := os.RemoveAll(dir); err != nil {
		return false, false, fmt.Errorf("remove %s: %w", obsoleteXPTrialDirectory, err)
	}
	return true, false, nil
}
