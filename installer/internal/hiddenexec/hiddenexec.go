// Package hiddenexec starts the helper programs the installer needs
// (PowerShell, bcdedit, bcdboot, dism) without a console window and copies
// their output into the installer log.
//
// The installer is a GUI program, so every console child would otherwise
// get its own console window that flashes up over the installer.
package hiddenexec

import (
	"fmt"
	"os/exec"
	"strings"
	"sync/atomic"
)

// maxLoggedOutput caps the output copied into the log for one command.
const maxLoggedOutput = 8 * 1024

var logSink atomic.Pointer[func(string)]

// SetLog sets where command lines and their output go; nil turns it off.
func SetLog(fn func(string)) {
	if fn == nil {
		logSink.Store(nil)
		return
	}
	logSink.Store(&fn)
}

func logLine(line string) {
	if fn := logSink.Load(); fn != nil {
		(*fn)(line)
	}
}

// Command is exec.Command with the console window suppressed.
func Command(name string, args ...string) *exec.Cmd {
	cmd := exec.Command(name, args...)
	Hide(cmd)
	return cmd
}

// CombinedOutput runs cmd hidden (Hide is applied again, so a cmd built
// with exec.Command is also safe), logs a one-line summary plus the output
// under label, and returns what cmd.CombinedOutput returns.
func CombinedOutput(label string, cmd *exec.Cmd) ([]byte, error) {
	Hide(cmd)
	output, err := cmd.CombinedOutput()
	logLine(Summary(label, err, output))
	return output, err
}

// Summary is the log text for one finished command.
func Summary(label string, err error, output []byte) string {
	status := "exit=0"
	if err != nil {
		status = "error=" + err.Error()
	}
	text := strings.TrimSpace(strings.ReplaceAll(string(output), "\r", ""))
	if len(text) > maxLoggedOutput {
		text = text[:maxLoggedOutput] + fmt.Sprintf(" ... [%d bytes cut]", len(text)-maxLoggedOutput)
	}
	if text == "" {
		return fmt.Sprintf("[EXEC] %s %s", label, status)
	}
	return fmt.Sprintf("[EXEC] %s %s output:\n    %s", label, status, strings.ReplaceAll(text, "\n", "\n    "))
}
