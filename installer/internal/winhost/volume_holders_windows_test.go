//go:build windows

package winhost

import (
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// A process whose current directory is a folder holds that folder open, as
// an Explorer window does with the drive it shows; the Restart Manager must
// name it.
func TestVolumeHoldersNamesAProcessHoldingTheFolder(t *testing.T) {
	dir := t.TempDir()
	holder := exec.Command("powershell.exe", "-NoProfile", "-Command", "Start-Sleep -Seconds 30")
	holder.Dir = dir
	if err := holder.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = holder.Process.Kill(); _, _ = holder.Process.Wait() }()
	var names []string
	for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); time.Sleep(200 * time.Millisecond) {
		if names = volumeHolders(dir); len(names) > 0 {
			break
		}
	}
	if len(names) == 0 {
		t.Fatalf("Restart Manager named no holder of %s", dir)
	}
	t.Logf("holders of %s: %v", dir, names)
	if !strings.Contains(strings.ToLower(strings.Join(names, " ")), "powershell") {
		t.Logf("holder name is the localized application name: %v", names)
	}
}

func TestVolumeHoldersWithoutHolderOrPath(t *testing.T) {
	if names := volumeHolders(""); names != nil {
		t.Fatalf("empty mount: %v", names)
	}
	dir := t.TempDir()
	if names := volumeHolders(dir); len(names) != 0 {
		t.Fatalf("unused folder: %v", names)
	}
	_ = os.RemoveAll(dir)
}
