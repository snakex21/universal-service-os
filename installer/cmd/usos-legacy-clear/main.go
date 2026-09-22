//go:build windows

package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/legacyclear"
	"github.com/snakex21/universal-service-os/installer/internal/winhost"
)

func main() {
	diskNumber := flag.Uint("disk", 0, "required PhysicalDrive number")
	model := flag.String("model", "", "required full model")
	size := flag.Uint64("size", 0, "required size in bytes")
	confirm := flag.String("confirm", "", "must exactly equal CLEAR LEGACY ONLY")
	logPath := flag.String("log", "USOS Legacy Clear.log", "operation log path")
	flag.Parse()

	fatalf := func(format string, args ...any) {
		fmt.Fprintf(os.Stderr, "FAIL: "+format+"\n", args...)
		os.Exit(1)
	}
	if *diskNumber == 0 || strings.TrimSpace(*model) == "" || *size == 0 {
		fatalf("disk, model and size are required")
	}
	if *confirm != "CLEAR LEGACY ONLY" {
		fatalf("confirmation mismatch: -confirm must exactly equal CLEAR LEGACY ONLY")
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

	logAbs, err := filepath.Abs(*logPath)
	if err != nil {
		fatalf("resolve log path: %v", err)
	}
	logger, err := install.NewOperationLoggerAt(logAbs)
	if err != nil {
		fatalf("open operation log: %v", err)
	}
	defer logger.Close()
	engine, err := legacyclear.NewEngine(winhost.Backend{}, logger)
	if err != nil {
		fatalf("create Legacy clear engine: %v", err)
	}

	fmt.Printf("CONFIRMED PhysicalDrive%d model=%q serial=%q size=%d\n", target.Disk.Number, target.Disk.DisplayName(), target.Disk.Serial, target.Disk.SizeBytes)
	var finalErr error
	for event := range engine.RunAsync(target) {
		switch event.Kind {
		case legacyclear.EventLog:
			fmt.Println(event.Message)
		case legacyclear.EventStage:
			if stage, ok := legacyclear.StageInfo(event.StageID); ok {
				switch event.State {
				case legacyclear.StateActive:
					fmt.Printf("STAGE %d/%d START %s\n", stage.Number, legacyclear.StageCount, stage.Name)
				case legacyclear.StateSucceeded:
					fmt.Printf("STAGE %d/%d PASS %s\n", stage.Number, legacyclear.StageCount, stage.Name)
				case legacyclear.StateFailed:
					fmt.Printf("STAGE %d/%d FAIL %s: %v\n", stage.Number, legacyclear.StageCount, stage.Name, event.Err)
				}
			}
		case legacyclear.EventFinished:
			finalErr = event.Err
		}
	}
	if finalErr != nil {
		fatalf("Legacy clear stopped: %v", finalErr)
	}
	fmt.Printf("LOG=%s\n", logAbs)
	fmt.Println("RESULT=PASS")
}
