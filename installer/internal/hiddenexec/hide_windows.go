//go:build windows

package hiddenexec

import (
	"os/exec"
	"syscall"
)

// createNoWindow is CREATE_NO_WINDOW: a console child runs without a console
// window instead of opening one.
const createNoWindow = 0x08000000

// Hide makes cmd start without a visible window. It keeps any other
// SysProcAttr settings the caller made.
func Hide(cmd *exec.Cmd) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.HideWindow = true
	cmd.SysProcAttr.CreationFlags |= createNoWindow
}
