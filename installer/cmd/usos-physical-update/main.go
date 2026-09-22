//go:build windows

package main

import (
	"crypto/sha256"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/localupdate"
	"github.com/snakex21/universal-service-os/installer/internal/winhost"
)

func main() {
	diskNumber := flag.Uint("disk", 8, "required PhysicalDrive number")
	model := flag.String("model", "Kingston DataTraveler 3.0", "required full model")
	size := flag.Uint64("size", 61991813632, "required size in bytes")
	confirm := flag.String("confirm", "", "must exactly equal the full model")
	diskPTUUID := flag.String("ptuuid", "", "required expected GPT disk UUID")
	espPartUUID := flag.String("esp-partuuid", "", "required expected ESP PARTUUID")
	dataPartUUID := flag.String("data-partuuid", "", "required expected DATA PARTUUID")
	workPartUUID := flag.String("work-partuuid", "", "required expected WORK PARTUUID")
	installerPath := flag.String("installer", "", "USOS Installer.exe used by CopyInstallPayload")
	logPath := flag.String("log", "", "operation log path")
	legacyCorePath := flag.String("legacy-core", "", "optional rollback Core slot override; normal updates leave this empty")
	restoreImageMarkers := flag.Bool("restore-image-markers", false, "rollback only: recreate pre-direct-NTFS zero-byte image markers on ESP after update")
	debugBootmgrProbe := flag.String("debug-bootmgr-probe", "", "optional physical diagnostic bootmgr.exe probe copied to the identified ESP after a successful update")
	flag.Parse()

	fatalf := func(format string, args ...any) {
		fmt.Fprintf(os.Stderr, "FAIL: "+format+"\n", args...)
		os.Exit(1)
	}
	if *confirm != *model {
		fatalf("confirmation mismatch: exact full model is required")
	}
	if strings.TrimSpace(*installerPath) == "" {
		fatalf("missing -installer")
	}
	if strings.TrimSpace(*diskPTUUID) == "" || strings.TrimSpace(*espPartUUID) == "" || strings.TrimSpace(*dataPartUUID) == "" || strings.TrimSpace(*workPartUUID) == "" {
		fatalf("missing exact GPT identity guard: -ptuuid, -esp-partuuid, -data-partuuid and -work-partuuid are all required")
	}
	installerAbs, err := filepath.Abs(*installerPath)
	if err != nil {
		fatalf("resolve installer path: %v", err)
	}
	if info, err := os.Stat(installerAbs); err != nil || !info.Mode().IsRegular() || info.Size() <= 0 {
		fatalf("invalid installer executable %s: %v", installerAbs, err)
	}
	if strings.TrimSpace(*logPath) == "" {
		*logPath = "USOS Physical Update Test.log"
	}
	logAbs, err := filepath.Abs(*logPath)
	if err != nil {
		fatalf("resolve log path: %v", err)
	}

	targets, err := (winhost.InstalledUSOSSource{}).ListInstalledUSOS()
	if err != nil {
		fatalf("enumerate installed USOS targets: %v", err)
	}
	var targetIndex = -1
	for i := range targets {
		if targets[i].Disk.Number == uint32(*diskNumber) {
			targetIndex = i
			break
		}
	}
	if targetIndex < 0 {
		fatalf("PhysicalDrive%d is not a valid installed USOS target", *diskNumber)
	}
	target := targets[targetIndex]
	if target.Disk.DisplayName() != *model {
		fatalf("model changed: got %q want %q", target.Disk.DisplayName(), *model)
	}
	if target.Disk.SizeBytes != *size {
		fatalf("size changed: got %d want %d", target.Disk.SizeBytes, *size)
	}
	if target.Disk.SystemDisk || !target.Disk.Removable {
		fatalf("refusing unsafe target PhysicalDrive%d system=%v removable=%v", target.Disk.Number, target.Disk.SystemDisk, target.Disk.Removable)
	}
	if !strings.EqualFold(target.Media.DiskPTUUID, strings.TrimSpace(*diskPTUUID)) {
		fatalf("GPT disk UUID changed: got %q want %q", target.Media.DiskPTUUID, strings.TrimSpace(*diskPTUUID))
	}
	if !strings.EqualFold(target.Media.ESP.PartUUID, strings.TrimSpace(*espPartUUID)) {
		fatalf("ESP PARTUUID changed: got %q want %q", target.Media.ESP.PartUUID, strings.TrimSpace(*espPartUUID))
	}
	if !strings.EqualFold(target.Media.DATA.PartUUID, strings.TrimSpace(*dataPartUUID)) {
		fatalf("DATA PARTUUID changed: got %q want %q", target.Media.DATA.PartUUID, strings.TrimSpace(*dataPartUUID))
	}
	if !strings.EqualFold(target.Media.WORK.PartUUID, strings.TrimSpace(*workPartUUID)) {
		fatalf("WORK PARTUUID changed: got %q want %q", target.Media.WORK.PartUUID, strings.TrimSpace(*workPartUUID))
	}

	logger, err := install.NewOperationLoggerAt(logAbs)
	if err != nil {
		fatalf("open operation log: %v", err)
	}
	defer logger.Close()

	backend := winhost.Backend{InstallerExecutable: installerAbs}
	if strings.TrimSpace(*legacyCorePath) != "" {
		coreAbs, err := filepath.Abs(*legacyCorePath)
		if err != nil {
			fatalf("resolve Legacy Core override: %v", err)
		}
		coreBytes, err := os.ReadFile(coreAbs)
		if err != nil {
			fatalf("read Legacy Core override: %v", err)
		}
		backend.LegacyCoreOverride = coreBytes
		fmt.Printf("LEGACY_CORE_OVERRIDE=%s bytes=%d\n", coreAbs, len(coreBytes))
	}
	engine, err := localupdate.NewEngine(backend, logger)
	if err != nil {
		fatalf("create local update engine: %v", err)
	}

	fmt.Printf("CONFIRMED PhysicalDrive%d model=%q serial=%q size=%d\n", target.Disk.Number, target.Disk.DisplayName(), target.Disk.Serial, target.Disk.SizeBytes)
	fmt.Printf("GPT disk=%s ESP=%s@%d+%d DATA=%s@%d+%d WORK=%s@%d+%d\n", target.Media.DiskPTUUID, target.Media.ESP.PartUUID, target.Media.ESP.StartBytes, target.Media.ESP.SizeBytes, target.Media.DATA.PartUUID, target.Media.DATA.StartBytes, target.Media.DATA.SizeBytes, target.Media.WORK.PartUUID, target.Media.WORK.StartBytes, target.Media.WORK.SizeBytes)
	fmt.Printf("INSTALLER=%s\n", installerAbs)
	var final *install.VerificationReport
	var finalErr error
	for event := range engine.RunAsync(target) {
		switch event.Kind {
		case localupdate.EventLog:
			fmt.Println(event.Message)
		case localupdate.EventStage:
			if stage, ok := localupdate.StageInfo(event.StageID); ok {
				switch event.State {
				case localupdate.StateActive:
					if event.ProgressKnown {
						if event.Progress == 0 || event.Progress >= 1 {
							fmt.Printf("STAGE %d/%d START %s progress=%.1f%%\n", stage.Number, localupdate.StageCount, stage.Name, event.Progress*100)
						}
					} else {
						fmt.Printf("STAGE %d/%d START %s\n", stage.Number, localupdate.StageCount, stage.Name)
					}
				case localupdate.StateSucceeded:
					fmt.Printf("STAGE %d/%d PASS %s\n", stage.Number, localupdate.StageCount, stage.Name)
				case localupdate.StateFailed:
					fmt.Printf("STAGE %d/%d FAIL %s: %v\n", stage.Number, localupdate.StageCount, stage.Name, event.Err)
				}
			}
		case localupdate.EventFinished:
			final = event.Verification
			finalErr = event.Err
		}
	}
	if final != nil {
		for _, item := range final.Items {
			fmt.Printf("VERIFY %s expected=%q actual=%q match=%v\n", item.Name, item.Expected, item.Actual, item.Match)
		}
	}
	if finalErr != nil {
		fatalf("local update stopped: %v", finalErr)
	}
	if final == nil || !final.OK() {
		fatalf("local update returned no successful final verification")
	}
	if *restoreImageMarkers {
		if len(backend.LegacyCoreOverride) == 0 {
			fatalf("-restore-image-markers requires -legacy-core so rollback cannot silently alter normal production media")
		}
		if err := winhost.RestoreLegacyImageMarkers(target.Media); err != nil {
			fatalf("restore Legacy ESP image markers: %v", err)
		}
		fmt.Println("ROLLBACK ESP IMAGE MARKERS RESTORED")
	}
	if strings.TrimSpace(*debugBootmgrProbe) != "" {
		probeAbs, err := filepath.Abs(*debugBootmgrProbe)
		if err != nil {
			fatalf("resolve bootmgr probe: %v", err)
		}
		probe, err := os.ReadFile(probeAbs)
		if err != nil {
			fatalf("read bootmgr probe: %v", err)
		}
		if len(probe) < 4096 || string(probe[:2]) != "MZ" {
			fatalf("invalid bootmgr probe %s", probeAbs)
		}
		destination := filepath.Join(target.Media.ESP.VolumePath, "EFI", "USOS", "windows-bios-bootmgr-probe.exe")
		tmp := destination + ".tmp"
		if err := os.WriteFile(tmp, probe, 0o644); err != nil {
			fatalf("write bootmgr probe temporary file: %v", err)
		}
		if err := os.Rename(tmp, destination); err != nil {
			_ = os.Remove(tmp)
			fatalf("publish bootmgr probe: %v", err)
		}
		readback, err := os.ReadFile(destination)
		if err != nil {
			fatalf("read back bootmgr probe: %v", err)
		}
		want := sha256.Sum256(probe)
		got := sha256.Sum256(readback)
		if want != got {
			fatalf("bootmgr probe readback mismatch: got=%x want=%x", got, want)
		}
		fmt.Printf("DEBUG_BOOTMGR_PROBE=%s bytes=%d sha256=%x\n", destination, len(probe), got)
	}
	fmt.Printf("LOG=%s\n", logAbs)
	fmt.Println("RESULT=PASS")
}
