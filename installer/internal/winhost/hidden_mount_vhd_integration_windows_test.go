//go:build windows

package winhost

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/snakex21/universal-service-os/installer/internal/autoplay"
	"github.com/snakex21/universal-service-os/installer/internal/layout"
	"golang.org/x/sys/windows"
)

// newTestVHDX creates, attaches and opens a temporary expandable VHDX and
// refuses to continue unless the disk really is that file-backed image.
func newTestVHDX(t *testing.T, sizeMiB int) (uint32, windows.Handle) {
	t.Helper()
	dir := t.TempDir()
	image := filepath.Join(dir, "usos-vhd-test.vhdx")
	script := filepath.Join(dir, "create.txt")
	if err := os.WriteFile(script, []byte(fmt.Sprintf("create vdisk file=\"%s\" maximum=%d type=expandable\r\n", image, sizeMiB)), 0o600); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("diskpart.exe", "/s", script).CombinedOutput(); err != nil {
		t.Fatalf("diskpart create vdisk: %v: %s", err, out)
	}
	ps := func(command string) string {
		t.Helper()
		out, err := exec.Command("powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command).CombinedOutput()
		if err != nil {
			t.Fatalf("powershell %q: %v: %s", command, err, out)
		}
		return strings.TrimSpace(string(out))
	}
	quoted := "'" + strings.ReplaceAll(image, "'", "''") + "'"
	ps("Mount-DiskImage -ImagePath " + quoted + " | Out-Null")
	t.Cleanup(func() {
		_ = exec.Command("powershell.exe", "-NoProfile", "-Command", "Dismount-DiskImage -ImagePath "+quoted+" | Out-Null").Run()
	})
	number64, err := strconv.ParseUint(ps("(Get-DiskImage -ImagePath "+quoted+").Number"), 10, 32)
	if err != nil {
		t.Fatalf("disk number of the VHDX: %v", err)
	}
	diskNumber := uint32(number64)
	// Hard safety check: the disk must be this file-backed VHDX.
	bus := ps(fmt.Sprintf("(Get-Disk -Number %d).BusType", diskNumber))
	location := ps(fmt.Sprintf("(Get-Disk -Number %d).Location", diskNumber))
	if bus != "File Backed Virtual" || !strings.EqualFold(location, image) {
		t.Fatalf("refusing: disk %d is bus=%q location=%q, not the test VHDX", diskNumber, bus, location)
	}

	path := fmt.Sprintf(`\\.\PhysicalDrive%d`, diskNumber)
	pathPtr, _ := utf16Ptr(path)
	handle, err := windows.CreateFile(pathPtr, windows.GENERIC_READ|windows.GENERIC_WRITE, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { windows.CloseHandle(handle) })

	return diskNumber, handle
}

// driveLetters lists drive-letter mount paths of the disk's volumes, keyed
// by the name of the partition whose start offset matches.
func driveLetters(t *testing.T, diskNumber uint32, names map[uint64]string) map[string][]string {
	t.Helper()
	volumes, err := enumerateVolumes()
	if err != nil {
		t.Fatal(err)
	}
	found := map[string][]string{}
	for _, v := range volumes {
		for _, e := range v.Extents {
			if e.DiskNumber != diskNumber {
				continue
			}
			name, ok := names[e.StartingOffset]
			if !ok {
				name = "?"
			}
			for _, p := range v.Info.MountPaths {
				if len(p) >= 2 && p[1] == ':' {
					found[name] = append(found[name], p)
				}
			}
		}
	}
	return found
}

// TestVHDXPartitionsStayUnmountedUntilFormatted runs the real GPT write,
// format and expose steps against a temporary VHDX (never a physical disk):
// the new DATA/WORK volumes must not get a drive letter until they are
// formatted; afterwards only DATA has one. It needs administrator rights.
//
//	set USOS_VHD_INTEGRATION=1 && go test ./internal/winhost -run VHDX -v
func TestVHDXPartitionsStayUnmountedUntilFormatted(t *testing.T) {
	if os.Getenv("USOS_VHD_INTEGRATION") != "1" {
		t.Skip("set USOS_VHD_INTEGRATION=1 (elevated) to run the VHDX integration test")
	}
	const sizeMiB = 40 * 1024
	diskNumber, handle := newTestVHDX(t, sizeMiB)

	plan, err := layout.Build(uint64(sizeMiB) * 1024 * 1024)
	if err != nil {
		t.Fatal(err)
	}
	ids, err := newGPTIDs()
	if err != nil {
		t.Fatal(err)
	}
	restoreAutoPlay, err := autoplay.Suppress(autoplay.CurrentUser{})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := restoreAutoPlay(); err != nil {
			t.Errorf("restore AutoPlay: %v", err)
		}
	}()
	header, err := createGPT(handle, ids)
	if err != nil {
		t.Fatal(err)
	}
	media, err := setGPTLayout(handle, plan, header, ids)
	if err != nil {
		t.Fatal(err)
	}
	media.DiskNumber = diskNumber

	letters := func() map[string][]string {
		return driveLetters(t, diskNumber, map[uint64]string{media.ESP.StartBytes: "ESP", media.DATA.StartBytes: "DATA", media.WORK.StartBytes: "WORK"})
	}
	time.Sleep(3 * time.Second) // let the mount manager see the new volumes
	if got := letters(); len(got) != 0 {
		t.Fatalf("unformatted volumes got drive letters: %v", got)
	}

	if err := formatPartition(diskNumber, media.ESP, guidString(efiSystemPartitionType), "FAT32", "USOS_ESP", false); err != nil {
		t.Fatal(err)
	}
	if err := formatPartition(diskNumber, media.DATA, guidString(basicDataPartitionType), "NTFS", "USOS_DATA", false); err != nil {
		t.Fatal(err)
	}
	if err := formatPartition(diskNumber, media.WORK, guidString(basicDataPartitionType), "NTFS", "USOS_WORK", true); err != nil {
		t.Fatal(err)
	}
	if got := letters(); len(got) != 0 {
		t.Fatalf("drive letters appeared during format: %v", got)
	}

	if err := (Backend{}).ExposeFormattedVolumes(media); err != nil {
		t.Fatal(err)
	}
	got := letters()
	if len(got["DATA"]) == 0 || len(got["WORK"]) != 0 || len(got["ESP"]) != 0 {
		t.Fatalf("after expose: letters=%v, want only DATA", got)
	}
	after, err := readDriveLayout(handle)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := verifyMediaLayout(media, after); err != nil {
		t.Fatalf("final layout: %v", err)
	}
	t.Logf("PhysicalDrive%d: DATA=%v, WORK and ESP without letters", diskNumber, got["DATA"])
}

// TestVHDXUninstallVolumeStaysUnmountedUntilFormatted runs the real uninstall
// GPT write, exFAT format and expose steps against a temporary VHDX: the
// single partition must not get a drive letter until it is formatted, and
// must have one afterwards. It needs administrator rights.
func TestVHDXUninstallVolumeStaysUnmountedUntilFormatted(t *testing.T) {
	if os.Getenv("USOS_VHD_INTEGRATION") != "1" {
		t.Skip("set USOS_VHD_INTEGRATION=1 (elevated) to run the VHDX integration test")
	}
	diskNumber, handle := newTestVHDX(t, 34*1024)
	restoreAutoPlay, err := autoplay.Suppress(autoplay.CurrentUser{})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := restoreAutoPlay(); err != nil {
			t.Errorf("restore AutoPlay: %v", err)
		}
	}()
	media, err := createSingleDataLayout(handle, diskNumber, 512)
	if err != nil {
		t.Fatal(err)
	}
	letters := func() map[string][]string {
		return driveLetters(t, diskNumber, map[uint64]string{media.Data.StartBytes: "DATA"})
	}
	time.Sleep(3 * time.Second) // let the mount manager see the new volume
	if got := letters(); len(got) != 0 {
		t.Fatalf("unformatted uninstall volume got a drive letter: %v", got)
	}
	if err := (Backend{}).FormatExFAT(media); err != nil {
		t.Fatal(err)
	}
	if got := letters(); len(got) != 0 {
		t.Fatalf("drive letter appeared during format: %v", got)
	}
	if err := (Backend{}).ExposeFormattedVolume(media); err != nil {
		t.Fatal(err)
	}
	got := letters()
	if len(got["DATA"]) == 0 {
		t.Fatalf("after expose: letters=%v, want one for the exFAT volume", got)
	}
	after, err := readDriveLayout(handle)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := verifySingleDataLayout(media, after, 0); err != nil {
		t.Fatalf("final layout: %v", err)
	}
	report, err := (Backend{}).VerifyUninstall(media)
	if err != nil {
		t.Fatalf("VerifyUninstall: %v %+v", err, report.Items)
	}
	t.Logf("PhysicalDrive%d: exFAT volume at %v", diskNumber, got["DATA"])
}
