//go:build windows

package winhost

import (
	"strings"
	"testing"
)

func TestFormatPartitionScriptFormatsByPartitionNotDriveLetter(t *testing.T) {
	if !strings.Contains(formatPartitionScript, "Format-Volume -Partition $matches[0]") {
		t.Fatal("format script must call Format-Volume with the verified partition object")
	}
	if strings.Contains(formatPartitionScript, "Format-Volume -DriveLetter") {
		t.Fatal("format script must not select a volume by drive letter")
	}
}

func TestFormatPartitionScriptRemovesWorkDriveLetter(t *testing.T) {
	for _, required := range []string{
		"USOS_FORMAT_HIDE_DRIVE_LETTER",
		"$current[0].AccessPaths",
		"($_ -match '^[A-Za-z]:\\\\')",
		"Get-Volume -Partition $current[0]",
		"Get-Partition -DriveLetter $letter",
		"($_.Guid.ToString().Trim('{}') -ieq $partGuid)",
		"Remove-PartitionAccessPath -InputObject $current[0]",
		"WORK still has user mount paths",
	} {
		if !strings.Contains(formatPartitionScript, required) {
			t.Fatalf("format script missing %q", required)
		}
	}
	if strings.Contains(formatPartitionScript, "+ ':\\\\'") {
		t.Fatal("drive-letter access path must contain one trailing backslash")
	}
}
