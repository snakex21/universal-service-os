//go:build windows

package winhost

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/install"
)

const formatPartitionScript = `$ErrorActionPreference = 'Stop'
$diskNumber = [uint32]$env:USOS_FORMAT_DISK
$offset = [uint64]$env:USOS_FORMAT_OFFSET
$size = [uint64]$env:USOS_FORMAT_SIZE
$partGuid = $env:USOS_FORMAT_PARTUUID.Trim('{}')
$gptType = $env:USOS_FORMAT_GPTTYPE.Trim('{}')
$fileSystem = $env:USOS_FORMAT_FS
$label = $env:USOS_FORMAT_LABEL
$hideDriveLetter = ($env:USOS_FORMAT_HIDE_DRIVE_LETTER -eq '1')
$matches = @(Get-Partition -DiskNumber $diskNumber | Where-Object {
    ([uint64]$_.Offset -eq $offset) -and
    ([uint64]$_.Size -eq $size) -and
    ($_.Guid.ToString().Trim('{}') -ieq $partGuid) -and
    ($_.GptType.ToString().Trim('{}') -ieq $gptType)
})
if ($matches.Count -ne 1) {
    throw "Expected exactly one partition matching disk=$diskNumber offset=$offset size=$size PARTUUID=$partGuid GPT=$gptType; got $($matches.Count)"
}
$result = Format-Volume -Partition $matches[0] -FileSystem $fileSystem -NewFileSystemLabel $label -Force -Confirm:$false
if ($null -eq $result) { throw 'Format-Volume returned no volume object' }
if ($result.FileSystem -ine $fileSystem) { throw "Filesystem verification failed: got $($result.FileSystem) want $fileSystem" }
if ($result.FileSystemLabel -cne $label) { throw "Label verification failed: got $($result.FileSystemLabel) want $label" }
if ($hideDriveLetter) {
    $current = @(Get-Partition -DiskNumber $diskNumber | Where-Object {
        ([uint64]$_.Offset -eq $offset) -and
        ([uint64]$_.Size -eq $size) -and
        ($_.Guid.ToString().Trim('{}') -ieq $partGuid) -and
        ($_.GptType.ToString().Trim('{}') -ieq $gptType)
    })
    if ($current.Count -ne 1) { throw "Partition disappeared after format; got $($current.Count) matches" }
    $accessPaths = @($current[0].AccessPaths | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        ($_ -match '^[A-Za-z]:\\')
    })
    $volume = Get-Volume -Partition $current[0]
    $candidateLetters = @($current[0].DriveLetter, $volume.DriveLetter, $result.DriveLetter) | Where-Object {
        $null -ne $_ -and $_.ToString().Length -eq 1
    } | Select-Object -Unique
    foreach ($letter in $candidateLetters) {
        $letterMatches = @(Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue | Where-Object {
            ([uint32]$_.DiskNumber -eq $diskNumber) -and
            ([uint64]$_.Offset -eq $offset) -and
            ([uint64]$_.Size -eq $size) -and
            ($_.Guid.ToString().Trim('{}') -ieq $partGuid) -and
            ($_.GptType.ToString().Trim('{}') -ieq $gptType)
        })
        if ($letterMatches.Count -eq 1) {
            $accessPaths += $letter.ToString() + ':\'
        }
    }
    foreach ($accessPath in @($accessPaths | Select-Object -Unique)) {
        Remove-PartitionAccessPath -InputObject $current[0] -AccessPath $accessPath -Confirm:$false | Out-Null
    }
    $afterHide = @(Get-Partition -DiskNumber $diskNumber | Where-Object {
        ([uint64]$_.Offset -eq $offset) -and
        ([uint64]$_.Size -eq $size) -and
        ($_.Guid.ToString().Trim('{}') -ieq $partGuid) -and
        ($_.GptType.ToString().Trim('{}') -ieq $gptType)
    })
    if ($afterHide.Count -ne 1) { throw "Partition re-read after hiding drive letter returned $($afterHide.Count) matches" }
    $remainingAccessPaths = @($afterHide[0].AccessPaths | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        ($_ -match '^[A-Za-z]:\\')
    })
    $afterVolume = Get-Volume -Partition $afterHide[0]
    if (($null -ne $afterVolume.DriveLetter -and $afterVolume.DriveLetter.ToString().Length -eq 1) -or $remainingAccessPaths.Count -ne 0) {
        throw "WORK still has user mount paths after Remove-PartitionAccessPath: drive=$($afterVolume.DriveLetter) paths=$($remainingAccessPaths -join ',')"
    }
}
Write-Output ("PASS filesystem={0} label={1} hidden={2}" -f $result.FileSystem,$result.FileSystemLabel,$hideDriveLetter)
`

func (Backend) FormatESP(media install.MediaLayout) error {
	return formatPartition(media.DiskNumber, media.ESP, guidString(efiSystemPartitionType), "FAT32", "USOS_ESP", false)
}

func (Backend) FormatDATA(media install.MediaLayout) error {
	return formatPartition(media.DiskNumber, media.DATA, guidString(basicDataPartitionType), "NTFS", "USOS_DATA", false)
}

func (Backend) FormatWORK(media install.MediaLayout) error {
	return formatPartition(media.DiskNumber, media.WORK, guidString(basicDataPartitionType), "NTFS", "USOS_WORK", true)
}

func formatPartition(diskNumber uint32, partition install.PartitionRef, gptType, fileSystem, label string, hideDriveLetter bool) error {
	if strings.TrimSpace(partition.PartUUID) == "" {
		return fmt.Errorf("refusing to format partition with empty PARTUUID")
	}
	powershell, err := exec.LookPath("powershell.exe")
	if err != nil {
		return fmt.Errorf("Windows PowerShell is required for Format-Volume: %w", err)
	}
	cmd := exec.Command(powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", formatPartitionScript)
	hideValue := "0"
	if hideDriveLetter {
		hideValue = "1"
	}
	cmd.Env = append(os.Environ(),
		"USOS_FORMAT_DISK="+strconv.FormatUint(uint64(diskNumber), 10),
		"USOS_FORMAT_OFFSET="+strconv.FormatUint(partition.StartBytes, 10),
		"USOS_FORMAT_SIZE="+strconv.FormatUint(partition.SizeBytes, 10),
		"USOS_FORMAT_PARTUUID="+partition.PartUUID,
		"USOS_FORMAT_GPTTYPE="+gptType,
		"USOS_FORMAT_FS="+fileSystem,
		"USOS_FORMAT_LABEL="+label,
		"USOS_FORMAT_HIDE_DRIVE_LETTER="+hideValue,
	)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("Format-Volume %s PARTUUID=%s: %w: %s", fileSystem, partition.PartUUID, err, strings.TrimSpace(string(output)))
	}
	if !strings.Contains(string(output), "PASS filesystem=") {
		return fmt.Errorf("Format-Volume %s PARTUUID=%s returned unexpected output: %s", fileSystem, partition.PartUUID, strings.TrimSpace(string(output)))
	}
	return nil
}
