//go:build windows

package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
	"github.com/snakex21/universal-service-os/installer/internal/localupdate"
	"github.com/snakex21/universal-service-os/installer/internal/winhost"
)

type mountedVirtualBackend struct {
	winhost.Backend
}

func (b mountedVirtualBackend) RevalidateInstalledUSOS(expected installed.Target) (installed.Target, error) {
	current, err := winhost.InspectInstalledUSOSReadOnly(expected.Disk)
	if err != nil {
		return installed.Target{}, err
	}
	if current.Identity != expected.Identity {
		return installed.Target{}, fmt.Errorf("usos-device.ini changed since initial mounted-image inspection")
	}
	if !sameMedia(current.Media, expected.Media) {
		return installed.Target{}, fmt.Errorf("GPT identity/layout changed since initial mounted-image inspection")
	}
	return current, nil
}

func (b mountedVirtualBackend) Verify(media install.MediaLayout, expected install.DeviceINI) (install.VerificationReport, error) {
	script := fmt.Sprintf(`$p=Get-Partition -DiskNumber %d -PartitionNumber %d; if(-not $p.DriveLetter){Add-PartitionAccessPath -DiskNumber %d -PartitionNumber %d -AssignDriveLetter | Out-Null; Start-Sleep -Milliseconds 250; $p=Get-Partition -DiskNumber %d -PartitionNumber %d}; if(-not $p.DriveLetter){throw 'temporary DATA drive letter assignment failed'}; Write-Output $p.DriveLetter`,
		media.DiskNumber, media.DATA.Number,
		media.DiskNumber, media.DATA.Number,
		media.DiskNumber, media.DATA.Number,
	)
	cmd := exec.Command("powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return install.VerificationReport{}, fmt.Errorf("assign temporary DATA drive letter before production verification: %w: %s", err, strings.TrimSpace(string(out)))
	}
	fmt.Printf("[PASS] temporary DATA drive letter assigned before verification: %s:\n", strings.TrimSpace(string(out)))
	return b.Backend.Verify(media, expected)
}

func sameMedia(a, b install.MediaLayout) bool {
	return a.DiskNumber == b.DiskNumber &&
		strings.EqualFold(a.DiskPTUUID, b.DiskPTUUID) &&
		samePartition(a.ESP, b.ESP) &&
		samePartition(a.DATA, b.DATA) &&
		samePartition(a.WORK, b.WORK)
}

func samePartition(a, b install.PartitionRef) bool {
	return a.Number == b.Number &&
		a.StartBytes == b.StartBytes &&
		a.SizeBytes == b.SizeBytes &&
		strings.EqualFold(a.PartUUID, b.PartUUID)
}

func main() {
	diskNumber := flag.Uint("disk", ^uint(0), "mounted file-backed USOS disk number")
	installerPath := flag.String("installer", "", "USOS Installer.exe used by CopyInstallPayload")
	logPath := flag.String("log", "", "operation log path")
	flag.Parse()

	if *diskNumber == ^uint(0) {
		fatalf("missing -disk")
	}
	if strings.TrimSpace(*installerPath) == "" {
		fatalf("missing -installer")
	}
	installerAbs, err := filepath.Abs(*installerPath)
	if err != nil {
		fatalf("resolve installer path: %v", err)
	}
	if info, err := os.Stat(installerAbs); err != nil || !info.Mode().IsRegular() || info.Size() <= 0 {
		fatalf("invalid installer executable %s: %v", installerAbs, err)
	}
	if strings.TrimSpace(*logPath) == "" {
		*logPath = filepath.Join(filepath.Dir(installerAbs), "USOS Backend E2E Update.log")
	}

	disk, err := diskByNumber(uint32(*diskNumber))
	if err != nil {
		fatalf("locate mounted test disk: %v", err)
	}
	if disk.SystemDisk {
		fatalf("refusing system disk PhysicalDrive%d", disk.Number)
	}
	identityText := strings.ToLower(strings.Join([]string{disk.Model, disk.Vendor, disk.Product}, " "))
	if !strings.Contains(identityText, "virtual") {
		fatalf("refusing non-virtual disk PhysicalDrive%d model=%q vendor=%q product=%q", disk.Number, disk.Model, disk.Vendor, disk.Product)
	}

	target, err := winhost.InspectInstalledUSOSReadOnly(disk)
	if err != nil {
		fatalf("mounted image is not a valid installed USOS target: %v", err)
	}
	fmt.Printf("[PASS] mounted production USOS target PhysicalDrive%d disk=%s DATA=%s WORK=%s\n", disk.Number, target.Media.DiskPTUUID, target.Media.DATA.PartUUID, target.Media.WORK.PartUUID)

	logger, err := install.NewOperationLoggerAt(*logPath)
	if err != nil {
		fatalf("create update logger: %v", err)
	}
	defer logger.Close()

	backend := mountedVirtualBackend{Backend: winhost.Backend{InstallerExecutable: installerAbs}}
	engine, err := localupdate.NewEngine(backend, logger)
	if err != nil {
		fatalf("create production local-update engine: %v", err)
	}

	var final *install.VerificationReport
	var finalErr error
	for event := range engine.RunAsync(target) {
		switch event.Kind {
		case localupdate.EventLog:
			fmt.Println(event.Message)
		case localupdate.EventStage:
			if stage, ok := localupdate.StageInfo(event.StageID); ok {
				fmt.Printf("[STAGE] %d/%d %s state=%d progress=%.3f\n", stage.Number, localupdate.StageCount, stage.Name, event.State, event.Progress)
			}
		case localupdate.EventFinished:
			final = event.Verification
			finalErr = event.Err
		}
	}
	if final != nil {
		for _, item := range final.Items {
			fmt.Printf("[VERIFY] %s match=%v expected=%s actual=%s\n", item.Name, item.Match, item.Expected, item.Actual)
		}
	}
	if finalErr != nil {
		fatalf("production local update failed: %v", finalErr)
	}
	if final == nil || !final.OK() {
		fatalf("production local update returned missing/failed verification report")
	}
	fmt.Println("[PASS] production CopyInstallPayload generated and verified backend templates")
}

func diskByNumber(number uint32) (domain.Disk, error) {
	disks, err := (winhost.Enumerator{}).ListDisks()
	if err != nil {
		return domain.Disk{}, err
	}
	for _, disk := range disks {
		if disk.Number == number {
			return disk, nil
		}
	}
	return domain.Disk{}, fmt.Errorf("PhysicalDrive%d not found", number)
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "[FAIL] "+format+"\n", args...)
	os.Exit(1)
}
