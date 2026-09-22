//go:build windows

package main

import (
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
	serial := flag.String("serial", "USOS-GPT-TEST", "required removable target serial")
	size := flag.Uint64("size", 40*1024*1024*1024, "required target size in bytes")
	installerPath := flag.String("installer", "", "USOS Installer.exe used by CopyInstallPayload")
	outPath := flag.String("out", "", "result file path")
	logPath := flag.String("log", "", "operation log path")
	flag.Parse()

	lines := []string{"USOS local-update QEMU E2E"}
	finish := func(ok bool, err error) {
		if err != nil {
			lines = append(lines, "ERROR="+err.Error())
		}
		if ok {
			lines = append(lines, "RESULT=PASS")
		} else {
			lines = append(lines, "RESULT=FAIL")
		}
		if strings.TrimSpace(*outPath) != "" {
			_ = os.WriteFile(*outPath, []byte(strings.Join(lines, "\r\n")+"\r\n"), 0o644)
		}
		for _, line := range lines {
			fmt.Println(line)
		}
		if ok {
			os.Exit(0)
		}
		os.Exit(1)
	}

	if strings.TrimSpace(*installerPath) == "" {
		finish(false, fmt.Errorf("missing -installer"))
	}
	installerAbs, err := filepath.Abs(*installerPath)
	if err != nil {
		finish(false, fmt.Errorf("resolve installer path: %w", err))
	}
	if info, statErr := os.Stat(installerAbs); statErr != nil || !info.Mode().IsRegular() || info.Size() <= 0 {
		finish(false, fmt.Errorf("invalid installer executable %s: %v", installerAbs, statErr))
	}

	targets, err := (winhost.InstalledUSOSSource{}).ListInstalledUSOS()
	if err != nil {
		finish(false, fmt.Errorf("enumerate installed USOS targets: %w", err))
	}
	var selected = -1
	for i := range targets {
		disk := targets[i].Disk
		if strings.TrimSpace(disk.Serial) != strings.TrimSpace(*serial) || disk.SizeBytes != *size {
			continue
		}
		if disk.SystemDisk || !disk.Removable {
			finish(false, fmt.Errorf("refusing unsafe target PhysicalDrive%d system=%v removable=%v", disk.Number, disk.SystemDisk, disk.Removable))
		}
		if selected >= 0 {
			finish(false, fmt.Errorf("multiple installed USOS targets match serial=%q size=%d", *serial, *size))
		}
		selected = i
	}
	if selected < 0 {
		finish(false, fmt.Errorf("no installed removable USOS target matches serial=%q size=%d", *serial, *size))
	}
	target := targets[selected]
	lines = append(lines, fmt.Sprintf("TARGET=PhysicalDrive%d serial=%q size=%d gpt=%s", target.Disk.Number, target.Disk.Serial, target.Disk.SizeBytes, target.Media.DiskPTUUID))

	if strings.TrimSpace(*logPath) == "" {
		if strings.TrimSpace(*outPath) != "" {
			*logPath = filepath.Join(filepath.Dir(*outPath), "USOS Local Update QEMU E2E.log")
		} else {
			*logPath = filepath.Join(filepath.Dir(installerAbs), "USOS Local Update QEMU E2E.log")
		}
	}
	logger, err := install.NewOperationLoggerAt(*logPath)
	if err != nil {
		finish(false, fmt.Errorf("create logger: %w", err))
	}
	defer logger.Close()

	engine, err := localupdate.NewEngine(winhost.Backend{InstallerExecutable: installerAbs}, logger)
	if err != nil {
		finish(false, fmt.Errorf("create local update engine: %w", err))
	}
	var final *install.VerificationReport
	var finalErr error
	for event := range engine.RunAsync(target) {
		switch event.Kind {
		case localupdate.EventLog:
			lines = append(lines, "LOG="+event.Message)
		case localupdate.EventStage:
			if stage, ok := localupdate.StageInfo(event.StageID); ok {
				lines = append(lines, fmt.Sprintf("STAGE=%d/%d state=%d progress=%.6f name=%q", stage.Number, localupdate.StageCount, event.State, event.Progress, stage.Name))
			}
		case localupdate.EventFinished:
			final = event.Verification
			finalErr = event.Err
		}
	}
	if final != nil {
		for _, item := range final.Items {
			lines = append(lines, fmt.Sprintf("VERIFY name=%q match=%v expected=%q actual=%q", item.Name, item.Match, item.Expected, item.Actual))
		}
	}
	if finalErr != nil {
		finish(false, fmt.Errorf("local update stopped: %w", finalErr))
	}
	if final == nil || !final.OK() {
		finish(false, fmt.Errorf("local update returned no successful final verification"))
	}
	finish(true, nil)
}
