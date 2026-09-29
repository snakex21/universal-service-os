//go:build windows

package winhost

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/snakex21/universal-service-os/installer/internal/components"
	"github.com/snakex21/universal-service-os/installer/internal/install"
)

// Optional components (internal/components) on the stick. The zips reaching
// here are already verified against SHA256SUMS and the compiled hash list.
// Installing reuses the existing paths: the WinPE donor goes to
// DATA\Programs\USOS\WinPE and is recorded by ensureWinpeDonor (the same code
// as install/update/repair); an XP package is installed by the
// install-xp-package.ps1 shipped inside it, exactly as by hand.

// ComponentStatus reads which components the stick has (read-only).
func (b Backend) ComponentStatus(media install.MediaLayout) (components.Status, error) {
	resolved, err := resolveFormattedMedia(media, 10*time.Second)
	if err != nil {
		return components.Status{}, fmt.Errorf("resolve media for the components: %w", err)
	}
	return components.Inspect(resolved.ESP.VolumePath, resolved.DATA.VolumePath), nil
}

// InstallComponent puts one verified component zip onto the stick.
func (b Backend) InstallComponent(media install.MediaLayout, id components.ID, zipPath string, storeOnly bool, log func(string)) error {
	resolved, err := resolveFormattedMedia(media, 10*time.Second)
	if err != nil {
		return fmt.Errorf("resolve media for the components: %w", err)
	}
	return installComponentAt(resolved.ESP.VolumePath, resolved.DATA.VolumePath, id, zipPath, storeOnly, log)
}

func installComponentAt(espRoot, dataRoot string, id components.ID, zipPath string, storeOnly bool, log func(string)) error {
	if log == nil {
		log = func(string) {}
	}
	switch {
	case id == components.WinPE:
		return installWinpeComponent(espRoot, dataRoot, zipPath, log)
	case id.IsXP() && storeOnly:
		return storeXPComponent(dataRoot, id, zipPath, log)
	case id.IsXP():
		return installXPComponent(espRoot, zipPath, log)
	}
	return fmt.Errorf("unknown component %q", id)
}

func installWinpeComponent(espRoot, dataRoot, zipPath string, log func(string)) error {
	if status := components.Inspect(espRoot, dataRoot); status.WinPE {
		log("[COMPONENTS] WinPE donor already on DATA: " + status.WinPEName)
	} else {
		name, err := components.ExtractWinPEDonor(zipPath, dataRoot)
		if err != nil {
			return fmt.Errorf("copy the WinPE donor to DATA: %w", err)
		}
		log("[COMPONENTS] WinPE donor copied to " + filepath.Join(winpeDonorDir, name))
	}
	state, err := ensureWinpeDonor(dataRoot, espRoot)
	log("WINPE_DONOR " + state.logLine())
	if err != nil {
		return err
	}
	if state.Ambiguous || state.Corrupt || state.Name == "" {
		return errors.New("WinPE donor: " + state.logLine())
	}
	return nil
}

// storeXPComponent keeps the second XP language's zip on DATA
// (Programs\USOS\XP) for a later offline install.
func storeXPComponent(dataRoot string, id components.ID, zipPath string, log func(string)) error {
	name := components.CurrentRelease().Asset(id)
	if name == "" {
		name = filepath.Base(zipPath)
	}
	target := filepath.Join(dataRoot, components.XPStoreDir, name)
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	src, err := os.Open(zipPath)
	if err != nil {
		return err
	}
	defer src.Close()
	dst, err := os.Create(target + ".part")
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(dst, src)
	syncErr := dst.Sync()
	closeErr := dst.Close()
	if err := errors.Join(copyErr, syncErr, closeErr); err != nil {
		os.Remove(target + ".part")
		return err
	}
	want, err := components.HashFile(zipPath)
	if err != nil {
		return err
	}
	if got, err := components.HashFile(target + ".part"); err != nil || got != want {
		os.Remove(target + ".part")
		return fmt.Errorf("readback of %s failed", target)
	}
	if err := os.Rename(target+".part", target); err != nil {
		return err
	}
	log("[COMPONENTS] " + string(id) + " zip kept on DATA: " + filepath.Join(components.XPStoreDir, name))
	return nil
}

// installXPComponent unpacks the package on the PC and runs its
// install-xp-package.ps1 against this stick's ESP.
func installXPComponent(espRoot, zipPath string, log func(string)) error {
	work, err := os.MkdirTemp("", "usos-xp-package-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(work)
	if err := components.ExtractAll(zipPath, work); err != nil {
		return fmt.Errorf("unpack the XP package: %w", err)
	}
	script := filepath.Join(work, components.XPInstallScript)
	if _, err := os.Stat(script); err != nil {
		return fmt.Errorf("the XP package has no %s", components.XPInstallScript)
	}
	powershell, err := exec.LookPath("powershell.exe")
	if err != nil {
		return fmt.Errorf("Windows PowerShell is required for %s: %w", components.XPInstallScript, err)
	}
	if !strings.HasSuffix(espRoot, `\`) {
		espRoot += `\`
	}
	// The wrapper turns a thrown error into one unwrapped "ERROR: " line.
	cmd := exec.Command(powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", xpInstallWrapper)
	cmd.Dir = work
	cmd.Env = append(os.Environ(), "USOS_XP_SCRIPT="+script, "USOS_XP_ESP="+espRoot)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000} // CREATE_NO_WINDOW
	output, runErr := cmd.CombinedOutput()
	for _, line := range strings.Split(strings.ReplaceAll(string(output), "\r", ""), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			log("[XP-PACKAGE] " + line)
		}
	}
	if runErr != nil || !strings.Contains(string(output), "PASS: XP package installed") {
		return fmt.Errorf("%s: %s", components.XPInstallScript, psError(string(output)))
	}
	return nil
}

const xpInstallWrapper = `$ErrorActionPreference = 'Stop'
try { & $env:USOS_XP_SCRIPT -EspRoot $env:USOS_XP_ESP; exit 0 }
catch { Write-Output ('ERROR: ' + $_.Exception.Message); exit 1 }`

// psError returns the wrapper's "ERROR: " message, else the last line.
func psError(text string) string {
	lines := strings.Split(strings.TrimSpace(strings.ReplaceAll(text, "\r", "")), "\n")
	for _, line := range lines {
		if message, ok := strings.CutPrefix(strings.TrimSpace(line), "ERROR: "); ok {
			return message
		}
	}
	return strings.TrimSpace(lines[len(lines)-1])
}
