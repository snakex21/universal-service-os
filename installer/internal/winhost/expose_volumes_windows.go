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
)

// exposeLettersScript gives the formatted DATA volume a drive letter (the
// user copies images there) and keeps WORK without one. It runs only after
// both volumes are formatted, so Windows never offers to format them.
const exposeLettersScript = `$ErrorActionPreference = 'Stop'
$diskNumber = [uint32]$env:USOS_EXPOSE_DISK
$gptType = $env:USOS_EXPOSE_GPTTYPE.Trim('{}')
function Find-UsosPartition([uint64]$offset, [uint64]$size, [string]$partGuid) {
    $found = @(Get-Partition -DiskNumber $diskNumber | Where-Object {
        ([uint64]$_.Offset -eq $offset) -and
        ([uint64]$_.Size -eq $size) -and
        ($_.Guid.ToString().Trim('{}') -ieq $partGuid.Trim('{}')) -and
        ($_.GptType.ToString().Trim('{}') -ieq $gptType)
    })
    if ($found.Count -ne 1) { throw "Expected exactly one partition disk=$diskNumber offset=$offset PARTUUID=$partGuid; got $($found.Count)" }
    return $found[0]
}
function Get-LetterPaths($partition) {
    return @($partition.AccessPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and ($_ -match '^[A-Za-z]:\\') })
}
Update-HostStorageCache -ErrorAction SilentlyContinue
$work = Find-UsosPartition ([uint64]$env:USOS_EXPOSE_WORK_OFFSET) ([uint64]$env:USOS_EXPOSE_WORK_SIZE) $env:USOS_EXPOSE_WORK_PARTUUID
foreach ($path in (Get-LetterPaths $work)) {
    Remove-PartitionAccessPath -InputObject $work -AccessPath $path -Confirm:$false | Out-Null
}
$data = Find-UsosPartition ([uint64]$env:USOS_EXPOSE_DATA_OFFSET) ([uint64]$env:USOS_EXPOSE_DATA_SIZE) $env:USOS_EXPOSE_DATA_PARTUUID
if ((Get-LetterPaths $data).Count -eq 0) {
    Add-PartitionAccessPath -InputObject $data -AssignDriveLetter | Out-Null
}
$data = Find-UsosPartition ([uint64]$env:USOS_EXPOSE_DATA_OFFSET) ([uint64]$env:USOS_EXPOSE_DATA_SIZE) $env:USOS_EXPOSE_DATA_PARTUUID
$work = Find-UsosPartition ([uint64]$env:USOS_EXPOSE_WORK_OFFSET) ([uint64]$env:USOS_EXPOSE_WORK_SIZE) $env:USOS_EXPOSE_WORK_PARTUUID
$dataLetters = @(Get-LetterPaths $data)
$workLetters = @(Get-LetterPaths $work)
if ($dataLetters.Count -eq 0) { throw 'DATA did not get a drive letter' }
if ($workLetters.Count -ne 0) { throw "WORK still has drive letters: $($workLetters -join ',')" }
Write-Output ("PASS data={0}" -f ($dataLetters -join ','))
`

// ExposeFormattedVolumes runs after DATA and WORK are formatted: it clears
// their GPT NoDriveLetter bit (set at creation so the raw volumes stay
// unmounted), sets GPT bit 1 when hideDataWorkFromFirmwareMenu is on (single
// firmware boot-menu entry) and gives DATA a drive letter while WORK keeps
// none.
func (b Backend) ExposeFormattedVolumes(media install.MediaLayout) error {
	if err := b.applyInstalledDataWorkAttributes(media, "DATA/WORK"); err != nil {
		return err
	}
	cmd, err := exposeLettersCommand(media)
	if err != nil {
		return err
	}
	output, err := hiddenexec.CombinedOutput("DATA drive letter", cmd)
	if err != nil {
		return fmt.Errorf("assign DATA drive letter: %w: %s", err, strings.TrimSpace(string(output)))
	}
	if !strings.Contains(string(output), "PASS data=") {
		return fmt.Errorf("assign DATA drive letter returned unexpected output: %s", strings.TrimSpace(string(output)))
	}
	return nil
}

func exposeLettersCommand(media install.MediaLayout) (*exec.Cmd, error) {
	if strings.TrimSpace(media.DATA.PartUUID) == "" || strings.TrimSpace(media.WORK.PartUUID) == "" {
		return nil, fmt.Errorf("refusing drive-letter update with empty PARTUUID")
	}
	powershell, err := exec.LookPath("powershell.exe")
	if err != nil {
		return nil, fmt.Errorf("Windows PowerShell is required for the DATA drive letter: %w", err)
	}
	cmd := hiddenexec.Command(powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", exposeLettersScript)
	cmd.Env = append(os.Environ(),
		"USOS_EXPOSE_DISK="+strconv.FormatUint(uint64(media.DiskNumber), 10),
		"USOS_EXPOSE_GPTTYPE="+guidString(basicDataPartitionType),
		"USOS_EXPOSE_DATA_OFFSET="+strconv.FormatUint(media.DATA.StartBytes, 10),
		"USOS_EXPOSE_DATA_SIZE="+strconv.FormatUint(media.DATA.SizeBytes, 10),
		"USOS_EXPOSE_DATA_PARTUUID="+media.DATA.PartUUID,
		"USOS_EXPOSE_WORK_OFFSET="+strconv.FormatUint(media.WORK.StartBytes, 10),
		"USOS_EXPOSE_WORK_SIZE="+strconv.FormatUint(media.WORK.SizeBytes, 10),
		"USOS_EXPOSE_WORK_PARTUUID="+media.WORK.PartUUID,
	)
	return cmd, nil
}
