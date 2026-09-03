//go:build windows

package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/installed"
	"github.com/snakex21/universal-service-os/installer/internal/winhost"
)

func main() {
	serial := flag.String("serial", "USOS-GPT-TEST", "required target serial")
	_ = flag.Uint64("size", 0, "accepted for bootstrap compatibility")
	diskNumber := flag.Int("disk-number", -1, "inspect this exact disk number, including a read-only virtual disk")
	installerPath := flag.String("installer", "", "reference USOS Installer.exe; defaults to tagged config media")
	out := flag.String("out", "", "result file")
	flag.Parse()
	if strings.TrimSpace(*out) == "" {
		fmt.Fprintln(os.Stderr, "missing -out")
		os.Exit(2)
	}

	lines := []string{"USOS read-only post-verify diagnostic"}
	finish := func(ok bool, err error) {
		if err != nil {
			lines = append(lines, "ERROR="+err.Error())
		}
		if ok {
			lines = append(lines, "RESULT=PASS")
		} else {
			lines = append(lines, "RESULT=FAIL")
		}
		_ = os.WriteFile(*out, []byte(strings.Join(lines, "\r\n")+"\r\n"), 0o644)
		if ok {
			os.Exit(0)
		}
		os.Exit(1)
	}

	var target installed.Target
	if *diskNumber >= 0 {
		disks, err := (winhost.Enumerator{}).ListDisks()
		if err != nil {
			finish(false, err)
		}
		var found int
		for _, disk := range disks {
			if disk.Number == uint32(*diskNumber) {
				found++
				var inspectErr error
				target, inspectErr = winhost.InspectInstalledUSOSReadOnly(disk)
				if inspectErr != nil {
					finish(false, fmt.Errorf("inspect PhysicalDrive%s read-only: %w", strconv.Itoa(*diskNumber), inspectErr))
				}
			}
		}
		if found != 1 {
			finish(false, fmt.Errorf("expected one PhysicalDrive%d, found %d", *diskNumber, found))
		}
	} else {
		targets, err := (winhost.InstalledUSOSSource{}).ListInstalledUSOS()
		if err != nil {
			finish(false, err)
		}
		var found int
		var targetIndex int
		for i, candidate := range targets {
			if strings.TrimSpace(candidate.Disk.Serial) == strings.TrimSpace(*serial) {
				found++
				targetIndex = i
			}
		}
		if found != 1 {
			finish(false, fmt.Errorf("expected one installed USOS serial=%q, found %d", *serial, found))
		}
		target = targets[targetIndex]
	}
	lines = append(lines, fmt.Sprintf("TARGET=PhysicalDrive%d model=%q serial=%q size=%d", target.Disk.Number, target.Disk.DisplayName(), target.Disk.Serial, target.Disk.SizeBytes))
	for _, volume := range target.Disk.Volumes {
		lines = append(lines, fmt.Sprintf("VOLUME label=%q fs=%q mounts=%q root=%q", volume.Label, volume.FileSystem, volume.MountPaths, volume.RootEntries))
	}

	installer := strings.TrimSpace(*installerPath)
	if installer == "" {
		installer = findConfigInstaller()
	}
	if installer == "" {
		finish(false, fmt.Errorf("config USOS Installer.exe not found"))
	}
	lines = append(lines, "REFERENCE_INSTALLER="+installer)
	report, err := (winhost.Backend{InstallerExecutable: installer}).Verify(target.Media, target.Identity)
	if err != nil {
		finish(false, err)
	}
	all := true
	for _, item := range report.Items {
		lines = append(lines, fmt.Sprintf("VERIFY name=%q expected=%q actual=%q match=%v", item.Name, item.Expected, item.Actual, item.Match))
		if !item.Match {
			all = false
		}
	}
	finish(all, nil)
}

func findConfigInstaller() string {
	for letter := 'D'; letter <= 'Z'; letter++ {
		root := fmt.Sprintf("%c:\\", letter)
		if _, err := os.Stat(filepath.Join(root, "USOS_QEMU_TEST.TAG")); err != nil {
			continue
		}
		path := filepath.Join(root, "USOS Installer.exe")
		if info, err := os.Stat(path); err == nil && info.Mode().IsRegular() && info.Size() > 0 {
			return path
		}
	}
	return ""
}
