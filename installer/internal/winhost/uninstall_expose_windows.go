//go:build windows

package winhost

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/hiddenexec"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/uninstall"
)

// exposeUninstallLetterScript gives the formatted exFAT volume a drive letter.
// It runs only after Format-Volume, so Windows never offers to format it.
const exposeUninstallLetterScript = `$ErrorActionPreference = 'Stop'
$diskNumber = [uint32]$env:USOS_EXPOSE_DISK
$offset = [uint64]$env:USOS_EXPOSE_OFFSET
$size = [uint64]$env:USOS_EXPOSE_SIZE
$partGuid = $env:USOS_EXPOSE_PARTUUID.Trim('{}')
$gptType = $env:USOS_EXPOSE_GPTTYPE.Trim('{}')
function Find-Partition {
    $found = @(Get-Partition -DiskNumber $diskNumber | Where-Object {
        ([uint64]$_.Offset -eq $offset) -and
        ([uint64]$_.Size -eq $size) -and
        ($_.Guid.ToString().Trim('{}') -ieq $partGuid) -and
        ($_.GptType.ToString().Trim('{}') -ieq $gptType)
    })
    if ($found.Count -ne 1) { throw "Expected exactly one partition disk=$diskNumber offset=$offset PARTUUID=$partGuid; got $($found.Count)" }
    return $found[0]
}
function Get-LetterPaths($partition) {
    return @($partition.AccessPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and ($_ -match '^[A-Za-z]:\\') })
}
Update-HostStorageCache -ErrorAction SilentlyContinue
$part = Find-Partition
if ((Get-LetterPaths $part).Count -eq 0) {
    Add-PartitionAccessPath -InputObject $part -AssignDriveLetter | Out-Null
}
$letters = @(Get-LetterPaths (Find-Partition))
if ($letters.Count -eq 0) { throw 'exFAT volume did not get a drive letter' }
Write-Output ("PASS letter={0}" -f ($letters -join ','))
`

// ExposeFormattedVolume runs after the uninstall exFAT format: it clears the
// GPT NoDriveLetter bit the partition was created with (so the raw volume
// stayed unmounted) and gives the formatted volume a drive letter.
func (b Backend) ExposeFormattedVolume(media uninstall.MediaLayout) error {
	if strings.TrimSpace(media.Data.PartUUID) == "" {
		return fmt.Errorf("refusing drive-letter update with empty PARTUUID")
	}
	ref := install.MediaLayout{DiskNumber: media.DiskNumber, DiskPTUUID: media.DiskPTUUID}
	if err := b.clearNoDriveLetter(ref, "exFAT", media.Data); err != nil {
		return err
	}
	powershell, err := exec.LookPath("powershell.exe")
	if err != nil {
		return fmt.Errorf("Windows PowerShell is required for the drive letter: %w", err)
	}
	cmd := hiddenexec.Command(powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", exposeUninstallLetterScript)
	cmd.Env = append(os.Environ(),
		"USOS_EXPOSE_DISK="+strconv.FormatUint(uint64(media.DiskNumber), 10),
		"USOS_EXPOSE_OFFSET="+strconv.FormatUint(media.Data.StartBytes, 10),
		"USOS_EXPOSE_SIZE="+strconv.FormatUint(media.Data.SizeBytes, 10),
		"USOS_EXPOSE_PARTUUID="+media.Data.PartUUID,
		"USOS_EXPOSE_GPTTYPE="+guidString(basicDataPartitionType),
	)
	output, err := hiddenexec.CombinedOutput("exFAT drive letter", cmd)
	if err != nil {
		return fmt.Errorf("assign exFAT drive letter: %w: %s", err, strings.TrimSpace(string(output)))
	}
	if !strings.Contains(string(output), "PASS letter=") {
		return fmt.Errorf("assign exFAT drive letter returned unexpected output: %s", strings.TrimSpace(string(output)))
	}
	return nil
}
