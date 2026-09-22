//go:build windows

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
	"github.com/snakex21/universal-service-os/installer/internal/legacyclear"
	"github.com/snakex21/universal-service-os/installer/internal/localupdate"
	"github.com/snakex21/universal-service-os/installer/internal/winhost"
)

func main() {
	serial := flag.String("serial", "USOS-GPT-TEST", "required target serial")
	size := flag.Uint64("size", 42949672960, "required target size in bytes")
	out := flag.String("out", "", "result file path")
	installerPath := flag.String("installer", "", "USOS Installer.exe used by CopyInstallPayload")
	flag.Parse()
	if strings.TrimSpace(*out) == "" || strings.TrimSpace(*installerPath) == "" {
		fmt.Fprintln(os.Stderr, "missing -out or -installer")
		os.Exit(2)
	}

	lines := []string{"USOS Legacy update-clear-update QEMU E2E"}
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

	installerAbs, err := filepath.Abs(*installerPath)
	if err != nil {
		finish(false, fmt.Errorf("resolve installer: %w", err))
	}
	if info, err := os.Stat(installerAbs); err != nil || !info.Mode().IsRegular() || info.Size() == 0 {
		finish(false, fmt.Errorf("invalid installer executable %s: %v", installerAbs, err))
	}

	target, err := findTarget(*serial, *size)
	if err != nil {
		finish(false, err)
	}
	baseline := target
	lines = append(lines, fmt.Sprintf("TARGET=PhysicalDrive%d model=%q serial=%q size=%d", target.Disk.Number, target.Disk.DisplayName(), target.Disk.Serial, target.Disk.SizeBytes))
	lines = append(lines, mediaLine("BASELINE", target))

	sentinelPath := filepath.Join(target.Media.DATA.VolumePath, "Systems", "Windows", "Windows 11", "Images", "UPDATE-CYCLE-SENTINEL.iso")
	if err := os.MkdirAll(filepath.Dir(sentinelPath), 0o755); err != nil {
		finish(false, fmt.Errorf("create sentinel directory: %w", err))
	}
	sentinelBytes := []byte("USOS UPDATE-CLEAR-UPDATE SENTINEL - DATA MUST SURVIVE\r\n")
	if err := os.WriteFile(sentinelPath, sentinelBytes, 0o644); err != nil {
		finish(false, fmt.Errorf("write DATA sentinel: %w", err))
	}
	sentinelHash := sha256Hex(sentinelBytes)
	lines = append(lines, "SENTINEL_BEFORE_SHA256="+sentinelHash)

	logDir := filepath.Dir(*out)
	backend := winhost.Backend{InstallerExecutable: installerAbs}

	if err := runUpdate("UPDATE1", target, backend, filepath.Join(logDir, "USOS Legacy Cycle Update1.log"), &lines); err != nil {
		finish(false, err)
	}
	if err := verifySentinel(sentinelPath, sentinelHash); err != nil {
		finish(false, fmt.Errorf("after UPDATE1: %w", err))
	}
	target, err = findTarget(*serial, *size)
	if err != nil {
		finish(false, fmt.Errorf("re-enumerate after UPDATE1: %w", err))
	}
	if !sameMedia(baseline, target) {
		finish(false, fmt.Errorf("GPT/media changed during UPDATE1"))
	}
	lines = append(lines, "UPDATE1_GPT_UNCHANGED=PASS", "UPDATE1_SENTINEL=PASS")

	if err := runClear(target, backend, filepath.Join(logDir, "USOS Legacy Cycle Clear.log"), &lines); err != nil {
		finish(false, err)
	}
	if err := verifySentinel(sentinelPath, sentinelHash); err != nil {
		finish(false, fmt.Errorf("after CLEAR: %w", err))
	}
	target, err = findTarget(*serial, *size)
	if err != nil {
		finish(false, fmt.Errorf("re-enumerate after CLEAR: %w", err))
	}
	if !sameMedia(baseline, target) {
		finish(false, fmt.Errorf("GPT/media changed during CLEAR"))
	}
	if err := backend.VerifyInstalledLegacyBootCleared(target); err != nil {
		finish(false, fmt.Errorf("explicit clear read-back verification: %w", err))
	}
	lines = append(lines, "CLEAR_GPT_UNCHANGED=PASS", "CLEAR_SENTINEL=PASS", "CLEAR_ZERO_READBACK=PASS")

	if err := runUpdate("UPDATE2", target, backend, filepath.Join(logDir, "USOS Legacy Cycle Update2.log"), &lines); err != nil {
		finish(false, err)
	}
	if err := verifySentinel(sentinelPath, sentinelHash); err != nil {
		finish(false, fmt.Errorf("after UPDATE2: %w", err))
	}
	finalTarget, err := findTarget(*serial, *size)
	if err != nil {
		finish(false, fmt.Errorf("re-enumerate after UPDATE2: %w", err))
	}
	if !sameMedia(baseline, finalTarget) {
		finish(false, fmt.Errorf("GPT/media changed during UPDATE2"))
	}
	if _, err := backend.RestoreLegacyBoot(finalTarget); err != nil {
		finish(false, fmt.Errorf("final idempotent Legacy read/write verification: %w", err))
	}
	if err := verifySentinel(sentinelPath, sentinelHash); err != nil {
		finish(false, fmt.Errorf("final sentinel verification: %w", err))
	}
	lines = append(lines, "UPDATE2_GPT_UNCHANGED=PASS", "UPDATE2_SENTINEL=PASS", "FINAL_LEGACY_IDEMPOTENT=PASS")
	finish(true, nil)
}

func runUpdate(prefix string, target installed.Target, backend winhost.Backend, logPath string, lines *[]string) error {
	logger, err := install.NewOperationLoggerAt(logPath)
	if err != nil {
		return fmt.Errorf("%s logger: %w", prefix, err)
	}
	defer logger.Close()
	engine, err := localupdate.NewEngine(backend, logger)
	if err != nil {
		return fmt.Errorf("%s engine: %w", prefix, err)
	}
	var final *install.VerificationReport
	var finalErr error
	for event := range engine.RunAsync(target) {
		switch event.Kind {
		case localupdate.EventLog:
			if strings.Contains(event.Message, "LEGACY_BOOT ") || strings.Contains(event.Message, "PAYLOAD AFTER") {
				*lines = append(*lines, prefix+" LOG="+event.Message)
			}
		case localupdate.EventStage:
			if stage, ok := localupdate.StageInfo(event.StageID); ok && (event.State == localupdate.StateSucceeded || event.State == localupdate.StateFailed) {
				*lines = append(*lines, fmt.Sprintf("%s STAGE=%d/%d state=%d name=%q", prefix, stage.Number, localupdate.StageCount, event.State, stage.Name))
			}
		case localupdate.EventFinished:
			final = event.Verification
			finalErr = event.Err
		}
	}
	if finalErr != nil {
		return fmt.Errorf("%s failed: %w", prefix, finalErr)
	}
	if final == nil || !final.OK() {
		return fmt.Errorf("%s returned no successful verification", prefix)
	}
	*lines = append(*lines, prefix+"=PASS")
	return nil
}

func runClear(target installed.Target, backend winhost.Backend, logPath string, lines *[]string) error {
	logger, err := install.NewOperationLoggerAt(logPath)
	if err != nil {
		return fmt.Errorf("CLEAR logger: %w", err)
	}
	defer logger.Close()
	engine, err := legacyclear.NewEngine(backend, logger)
	if err != nil {
		return fmt.Errorf("CLEAR engine: %w", err)
	}
	var finalErr error
	for event := range engine.RunAsync(target) {
		switch event.Kind {
		case legacyclear.EventLog:
			if strings.Contains(event.Message, "LEGACY_CLEAR ") {
				*lines = append(*lines, "CLEAR LOG="+event.Message)
			}
		case legacyclear.EventStage:
			if stage, ok := legacyclear.StageInfo(event.StageID); ok && (event.State == legacyclear.StateSucceeded || event.State == legacyclear.StateFailed) {
				*lines = append(*lines, fmt.Sprintf("CLEAR STAGE=%d/%d state=%d name=%q", stage.Number, legacyclear.StageCount, event.State, stage.Name))
			}
		case legacyclear.EventFinished:
			finalErr = event.Err
		}
	}
	if finalErr != nil {
		return fmt.Errorf("CLEAR failed: %w", finalErr)
	}
	*lines = append(*lines, "CLEAR=PASS")
	return nil
}

func findTarget(serial string, size uint64) (installed.Target, error) {
	targets, err := (winhost.InstalledUSOSSource{}).ListInstalledUSOS()
	if err != nil {
		return installed.Target{}, fmt.Errorf("enumerate installed USOS: %w", err)
	}
	matches := make([]installed.Target, 0, 1)
	for _, target := range targets {
		if strings.TrimSpace(target.Disk.Serial) == strings.TrimSpace(serial) && target.Disk.SizeBytes == size && target.Disk.Removable && !target.Disk.SystemDisk {
			matches = append(matches, target)
		}
	}
	if len(matches) != 1 {
		return installed.Target{}, fmt.Errorf("expected exactly one installed removable USOS target serial=%q size=%d, found %d", serial, size, len(matches))
	}
	return matches[0], nil
}

func sameMedia(a, b installed.Target) bool {
	return a.Media.DiskNumber == b.Media.DiskNumber &&
		strings.EqualFold(a.Media.DiskPTUUID, b.Media.DiskPTUUID) &&
		samePartition(a.Media.ESP, b.Media.ESP) &&
		samePartition(a.Media.DATA, b.Media.DATA) &&
		samePartition(a.Media.WORK, b.Media.WORK)
}

func samePartition(a, b install.PartitionRef) bool {
	return a.Number == b.Number && a.StartBytes == b.StartBytes && a.SizeBytes == b.SizeBytes && strings.EqualFold(a.PartUUID, b.PartUUID)
}

func mediaLine(prefix string, target installed.Target) string {
	return fmt.Sprintf("%s disk=%s esp=%s@%d+%d data=%s@%d+%d work=%s@%d+%d", prefix, target.Media.DiskPTUUID, target.Media.ESP.PartUUID, target.Media.ESP.StartBytes, target.Media.ESP.SizeBytes, target.Media.DATA.PartUUID, target.Media.DATA.StartBytes, target.Media.DATA.SizeBytes, target.Media.WORK.PartUUID, target.Media.WORK.StartBytes, target.Media.WORK.SizeBytes)
}

func verifySentinel(path, expectedHash string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read DATA sentinel: %w", err)
	}
	actual := sha256Hex(data)
	if actual != expectedHash {
		return fmt.Errorf("DATA sentinel SHA-256 changed: got=%s want=%s", actual, expectedHash)
	}
	return nil
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return strings.ToUpper(hex.EncodeToString(sum[:]))
}
