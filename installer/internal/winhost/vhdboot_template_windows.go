//go:build windows

package winhost

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const vhdBootTemplateDirectory = "VHDBoot"

type vhdBootImage struct {
	relativePath string
}

func ensureVHDBootTemplates(dataRoot string) error {
	images, err := findWindowsVHDImages(dataRoot)
	if err != nil {
		return err
	}
	root := dataProgramFile(dataRoot, vhdBootTemplateDirectory)
	if err := os.RemoveAll(root); err != nil {
		return fmt.Errorf("clear VHDBoot templates: %w", err)
	}
	if len(images) == 0 {
		return nil
	}

	windowsRoot := os.Getenv("WINDIR")
	if windowsRoot == "" {
		return fmt.Errorf("WINDIR is empty; cannot build VHDBoot templates")
	}
	sourceEFI := filepath.Join(windowsRoot, "Boot", "EFI")
	sourceFonts := filepath.Join(windowsRoot, "Boot", "Fonts")
	bootManager := filepath.Join(sourceEFI, "bootmgfw.efi")
	bcdedit := filepath.Join(windowsRoot, "System32", "bcdedit.exe")
	for _, required := range []string{sourceEFI, sourceFonts, bootManager, bcdedit} {
		if _, err := os.Stat(required); err != nil {
			return fmt.Errorf("VHDBoot host prerequisite missing %s: %w", required, err)
		}
	}

	shared := filepath.Join(root, "Shared")
	microsoftBoot := filepath.Join(shared, "EFI", "Microsoft", "Boot")
	if err := copyDirectoryTree(sourceEFI, microsoftBoot); err != nil {
		return fmt.Errorf("copy VHDBoot EFI files: %w", err)
	}
	if err := copyDirectoryTree(sourceFonts, filepath.Join(microsoftBoot, "Fonts")); err != nil {
		return fmt.Errorf("copy VHDBoot fonts: %w", err)
	}
	fallbackName, err := fallbackEFIName()
	if err != nil {
		return err
	}
	if _, _, err := copyFileSyncHash(bootManager, filepath.Join(shared, "EFI", "BOOT", fallbackName), nil); err != nil {
		return fmt.Errorf("copy VHDBoot fallback boot manager: %w", err)
	}
	_ = os.Remove(filepath.Join(microsoftBoot, "BCD"))

	for _, image := range images {
		entryRoot := filepath.Join(root, "Entries", filepath.FromSlash(image.relativePath))
		bcdPath := filepath.Join(entryRoot, "BCD")
		if err := createVHDBootBCD(bcdedit, bcdPath, image.relativePath); err != nil {
			return fmt.Errorf("build VHDBoot BCD for %s: %w", image.relativePath, err)
		}
	}
	return verifyVHDBootTemplates(dataRoot)
}

func findWindowsVHDImages(dataRoot string) ([]vhdBootImage, error) {
	windowsRoot := filepath.Join(dataRoot, "Systems", "Windows")
	profiles, err := os.ReadDir(windowsRoot)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var result []vhdBootImage
	for _, profile := range profiles {
		if !profile.IsDir() {
			continue
		}
		imagesRoot := filepath.Join(windowsRoot, profile.Name(), "Images")
		entries, err := os.ReadDir(imagesRoot)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return nil, err
		}
		for _, entry := range entries {
			if entry.IsDir() {
				continue
			}
			ext := strings.ToLower(filepath.Ext(entry.Name()))
			if ext != ".vhd" && ext != ".vhdx" {
				continue
			}
			relative := filepath.ToSlash(filepath.Join("Systems", "Windows", profile.Name(), "Images", entry.Name()))
			result = append(result, vhdBootImage{relativePath: relative})
		}
	}
	return result, nil
}

func createVHDBootBCD(bcdeditPath, storePath, relativeVHD string) error {
	if err := os.MkdirAll(filepath.Dir(storePath), 0o755); err != nil {
		return err
	}
	_ = os.Remove(storePath)
	if _, err := runBCD(bcdeditPath, "/createstore", storePath); err != nil {
		return err
	}
	for _, args := range [][]string{
		{"/store", storePath, "/create", "{bootmgr}", "/d", "USOS VHDBoot Manager"},
		{"/store", storePath, "/set", "{bootmgr}", "device", "boot"},
	} {
		if _, err := runBCD(bcdeditPath, args...); err != nil {
			return err
		}
	}
	output, err := runBCD(bcdeditPath, "/store", storePath, "/create", "/d", "USOS VHD", "/application", "osloader")
	if err != nil {
		return err
	}
	guid := bcdGUIDPattern.FindString(output)
	if guid == "" {
		return fmt.Errorf("bcdedit did not return VHDBoot loader GUID: %s", strings.TrimSpace(output))
	}
	vhdPath := `vhd=[locate]\` + strings.ReplaceAll(relativeVHD, "/", `\`)
	commands := [][]string{
		{"/store", storePath, "/set", guid, "device", vhdPath},
		{"/store", storePath, "/set", guid, "osdevice", vhdPath},
		{"/store", storePath, "/set", guid, "path", `\Windows\system32\winload.efi`},
		{"/store", storePath, "/set", guid, "systemroot", `\Windows`},
		{"/store", storePath, "/set", guid, "detecthal", "yes"},
		{"/store", storePath, "/displayorder", guid, "/addlast"},
		{"/store", storePath, "/default", guid},
		{"/store", storePath, "/timeout", "0"},
	}
	for _, args := range commands {
		if _, err := runBCD(bcdeditPath, args...); err != nil {
			return err
		}
	}
	return nil
}

func verifyVHDBootTemplates(dataRoot string) error {
	images, err := findWindowsVHDImages(dataRoot)
	if err != nil {
		return err
	}
	if len(images) == 0 {
		return nil
	}
	fallbackName, err := fallbackEFIName()
	if err != nil {
		return err
	}
	root := dataProgramFile(dataRoot, vhdBootTemplateDirectory)
	sharedEFI := filepath.Join(root, "Shared", "EFI", "BOOT", fallbackName)
	if info, err := os.Stat(sharedEFI); err != nil || !info.Mode().IsRegular() || info.Size() <= 0 {
		if err != nil {
			return fmt.Errorf("VHDBoot shared EFI missing: %w", err)
		}
		return fmt.Errorf("VHDBoot shared EFI is empty")
	}
	for _, image := range images {
		bcdPath := filepath.Join(root, "Entries", filepath.FromSlash(image.relativePath), "BCD")
		info, err := os.Stat(bcdPath)
		if err != nil {
			return fmt.Errorf("VHDBoot BCD missing for %s: %w", image.relativePath, err)
		}
		if !info.Mode().IsRegular() || info.Size() <= 0 {
			return fmt.Errorf("VHDBoot BCD is empty for %s", image.relativePath)
		}
	}
	return nil
}
