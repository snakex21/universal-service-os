//go:build windows

package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/winhost"
)

func main() {
	diskNumber := flag.Uint("disk", 9, "required PhysicalDrive number")
	model := flag.String("model", "Kingston DataTraveler 3.0", "required full model")
	size := flag.Uint64("size", 61991813632, "required size in bytes")
	mount := flag.String("mount", `L:\`, "required current mount path")
	label := flag.String("label", "KINGSTON", "required current volume label")
	installerPath := flag.String("installer", "", "required final USOS Installer.exe path copied by production payload code")
	confirm := flag.String("confirm", "", "must exactly equal the full model")
	flag.Parse()

	fail := func(format string, args ...any) {
		fmt.Fprintf(os.Stderr, "FAIL: "+format+"\n", args...)
		os.Exit(1)
	}
	if *diskNumber > 127 {
		fail("disk number %d outside allowed preflight range", *diskNumber)
	}
	if *confirm != *model {
		fail("confirmation mismatch: exact full model is required")
	}
	if strings.TrimSpace(*installerPath) == "" {
		fail("final installer executable path is required")
	}
	installerAbs, err := filepath.Abs(*installerPath)
	if err != nil {
		fail("resolve final installer path: %v", err)
	}
	installerInfo, err := os.Stat(installerAbs)
	if err != nil || !installerInfo.Mode().IsRegular() || installerInfo.Size() <= 0 {
		fail("invalid final installer executable %s: %v", installerAbs, err)
	}

	disks, err := (winhost.Enumerator{}).ListDisks()
	if err != nil {
		fail("enumerate physical disks: %v", err)
	}
	var target *domain.Disk
	for i := range disks {
		if disks[i].Number == uint32(*diskNumber) {
			target = &disks[i]
			break
		}
	}
	if target == nil {
		fail("PhysicalDrive%d is no longer present", *diskNumber)
	}
	if target.DisplayName() != *model {
		fail("model changed: got %q want %q", target.DisplayName(), *model)
	}
	if target.SizeBytes != *size {
		fail("size changed: got %d want %d", target.SizeBytes, *size)
	}
	if !target.Removable {
		fail("PhysicalDrive%d no longer reports RemovableMedia", *diskNumber)
	}
	if target.SystemDisk {
		fail("PhysicalDrive%d is now classified as the Windows system disk", *diskNumber)
	}
	if !target.Eligible {
		fail("PhysicalDrive%d is no longer eligible: %s", *diskNumber, target.Reason)
	}

	volumeMatch := false
	for _, volume := range target.Volumes {
		if !strings.EqualFold(strings.TrimSpace(volume.Label), strings.TrimSpace(*label)) {
			continue
		}
		for _, path := range volume.MountPaths {
			if strings.EqualFold(path, *mount) {
				volumeMatch = true
				break
			}
		}
	}
	if !volumeMatch {
		fail("confirmed preflight volume %s label=%q is no longer present on PhysicalDrive%d", *mount, *label, *diskNumber)
	}

	logPath, err := filepath.Abs("USOS Physical Kingston Test.log")
	if err != nil {
		fail("resolve log path: %v", err)
	}
	logger, err := install.NewOperationLoggerAt(logPath)
	if err != nil {
		fail("open operation log: %v", err)
	}
	defer logger.Close()

	engine, err := install.NewEngine(winhost.Backend{InstallerExecutable: installerAbs}, logger)
	if err != nil {
		fail("create install engine: %v", err)
	}

	fmt.Printf("CONFIRMED PhysicalDrive%d model=%q serial=%q size=%d mount=%s label=%q\n", target.Number, target.DisplayName(), target.Serial, target.SizeBytes, *mount, *label)
	fmt.Printf("INSTALLER=%s bytes=%d\n", installerAbs, installerInfo.Size())
	fmt.Println("DESTRUCTIVE_START=AUTHORIZED")

	var final *install.VerificationReport
	var finalErr error
	for event := range engine.RunAsync(*target) {
		switch event.Kind {
		case install.EventStage:
			stage, ok := install.Stage(event.StageID)
			if !ok {
				continue
			}
			switch event.State {
			case install.StateActive:
				if event.ProgressKnown {
					// Copy progress is real; keep console output sparse while the GUI remains byte-accurate.
					if event.Progress == 0 || event.Progress >= 1 {
						fmt.Printf("STAGE %d/8 START %s progress=%.1f%%\n", stage.Number, stage.Name, event.Progress*100)
					}
				} else {
					fmt.Printf("STAGE %d/8 START %s\n", stage.Number, stage.Name)
				}
			case install.StateSucceeded:
				fmt.Printf("STAGE %d/8 PASS %s\n", stage.Number, stage.Name)
			case install.StateFailed:
				fmt.Printf("STAGE %d/8 FAIL %s: %v\n", stage.Number, stage.Name, event.Err)
			}
		case install.EventFinished:
			final = event.Verification
			finalErr = event.Err
		}
	}

	if finalErr != nil {
		fail("installer stopped: %v", finalErr)
	}
	if final == nil || !final.OK() {
		fail("installer returned no successful final verification")
	}
	for _, item := range final.Items {
		fmt.Printf("VERIFY %s expected=%q actual=%q match=%v\n", item.Name, item.Expected, item.Actual, item.Match)
	}
	fmt.Printf("LOG=%s\n", logPath)
	fmt.Println("RESULT=PASS")
}
