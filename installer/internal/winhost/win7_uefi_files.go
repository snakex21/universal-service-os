package winhost

// Przenosne pliki stagingu win7-uefi-x64-modern (kompiluje sie na kazdym GOOS).
//
// Rozroznienie sciezek:
//   - win7-bios-vanilla (retro): bez zmian, vanilla WIM nietkniety.
//   - win7-uefi-x64-modern (nowy sprzet Ryzen/XHCI): ten builder.
//     Patch tylko na target PO apply-image (W:\ + katalog stagingu),
//     nigdy vanilla WIM na stale.
//
// Staging ZAWSZE z WinPE10 (WinPE7 nie wchodzi na nowym USB z XHCI),
// tylko Win7 x64, GPT + FAT32 ESP, Secure Boot OFF.

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/snakex21/universal-service-os/installer/internal/install"
)

// Win7ModernDriverRelDir to wzgledny katalog paczki XHCI w DATA:
// Systems/Windows/Windows 7/Drivers/x64 (podpisane INF+SYS+CAT).
// Uklad definiuje install.Win7DriverLibraryRelDir (jedyna definicja).
func Win7ModernDriverRelDir() string {
	return install.Win7DriverLibraryRelDir()
}

// Win7SetupCompleteRelPath to docelowa sciezka wzgledem roota Windows
// na target po apply-image.
func Win7SetupCompleteRelPath() string {
	return filepath.Join("Windows", "Setup", "Scripts", "SetupComplete.cmd")
}

// Win7ModernStagingFiles buduje zawartosci plikow modern:
// Autounattend.xml (oobeSystem SkipMachineOOBE/SkipUserOOBE,
// ProtectYourPC=3, HideEULA, InputLocale pl-PL, AutoLogon +
// FirstLogonCommands -> SetupComplete.cmd, DriverPaths -> Drivers\x64)
// oraz SetupComplete.cmd (fallback pnputil XHCI, gdy OOBE przeszlo bez USB).
func Win7ModernStagingFiles(params install.Win7ModernUnattendParams, setupCompleteDriverPath string) map[string]string {
	files := map[string]string{
		"SetupComplete.cmd": install.Win7SetupCompleteScript(setupCompleteDriverPath),
	}
	if params.UseAutounattend {
		files["Autounattend.xml"] = install.Win7ModernAutounattend(params)
	}
	return files
}

// WriteWin7ModernStagingFiles zapisuje pliki modern:
//   - stagingDir/Autounattend.xml (obok boot.wim / zrodel WinPE10),
//   - targetWindowsRoot/Windows/Setup/Scripts/SetupComplete.cmd (po apply-image).
func WriteWin7ModernStagingFiles(stagingDir, targetWindowsRoot string, params install.Win7ModernUnattendParams, setupCompleteDriverPath string) error {
	if err := os.MkdirAll(stagingDir, 0o755); err != nil {
		return fmt.Errorf("mkdir staging dir: %w", err)
	}
	for name, contents := range Win7ModernStagingFiles(params, setupCompleteDriverPath) {
		path := filepath.Join(stagingDir, name)
		if name == "SetupComplete.cmd" {
			path = filepath.Join(targetWindowsRoot, Win7SetupCompleteRelPath())
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return fmt.Errorf("mkdir %s: %w", filepath.Dir(path), err)
		}
		if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
			return fmt.Errorf("write %s: %w", path, err)
		}
	}
	return nil
}
