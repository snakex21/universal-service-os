//go:build !windows

package hiddenexec

import "os/exec"

// Hide does nothing outside Windows: there are no console windows to hide.
func Hide(cmd *exec.Cmd) {}
