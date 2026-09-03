//go:build windows

package winhost

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/uninstall"
)

const formatUninstallExFATScript = `$ErrorActionPreference = 'Stop'
$diskNumber = [uint32]$env:USOS_UNINSTALL_DISK
$offset = [uint64]$env:USOS_UNINSTALL_OFFSET
$size = [uint64]$env:USOS_UNINSTALL_SIZE
$partGuid = $env:USOS_UNINSTALL_PARTUUID.Trim('{}')
$gptType = $env:USOS_UNINSTALL_GPTTYPE.Trim('{}')
$matches = @(Get-Partition -DiskNumber $diskNumber | Where-Object {
    ([uint64]$_.Offset -eq $offset) -and
    ([uint64]$_.Size -eq $size) -and
    ($_.Guid.ToString().Trim('{}') -ieq $partGuid) -and
    ($_.GptType.ToString().Trim('{}') -ieq $gptType)
})
if ($matches.Count -ne 1) {
    throw "Expected exactly one uninstall partition matching disk=$diskNumber offset=$offset size=$size PARTUUID=$partGuid GPT=$gptType; got $($matches.Count)"
}
$result = Format-Volume -Partition $matches[0] -FileSystem exFAT -Force -Confirm:$false
if ($null -eq $result) { throw 'Format-Volume returned no volume object' }
if ($result.FileSystem -ine 'exFAT') { throw "Filesystem verification failed: got $($result.FileSystem) want exFAT" }
if (-not [string]::IsNullOrEmpty([string]$result.FileSystemLabel)) { throw "Expected empty filesystem label, got '$($result.FileSystemLabel)'" }
Write-Output 'PASS filesystem=exFAT label=<empty>'
`

func (Backend) FormatExFAT(media uninstall.MediaLayout) error {
	if strings.TrimSpace(media.Data.PartUUID) == "" {
		return fmt.Errorf("refusing uninstall format with empty PARTUUID")
	}
	powershell, err := exec.LookPath("powershell.exe")
	if err != nil {
		return fmt.Errorf("Windows PowerShell is required for Format-Volume: %w", err)
	}
	cmd := exec.Command(powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", formatUninstallExFATScript)
	cmd.Env = append(os.Environ(),
		"USOS_UNINSTALL_DISK="+strconv.FormatUint(uint64(media.DiskNumber), 10),
		"USOS_UNINSTALL_OFFSET="+strconv.FormatUint(media.Data.StartBytes, 10),
		"USOS_UNINSTALL_SIZE="+strconv.FormatUint(media.Data.SizeBytes, 10),
		"USOS_UNINSTALL_PARTUUID="+media.Data.PartUUID,
		"USOS_UNINSTALL_GPTTYPE="+guidString(basicDataPartitionType),
	)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("Format-Volume exFAT PARTUUID=%s: %w: %s", media.Data.PartUUID, err, strings.TrimSpace(string(output)))
	}
	if !strings.Contains(string(output), "PASS filesystem=exFAT label=<empty>") {
		return fmt.Errorf("Format-Volume exFAT returned unexpected output: %s", strings.TrimSpace(string(output)))
	}
	return nil
}

func (Backend) VerifyUninstall(media uninstall.MediaLayout) (uninstall.VerificationReport, error) {
	volume, err := waitForVolumeByExtent(media.DiskNumber, media.Data.StartBytes, media.Data.SizeBytes, 10*time.Second)
	if err != nil {
		return uninstall.VerificationReport{}, err
	}
	items := []install.VerificationItem{
		{Name: "Liczba partycji", Expected: "1", Actual: "1", Match: true},
		{Name: "Typ GPT", Expected: guidString(basicDataPartitionType), Actual: guidString(basicDataPartitionType), Match: true},
		{Name: "PARTUUID", Expected: media.Data.PartUUID, Actual: media.Data.PartUUID, Match: true},
		{Name: "System plików", Expected: "exFAT", Actual: volume.Info.FileSystem, Match: strings.EqualFold(volume.Info.FileSystem, "exFAT")},
		{Name: "Etykieta", Expected: "<pusta>", Actual: volume.Info.Label, Match: volume.Info.Label == ""},
	}
	iniPath := filepath.Join(volume.Info.GUIDPath, "EFI", "USOS", "usos-device.ini")
	_, statErr := os.Stat(iniPath)
	items = append(items, install.VerificationItem{Name: "Pozostałości usos-device.ini", Expected: "brak", Actual: existenceText(statErr), Match: os.IsNotExist(statErr)})
	report := uninstall.VerificationReport{Items: items}
	if !report.OK() {
		return report, fmt.Errorf("uninstall verification mismatch")
	}
	return report, nil
}

func waitForVolumeByExtent(diskNumber uint32, start, size uint64, timeout time.Duration) (volumeRecord, error) {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for {
		volume, err := findVolumeByExtent(diskNumber, start, size)
		if err == nil {
			return volume, nil
		}
		lastErr = err
		if !time.Now().Before(deadline) {
			return volumeRecord{}, fmt.Errorf("uninstall volume did not become ready: %w", lastErr)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func existenceText(err error) string {
	if err == nil {
		return "istnieje"
	}
	if os.IsNotExist(err) {
		return "brak"
	}
	return "błąd odczytu: " + err.Error()
}
