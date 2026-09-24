package winhost

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/install"
)

func verifyDataCatalogMatches(media install.MediaLayout) error {
	for _, profile := range catalogProfiles() {
		if err := verifyCatalogProfileMatches(media, profile); err != nil {
			return err
		}
	}
	return verifyDynamicUtilitiesCatalogMatches(media)
}

func verifyCatalogProfileMatches(media install.MediaLayout, profile catalogProfile) error {
	relativeRoot := filepath.Join(profile.root, profile.profile.name)
	dataRoot := filepath.Join(media.DATA.VolumePath, relativeRoot)
	espRoot := filepath.Join(media.ESP.VolumePath, relativeRoot)
	if err := verifyEspImageProjection(filepath.Join(dataRoot, "Images"), filepath.Join(espRoot, "Images")); err != nil {
		return fmt.Errorf("%s Images: %w", relativeRoot, err)
	}
	if profile.profile.unattended {
		if err := compareCatalogXmlFiles(filepath.Join(dataRoot, "Unattended"), filepath.Join(espRoot, "Unattended")); err != nil {
			return fmt.Errorf("%s Unattended: %w", relativeRoot, err)
		}
	}
	if err := compareOptionalFile(filepath.Join(dataRoot, "icon.png"), filepath.Join(espRoot, "icon.png")); err != nil {
		return fmt.Errorf("%s icon.png: %w", relativeRoot, err)
	}
	return nil
}

func verifyDynamicUtilitiesCatalogMatches(media install.MediaLayout) error {
	dataRoot := filepath.Join(media.DATA.VolumePath, "Utilities")
	espRoot := filepath.Join(media.ESP.VolumePath, "Utilities")
	dataNames, err := directoryNames(dataRoot)
	if err != nil {
		return fmt.Errorf("read DATA Utilities: %w", err)
	}
	espNames, err := directoryNames(espRoot)
	if err != nil {
		return fmt.Errorf("read ESP Utilities: %w", err)
	}
	if !equalStringSets(dataNames, espNames) {
		return fmt.Errorf("utility folder list mismatch: DATA=%v ESP=%v", dataNames, espNames)
	}
	for _, name := range dataNames {
		dataUtility := filepath.Join(dataRoot, name)
		espUtility := filepath.Join(espRoot, name)
		if err := verifyEspImageProjection(filepath.Join(dataUtility, "Images"), filepath.Join(espUtility, "Images")); err != nil {
			return fmt.Errorf("utility %s Images: %w", name, err)
		}
		if err := compareOptionalFile(filepath.Join(dataUtility, "icon.png"), filepath.Join(espUtility, "icon.png")); err != nil {
			return fmt.Errorf("utility %s icon.png: %w", name, err)
		}
	}
	return nil
}

func verifyEspImageProjection(dataDir, espDir string) error {
	dataEFI, err := filteredNames(dataDir, func(name string) bool { return strings.EqualFold(filepath.Ext(name), ".efi") })
	if err != nil {
		return err
	}
	espFiles, err := filteredNames(espDir, func(string) bool { return true })
	if err != nil {
		return err
	}
	if !equalStringSets(dataEFI, espFiles) {
		return fmt.Errorf("ESP Images must contain only executable EFI mirrors: DATA EFI=%v ESP=%v", dataEFI, espFiles)
	}
	for _, name := range dataEFI {
		if err := compareOptionalFile(filepath.Join(dataDir, name), filepath.Join(espDir, name)); err != nil {
			return fmt.Errorf("EFI executable mirror %s: %w", name, err)
		}
	}
	return nil
}

func compareCatalogXmlFiles(dataDir, espDir string) error {
	data, err := filteredNames(dataDir, isAnswerFileName)
	if err != nil {
		return err
	}
	esp, err := filteredNames(espDir, isAnswerFileName)
	if err != nil {
		return err
	}
	if !equalStringSets(data, esp) {
		return fmt.Errorf("answer-file catalog names differ: DATA=%v ESP=%v", data, esp)
	}
	for _, name := range data {
		dataHash, err := hashFileSHA256(filepath.Join(dataDir, name))
		if err != nil {
			return err
		}
		espHash, err := hashFileSHA256(filepath.Join(espDir, name))
		if err != nil {
			return err
		}
		if dataHash != espHash {
			return fmt.Errorf("answer-file SHA-256 mismatch for %s", name)
		}
	}
	return nil
}

func compareOptionalFile(dataPath, espPath string) error {
	dataInfo, dataErr := os.Stat(dataPath)
	if dataErr != nil {
		if !os.IsNotExist(dataErr) {
			return dataErr
		}
		if _, espErr := os.Stat(espPath); espErr == nil {
			return fmt.Errorf("stale ESP file exists while DATA file is absent")
		} else if !os.IsNotExist(espErr) {
			return espErr
		}
		return nil
	}
	if !dataInfo.Mode().IsRegular() {
		return fmt.Errorf("DATA file is not regular")
	}
	dataHash, err := hashFileSHA256(dataPath)
	if err != nil {
		return err
	}
	espHash, err := hashFileSHA256(espPath)
	if err != nil {
		return err
	}
	if dataHash != espHash {
		return fmt.Errorf("SHA-256 mismatch")
	}
	return nil
}

func directoryNames(root string) ([]string, error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, entry := range entries {
		if entry.IsDir() && !strings.HasPrefix(entry.Name(), ".") {
			names = append(names, entry.Name())
		}
	}
	sort.Slice(names, func(i, j int) bool { return strings.ToLower(names[i]) < strings.ToLower(names[j]) })
	return names, nil
}

func filteredNames(root string, keep func(string) bool) ([]string, error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		if os.IsNotExist(err) {
			return []string{}, nil
		}
		return nil, err
	}
	var names []string
	for _, entry := range entries {
		if !entry.IsDir() && keep(entry.Name()) {
			names = append(names, entry.Name())
		}
	}
	sort.Slice(names, func(i, j int) bool { return strings.ToLower(names[i]) < strings.ToLower(names[j]) })
	return names, nil
}

func equalStringSets(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if !strings.EqualFold(left[index], right[index]) {
			return false
		}
	}
	return true
}
