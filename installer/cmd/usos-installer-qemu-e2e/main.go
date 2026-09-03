//go:build windows

package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/layout"
	"github.com/snakex21/universal-service-os/installer/internal/winhost"
)

const seedScript = `$ErrorActionPreference = 'Stop'
$diskNumber = [uint32]$env:USOS_TEST_DISK
$disk = Get-Disk -Number $diskNumber
Set-Disk -Number $diskNumber -IsOffline $false
Set-Disk -Number $diskNumber -IsReadOnly $false
if ($disk.PartitionStyle -ne 'RAW') {
    Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Partition -DiskNumber $diskNumber -PartitionNumber $_.PartitionNumber -Confirm:$false -ErrorAction SilentlyContinue
    }
    Clear-Disk -Number $diskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue
}
$disk = Get-Disk -Number $diskNumber
if ($disk.PartitionStyle -eq 'RAW') { Initialize-Disk -Number $diskNumber -PartitionStyle GPT | Out-Null }
$partition = New-Partition -DiskNumber $diskNumber -UseMaximumSize -AssignDriveLetter
$volume = Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel 'USOS_PREEXISTING' -Force -Confirm:$false
$root = "$($volume.DriveLetter):\"
[IO.File]::WriteAllText((Join-Path $root 'MUST_BE_DESTROYED.txt'), 'pre-existing data')
Write-Output ("SEEDED drive={0}:" -f $volume.DriveLetter)
`

func main() {
	serial := flag.String("serial", "USOS-GPT-TEST", "required target serial")
	size := flag.Uint64("size", 40*layout.GiB, "required target size in bytes")
	out := flag.String("out", "", "result file path")
	installerPath := flag.String("installer", "", "final USOS Installer.exe to copy into DATA\\TOOLS; defaults to sibling of this test executable")
	flag.Parse()
	if strings.TrimSpace(*out) == "" {
		fmt.Fprintln(os.Stderr, "missing -out")
		os.Exit(2)
	}
	if strings.TrimSpace(*installerPath) == "" {
		executable, err := os.Executable()
		if err != nil {
			fmt.Fprintln(os.Stderr, "locate E2E executable:", err)
			os.Exit(2)
		}
		*installerPath = filepath.Join(filepath.Dir(executable), "USOS Installer.exe")
	}

	lines := []string{"USOS Installer QEMU full E2E"}
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

	target, err := findTarget(*serial, *size)
	if err != nil {
		finish(false, err)
	}
	lines = append(lines, fmt.Sprintf("TARGET_BEFORE_SEED=PhysicalDrive%d model=%q serial=%q size=%d", target.Number, target.Model, target.Serial, target.SizeBytes))
	if err := seedExistingVolume(target.Number); err != nil {
		finish(false, fmt.Errorf("seed existing target volume: %w", err))
	}
	lines = append(lines, "PREEXISTING_VOLUME_CREATED=PASS")

	target, err = findTarget(*serial, *size)
	if err != nil {
		finish(false, fmt.Errorf("re-enumerate seeded target: %w", err))
	}
	if len(target.Volumes) == 0 {
		finish(false, fmt.Errorf("seeded target has no visible volume; lock/dismount path would not be exercised"))
	}
	foundSeed := false
	for _, volume := range target.Volumes {
		lines = append(lines, fmt.Sprintf("PREEXISTING volume=%s label=%q fs=%q used=%d", volume.GUIDPath, volume.Label, volume.FileSystem, volume.UsedBytes))
		if volume.Label == "USOS_PREEXISTING" && strings.EqualFold(volume.FileSystem, "NTFS") {
			foundSeed = true
		}
	}
	if !foundSeed {
		finish(false, fmt.Errorf("pre-existing NTFS volume was not found after seeding"))
	}

	loggerPath := filepath.Join(filepath.Dir(*out), "USOS Installer E2E.log")
	logger, err := install.NewOperationLoggerAt(loggerPath)
	if err != nil {
		finish(false, fmt.Errorf("create installer logger: %w", err))
	}
	defer logger.Close()
	engine, err := install.NewEngine(winhost.Backend{InstallerExecutable: *installerPath}, logger)
	if err != nil {
		finish(false, err)
	}

	var final *install.VerificationReport
	var finalErr error
	for event := range engine.RunAsync(target) {
		switch event.Kind {
		case install.EventLog:
			lines = append(lines, "LOG="+event.Message)
		case install.EventStage:
			stage, _ := install.Stage(event.StageID)
			lines = append(lines, fmt.Sprintf("STAGE=%d/%d state=%d measurable=%v progress=%.6f name=%q", stage.Number, install.StageCount, event.State, event.ProgressKnown, event.Progress, stage.Name))
		case install.EventFinished:
			final = event.Verification
			finalErr = event.Err
		}
	}
	if final != nil {
		for _, item := range final.Items {
			lines = append(lines, fmt.Sprintf("VERIFY name=%q expected=%q actual=%q match=%v", item.Name, item.Expected, item.Actual, item.Match))
		}
	}
	if finalErr != nil {
		finish(false, fmt.Errorf("installer engine: %w", finalErr))
	}
	if final == nil || !final.OK() {
		finish(false, fmt.Errorf("missing or failed final verification report"))
	}
	finish(true, nil)
}

func findTarget(serial string, size uint64) (domain.Disk, error) {
	disks, err := (winhost.Enumerator{}).ListDisks()
	if err != nil {
		return domain.Disk{}, fmt.Errorf("enumerate disks: %w", err)
	}
	matches := make([]domain.Disk, 0, 1)
	for _, disk := range disks {
		if strings.TrimSpace(disk.Serial) == strings.TrimSpace(serial) && disk.SizeBytes == size && disk.Removable && !disk.SystemDisk {
			matches = append(matches, disk)
		}
	}
	if len(matches) != 1 {
		return domain.Disk{}, fmt.Errorf("expected exactly one removable target serial=%q size=%d, found %d", serial, size, len(matches))
	}
	if !matches[0].Eligible {
		return domain.Disk{}, fmt.Errorf("strict target is not eligible: %s", matches[0].Reason)
	}
	return matches[0], nil
}

func seedExistingVolume(diskNumber uint32) error {
	powershell, err := exec.LookPath("powershell.exe")
	if err != nil {
		return fmt.Errorf("full Windows PowerShell is required for E2E seed: %w", err)
	}
	cmd := exec.Command(powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", seedScript)
	cmd.Env = append(os.Environ(), "USOS_TEST_DISK="+strconv.FormatUint(uint64(diskNumber), 10))
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("seed script: %w: %s", err, strings.TrimSpace(string(output)))
	}
	if !strings.Contains(string(output), "SEEDED drive=") {
		return fmt.Errorf("seed script returned unexpected output: %s", strings.TrimSpace(string(output)))
	}
	return nil
}
