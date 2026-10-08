//go:build windows

package hiddenexec

import (
	"errors"
	"os/exec"
	"strings"
	"syscall"
	"testing"
)

func TestCommandHidesTheWindow(t *testing.T) {
	cmd := Command("cmd.exe", "/c", "echo", "x")
	if cmd.SysProcAttr == nil || !cmd.SysProcAttr.HideWindow || cmd.SysProcAttr.CreationFlags&createNoWindow == 0 {
		t.Fatalf("command is not hidden: %+v", cmd.SysProcAttr)
	}
}

func TestHideKeepsOtherFlags(t *testing.T) {
	const createNewProcessGroup = 0x00000200
	cmd := exec.Command("cmd.exe")
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNewProcessGroup}
	Hide(cmd)
	if cmd.SysProcAttr.CreationFlags != createNewProcessGroup|createNoWindow || !cmd.SysProcAttr.HideWindow {
		t.Fatalf("flags = 0x%X", cmd.SysProcAttr.CreationFlags)
	}
}

func TestCombinedOutputLogsAndHides(t *testing.T) {
	var lines []string
	SetLog(func(line string) { lines = append(lines, line) })
	defer SetLog(nil)
	cmd := exec.Command("cmd.exe", "/c", "echo hello-usos")
	output, err := CombinedOutput("echo test", cmd)
	if err != nil {
		t.Fatal(err)
	}
	if !cmd.SysProcAttr.HideWindow || cmd.SysProcAttr.CreationFlags&createNoWindow == 0 {
		t.Fatal("CombinedOutput ran the command visible")
	}
	if !strings.Contains(string(output), "hello-usos") {
		t.Fatalf("output = %q", output)
	}
	if len(lines) != 1 || !strings.Contains(lines[0], "[EXEC] echo test exit=0") || !strings.Contains(lines[0], "hello-usos") {
		t.Fatalf("log = %q", lines)
	}
}

func TestSummaryCapsOutputAndReportsErrors(t *testing.T) {
	long := strings.Repeat("a", maxLoggedOutput+10)
	got := Summary("x", errors.New("exit status 1"), []byte(long))
	if !strings.Contains(got, "error=exit status 1") || !strings.Contains(got, "[10 bytes cut]") {
		t.Fatalf("summary = %.80q...", got)
	}
	if Summary("y", nil, nil) != "[EXEC] y exit=0" {
		t.Fatal("empty output summary changed")
	}
}
