package winhost

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/install"
)

const (
	maxProfileIconBytes = int64(1024 * 1024)
	maxUnattendBytes    = int64(4 * 1024 * 1024)
)

var pngSignature = []byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a}
var legacyCatalogImageExtensions = map[string]struct{}{
	".iso": {}, ".wim": {}, ".img": {}, ".vhd": {}, ".vhdx": {}, ".efi": {},
}

type catalogProfile struct {
	root    string
	profile dataProfile
}

func syncDataCatalog(media install.MediaLayout) error {
	if err := os.RemoveAll(filepath.Join(media.ESP.VolumePath, "EFI", "USOS", "ProfileIcons")); err != nil {
		return fmt.Errorf("remove obsolete ESP ProfileIcons cache: %w", err)
	}
	if err := os.RemoveAll(filepath.Join(media.ESP.VolumePath, "Systems")); err != nil {
		return fmt.Errorf("clear generated ESP Systems catalog: %w", err)
	}
	for _, profile := range catalogProfiles() {
		if err := syncCatalogProfile(media, profile); err != nil {
			return err
		}
	}
	return syncDynamicUtilitiesCatalog(media)
}

func catalogProfiles() []catalogProfile {
	profiles := make([]catalogProfile, 0, len(windowsProfiles)+len(linuxProfiles)+len(betaProfiles)+len(dosProfiles))
	appendProfiles := func(root string, source []dataProfile) {
		for _, profile := range source {
			profiles = append(profiles, catalogProfile{root: root, profile: profile})
		}
	}
	appendProfiles(filepath.Join("Systems", "Windows"), windowsProfiles)
	appendProfiles(filepath.Join("Systems", "Linux"), linuxProfiles)
	appendProfiles(filepath.Join("Systems", "Betas"), betaProfiles)
	appendProfiles(filepath.Join("Systems", "DOS"), dosProfiles)
	return profiles
}

func syncCatalogProfile(media install.MediaLayout, profile catalogProfile) error {
	relativeRoot := filepath.Join(profile.root, profile.profile.name)
	dataRoot := filepath.Join(media.DATA.VolumePath, relativeRoot)
	espRoot := filepath.Join(media.ESP.VolumePath, relativeRoot)
	if err := os.RemoveAll(espRoot); err != nil {
		return fmt.Errorf("clear ESP catalog profile %s: %w", relativeRoot, err)
	}
	if err := os.MkdirAll(filepath.Join(espRoot, "Images"), 0o755); err != nil {
		return fmt.Errorf("create ESP Images metadata %s: %w", relativeRoot, err)
	}
	if err := mirrorEspExecutableImages(filepath.Join(dataRoot, "Images"), filepath.Join(espRoot, "Images")); err != nil {
		return fmt.Errorf("sync EFI executable images %s: %w", relativeRoot, err)
	}
	if profile.profile.unattended {
		if err := os.MkdirAll(filepath.Join(espRoot, "Unattended"), 0o755); err != nil {
			return fmt.Errorf("create ESP Unattended metadata %s: %w", relativeRoot, err)
		}
		if err := mirrorUnattended(filepath.Join(dataRoot, "Unattended"), filepath.Join(espRoot, "Unattended")); err != nil {
			return fmt.Errorf("sync unattended catalog %s: %w", relativeRoot, err)
		}
	}
	if err := mirrorOptionalIcon(filepath.Join(dataRoot, "icon.png"), filepath.Join(espRoot, "icon.png")); err != nil {
		return fmt.Errorf("sync profile icon %s: %w", relativeRoot, err)
	}
	return nil
}

func syncDynamicUtilitiesCatalog(media install.MediaLayout) error {
	dataRoot := filepath.Join(media.DATA.VolumePath, "Utilities")
	espRoot := filepath.Join(media.ESP.VolumePath, "Utilities")
	if err := os.RemoveAll(espRoot); err != nil {
		return fmt.Errorf("clear ESP utilities catalog: %w", err)
	}
	if err := os.MkdirAll(espRoot, 0o755); err != nil {
		return fmt.Errorf("create ESP utilities catalog: %w", err)
	}
	entries, err := os.ReadDir(dataRoot)
	if err != nil {
		return fmt.Errorf("read DATA Utilities: %w", err)
	}
	for _, entry := range entries {
		if !entry.IsDir() || strings.HasPrefix(entry.Name(), ".") {
			continue
		}
		dataUtility := filepath.Join(dataRoot, entry.Name())
		espUtility := filepath.Join(espRoot, entry.Name())
		if err := os.MkdirAll(filepath.Join(espUtility, "Images"), 0o755); err != nil {
			return fmt.Errorf("create ESP utility metadata %s: %w", entry.Name(), err)
		}
		if err := mirrorEspExecutableImages(filepath.Join(dataUtility, "Images"), filepath.Join(espUtility, "Images")); err != nil {
			return fmt.Errorf("sync utility EFI executable images %s: %w", entry.Name(), err)
		}
		if err := mirrorOptionalIcon(filepath.Join(dataUtility, "icon.png"), filepath.Join(espUtility, "icon.png")); err != nil {
			return fmt.Errorf("sync utility icon %s: %w", entry.Name(), err)
		}
	}
	return nil
}

// RestoreLegacyImageMarkers recreates the pre-direct-NTFS ESP image catalog.
// It is not used by normal install/update flows; it exists only as a rollback
// escape hatch while physical Legacy NTFS discovery is being validated.
func RestoreLegacyImageMarkers(media install.MediaLayout) error {
	for _, profile := range catalogProfiles() {
		relativeRoot := filepath.Join(profile.root, profile.profile.name)
		if err := restoreLegacyImageDirectory(filepath.Join(media.DATA.VolumePath, relativeRoot, "Images"), filepath.Join(media.ESP.VolumePath, relativeRoot, "Images")); err != nil {
			return fmt.Errorf("restore legacy image markers %s: %w", relativeRoot, err)
		}
	}
	dataUtilities := filepath.Join(media.DATA.VolumePath, "Utilities")
	entries, err := os.ReadDir(dataUtilities)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("read DATA Utilities for rollback: %w", err)
	}
	for _, entry := range entries {
		if !entry.IsDir() || strings.HasPrefix(entry.Name(), ".") {
			continue
		}
		if err := restoreLegacyImageDirectory(filepath.Join(dataUtilities, entry.Name(), "Images"), filepath.Join(media.ESP.VolumePath, "Utilities", entry.Name(), "Images")); err != nil {
			return fmt.Errorf("restore legacy utility markers %s: %w", entry.Name(), err)
		}
	}
	return nil
}

func restoreLegacyImageDirectory(sourceDir, destinationDir string) error {
	if err := os.MkdirAll(destinationDir, 0o755); err != nil {
		return err
	}
	entries, err := os.ReadDir(sourceDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		ext := strings.ToLower(filepath.Ext(entry.Name()))
		if _, ok := legacyCatalogImageExtensions[ext]; !ok {
			continue
		}
		source := filepath.Join(sourceDir, entry.Name())
		destination := filepath.Join(destinationDir, entry.Name())
		if ext == ".efi" {
			if err := mirrorExecutableEFI(source, destination); err != nil {
				return err
			}
			continue
		}
		file, err := os.OpenFile(destination, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
		if err != nil {
			return err
		}
		if err := file.Close(); err != nil {
			return err
		}
	}
	return nil
}

func mirrorEspExecutableImages(sourceDir, destinationDir string) error {
	entries, err := os.ReadDir(sourceDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.EqualFold(filepath.Ext(entry.Name()), ".efi") {
			continue
		}
		source := filepath.Join(sourceDir, entry.Name())
		destination := filepath.Join(destinationDir, entry.Name())
		if err := mirrorExecutableEFI(source, destination); err != nil {
			return fmt.Errorf("copy EFI image %s: %w", entry.Name(), err)
		}
	}
	return nil
}

func mirrorExecutableEFI(source, destination string) error {
	info, err := os.Stat(source)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Size() <= 0 {
		return fmt.Errorf("EFI image is not a non-empty regular file")
	}
	copied, sourceHash, err := copyFileSyncHash(source, destination, nil)
	if err != nil {
		return err
	}
	if copied != uint64(info.Size()) {
		return fmt.Errorf("EFI copy size mismatch: got %d want %d", copied, info.Size())
	}
	destinationHash, err := hashFileSHA256(destination)
	if err != nil {
		return err
	}
	if destinationHash != sourceHash {
		return fmt.Errorf("EFI SHA-256 mismatch after copy")
	}
	return nil
}

func mirrorUnattended(sourceDir, destinationDir string) error {
	entries, err := os.ReadDir(sourceDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.EqualFold(filepath.Ext(entry.Name()), ".xml") {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if info.Size() <= 0 || info.Size() > maxUnattendBytes {
			return fmt.Errorf("unattended file %s has invalid size %d bytes", entry.Name(), info.Size())
		}
		source := filepath.Join(sourceDir, entry.Name())
		destination := filepath.Join(destinationDir, entry.Name())
		copied, sourceHash, err := copyFileSyncHash(source, destination, nil)
		if err != nil {
			return err
		}
		if copied != uint64(info.Size()) {
			return fmt.Errorf("unattended copy size mismatch for %s", entry.Name())
		}
		destinationHash, err := hashFileSHA256(destination)
		if err != nil {
			return err
		}
		if destinationHash != sourceHash {
			return fmt.Errorf("unattended SHA-256 mismatch for %s", entry.Name())
		}
	}
	return nil
}

func mirrorOptionalIcon(source, destination string) error {
	info, err := os.Stat(source)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("icon is not a regular file")
	}
	if info.Size() <= 0 || info.Size() > maxProfileIconBytes {
		return fmt.Errorf("icon has invalid size %d bytes; allowed 1..%d", info.Size(), maxProfileIconBytes)
	}
	if err := verifyPNGSignature(source); err != nil {
		return err
	}
	copied, sourceHash, err := copyFileSyncHash(source, destination, nil)
	if err != nil {
		return err
	}
	if copied != uint64(info.Size()) {
		return fmt.Errorf("icon copy size mismatch: got %d want %d", copied, info.Size())
	}
	destinationHash, err := hashFileSHA256(destination)
	if err != nil {
		return err
	}
	if destinationHash != sourceHash {
		return fmt.Errorf("icon SHA-256 mismatch after copy")
	}
	return nil
}

func verifyPNGSignature(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	buffer := make([]byte, len(pngSignature))
	if _, err := io.ReadFull(file, buffer); err != nil {
		return fmt.Errorf("cannot read PNG signature: %w", err)
	}
	if !bytes.Equal(buffer, pngSignature) {
		return fmt.Errorf("file is not a PNG image")
	}
	return nil
}
