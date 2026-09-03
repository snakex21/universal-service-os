//go:build windows

package winhost

import (
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
)

const wimBootTemplateDirectory = "WimBootTemplate"

var bcdGUIDPattern = regexp.MustCompile(`\{[0-9a-fA-F-]{36}\}`)

func ensureWimBootTemplate(dataRoot string) error {
	hasWIM, err := hasWindowsWIMImages(dataRoot)
	if err != nil {
		return err
	}
	if !hasWIM {
		return nil
	}

	windowsRoot := os.Getenv("WINDIR")
	if windowsRoot == "" {
		return fmt.Errorf("WINDIR is empty; cannot build WIMBoot template")
	}

	sourceEFI := filepath.Join(windowsRoot, "Boot", "EFI")
	sourceFonts := filepath.Join(windowsRoot, "Boot", "Fonts")
	sourceSDI := filepath.Join(windowsRoot, "Boot", "DVD", "EFI", "boot.sdi")
	if _, err := os.Stat(sourceSDI); err != nil {
		sourceSDI = filepath.Join(windowsRoot, "Boot", "DVD", "PCAT", "boot.sdi")
	}
	bootManager := filepath.Join(sourceEFI, "bootmgfw.efi")
	for _, required := range []string{sourceEFI, sourceFonts, sourceSDI, bootManager, filepath.Join(windowsRoot, "System32", "bcdedit.exe")} {
		if _, err := os.Stat(required); err != nil {
			return fmt.Errorf("WIMBoot host prerequisite missing %s: %w", required, err)
		}
	}

	templateRoot := dataProgramFile(dataRoot, wimBootTemplateDirectory)
	if err := os.RemoveAll(templateRoot); err != nil {
		return fmt.Errorf("clear WIMBoot template: %w", err)
	}
	microsoftBoot := filepath.Join(templateRoot, "EFI", "Microsoft", "Boot")
	if err := copyDirectoryTree(sourceEFI, microsoftBoot); err != nil {
		return fmt.Errorf("copy Windows EFI boot files: %w", err)
	}
	if err := copyDirectoryTree(sourceFonts, filepath.Join(microsoftBoot, "Fonts")); err != nil {
		return fmt.Errorf("copy Windows boot fonts: %w", err)
	}
	if _, _, err := copyFileSyncHash(sourceSDI, filepath.Join(templateRoot, "boot", "boot.sdi"), nil); err != nil {
		return fmt.Errorf("copy boot.sdi: %w", err)
	}
	fallbackName, err := fallbackEFIName()
	if err != nil {
		return err
	}
	if _, _, err := copyFileSyncHash(bootManager, filepath.Join(templateRoot, "EFI", "BOOT", fallbackName), nil); err != nil {
		return fmt.Errorf("copy fallback Windows boot manager: %w", err)
	}

	bcdPath := filepath.Join(microsoftBoot, "BCD")
	if err := createWimBootBCD(filepath.Join(windowsRoot, "System32", "bcdedit.exe"), bcdPath); err != nil {
		return err
	}
	return verifyWimBootTemplate(dataRoot)
}

func hasWindowsWIMImages(dataRoot string) (bool, error) {
	windowsRoot := filepath.Join(dataRoot, "Systems", "Windows")
	entries, err := os.ReadDir(windowsRoot)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	for _, profile := range entries {
		if !profile.IsDir() {
			continue
		}
		images := filepath.Join(windowsRoot, profile.Name(), "Images")
		files, err := os.ReadDir(images)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return false, err
		}
		for _, file := range files {
			if !file.IsDir() && strings.EqualFold(filepath.Ext(file.Name()), ".wim") {
				return true, nil
			}
		}
	}
	return false, nil
}

func verifyWimBootTemplate(dataRoot string) error {
	hasWIM, err := hasWindowsWIMImages(dataRoot)
	if err != nil {
		return err
	}
	if !hasWIM {
		return nil
	}
	fallbackName, err := fallbackEFIName()
	if err != nil {
		return err
	}
	root := dataProgramFile(dataRoot, wimBootTemplateDirectory)
	required := []string{
		filepath.Join(root, "EFI", "BOOT", fallbackName),
		filepath.Join(root, "EFI", "Microsoft", "Boot", "BCD"),
		filepath.Join(root, "boot", "boot.sdi"),
	}
	for _, path := range required {
		info, err := os.Stat(path)
		if err != nil {
			return fmt.Errorf("WIMBoot template missing %s: %w", path, err)
		}
		if !info.Mode().IsRegular() || info.Size() <= 0 {
			return fmt.Errorf("WIMBoot template file is empty or invalid: %s", path)
		}
	}
	return nil
}

func fallbackEFIName() (string, error) {
	switch runtime.GOARCH {
	case "amd64":
		return "BOOTX64.EFI", nil
	case "arm64":
		return "BOOTAA64.EFI", nil
	case "386":
		return "BOOTIA32.EFI", nil
	default:
		return "", fmt.Errorf("WIMBoot template unsupported on host architecture %s", runtime.GOARCH)
	}
}

func createWimBootBCD(bcdeditPath, storePath string) error {
	if err := os.MkdirAll(filepath.Dir(storePath), 0o755); err != nil {
		return err
	}
	_ = os.Remove(storePath)
	if _, err := runBCD(bcdeditPath, "/createstore", storePath); err != nil {
		return fmt.Errorf("create WIMBoot BCD store: %w", err)
	}
	commands := [][]string{
		{"/store", storePath, "/create", "{bootmgr}", "/d", "USOS WIMBoot Manager"},
		{"/store", storePath, "/set", "{bootmgr}", "device", "boot"},
		{"/store", storePath, "/create", "{ramdiskoptions}", "/d", "USOS Ramdisk"},
		{"/store", storePath, "/set", "{ramdiskoptions}", "ramdisksdidevice", "boot"},
		{"/store", storePath, "/set", "{ramdiskoptions}", "ramdisksdipath", `\boot\boot.sdi`},
	}
	for _, args := range commands {
		if _, err := runBCD(bcdeditPath, args...); err != nil {
			return fmt.Errorf("configure WIMBoot BCD: %w", err)
		}
	}
	output, err := runBCD(bcdeditPath, "/store", storePath, "/create", "/d", "USOS WIM", "/application", "osloader")
	if err != nil {
		return fmt.Errorf("create WIMBoot loader entry: %w", err)
	}
	guid := bcdGUIDPattern.FindString(output)
	if guid == "" {
		return fmt.Errorf("bcdedit did not return loader GUID: %s", strings.TrimSpace(output))
	}
	ramdisk := `ramdisk=[boot]\sources\boot.wim,{ramdiskoptions}`
	loaderCommands := [][]string{
		{"/store", storePath, "/set", guid, "device", ramdisk},
		{"/store", storePath, "/set", guid, "osdevice", ramdisk},
		{"/store", storePath, "/set", guid, "path", `\windows\system32\boot\winload.efi`},
		{"/store", storePath, "/set", guid, "systemroot", `\windows`},
		{"/store", storePath, "/set", guid, "winpe", "yes"},
		{"/store", storePath, "/set", guid, "detecthal", "yes"},
		{"/store", storePath, "/displayorder", guid, "/addlast"},
		{"/store", storePath, "/default", guid},
		{"/store", storePath, "/timeout", "0"},
	}
	for _, args := range loaderCommands {
		if _, err := runBCD(bcdeditPath, args...); err != nil {
			return fmt.Errorf("configure WIMBoot loader %s: %w", guid, err)
		}
	}
	return nil
}

func runBCD(executable string, args ...string) (string, error) {
	command := exec.Command(executable, args...)
	output, err := command.CombinedOutput()
	if err != nil {
		return string(output), fmt.Errorf("%s %v failed: %w: %s", executable, args, err, strings.TrimSpace(string(output)))
	}
	return string(output), nil
}

func copyDirectoryTree(source, destination string) error {
	return filepath.WalkDir(source, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		relative, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		target := filepath.Join(destination, relative)
		if entry.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return nil
		}
		_, _, err = copyFileSyncHash(path, target, nil)
		return err
	})
}
