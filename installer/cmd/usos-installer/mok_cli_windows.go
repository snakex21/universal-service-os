//go:build windows

package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"golang.org/x/sys/windows"

	"github.com/snakex21/universal-service-os/installer/internal/mokenroll"
	"github.com/snakex21/universal-service-os/installer/internal/payload"
)

// Command-line switches for testing the MOK enrollment on a target without
// the window:
//
//	"USOS Installer.exe" -prepare-mok-enrollment [-mok-password usos] [-mok-cert file.cer]
//	"USOS Installer.exe" -check-mok [-mok-cert file.cer]
//
// The installer is a GUI-subsystem program, so the output goes to the
// console it was started from (cmd/PowerShell) or, when there is none, to a
// message box. Exit code 0 = success, 1 = failure, 2 = bad arguments.
func runMokCLI(args []string) (handled bool, code int) {
	if !mokCLIRequested(args) {
		return false, 0
	}
	out := attachParentConsole()
	set := flag.NewFlagSet("usos-installer", flag.ContinueOnError)
	set.SetOutput(out)
	prepare := set.Bool("prepare-mok-enrollment", false, "write the MokNew/MokAuth enrollment request for the USOS key (like mokutil --import)")
	check := set.Bool("check-mok", false, "show Secure Boot state and whether the USOS key is enrolled or pending (read-only)")
	password := set.String("mok-password", mokenroll.DefaultPassword, "password to type in MokManager (1-16 printable ASCII characters)")
	certPath := set.String("mok-cert", "", "DER certificate to use instead of the one in the installer payload")
	if err := set.Parse(args); err != nil {
		return true, report(out, 2, err.Error())
	}
	der, err := mokCertificate(*certPath)
	if err != nil {
		return true, report(out, 1, "[ERROR] USOS key: "+err.Error())
	}
	fw := mokenroll.System()
	if *check && !*prepare {
		st, err := mokenroll.Check(fw, der)
		if err != nil {
			return true, report(out, 1, "[ERROR] "+err.Error())
		}
		return true, report(out, 0, "[MOK] "+st.String())
	}
	res, err := mokenroll.Prepare(fw, der, *password, nil)
	switch {
	case err != nil:
		return true, report(out, 1, "[ERROR] "+err.Error())
	case res.AlreadyEnrolled:
		return true, report(out, 0, "[MOK] The USOS key is already enrolled (MokListRT); nothing was written.")
	}
	lines := []string{
		fmt.Sprintf("[MOK] Wrote MokNew (%d bytes) and MokAuth (%d bytes) to %s, attributes 0x%x; read back OK.", len(res.MokNew), len(res.MokAuth), mokenroll.ShimLockGUID, mokenroll.MokAttributes),
		"[MOK] Start this computer from the USOS drive: MokManager opens by itself. Press a key within 10 s, choose Enroll MOK -> Continue -> Yes, type the password, then Reboot.",
	}
	if res.MergedPending {
		lines = append(lines, "[MOK] Another pending key request was kept in MokNew.")
	}
	return true, report(out, 0, strings.Join(lines, "\n"))
}

func mokCLIRequested(args []string) bool {
	for _, a := range args {
		name := strings.TrimLeft(strings.SplitN(a, "=", 2)[0], "-")
		if name == "prepare-mok-enrollment" || name == "check-mok" {
			return true
		}
	}
	return false
}

func mokCertificate(path string) ([]byte, error) {
	var der []byte
	var err error
	if path != "" {
		der, err = os.ReadFile(path)
	} else {
		var bundle payload.Bundle
		if bundle, err = payload.Embedded(); err == nil {
			der, err = bundle.ReadFile(mokenroll.PayloadCertPath)
		}
	}
	if err != nil {
		return nil, err
	}
	return der, mokenroll.CheckCertificate(der)
}

// consoleOrBox writes to the parent console when there is one and collects
// the text for a message box otherwise.
type consoleOrBox struct {
	console *os.File
	text    strings.Builder
}

func (c *consoleOrBox) Write(p []byte) (int, error) {
	if c.console != nil {
		return c.console.Write(p)
	}
	return c.text.Write(p)
}

func attachParentConsole() *consoleOrBox {
	// Redirected output ("> mok.txt", a pipe) arrives as inherited handles.
	if h, err := windows.GetStdHandle(windows.STD_OUTPUT_HANDLE); err == nil && h != 0 && h != windows.InvalidHandle {
		if kind, _ := windows.GetFileType(h); kind == windows.FILE_TYPE_DISK || kind == windows.FILE_TYPE_PIPE {
			return &consoleOrBox{console: os.Stdout}
		}
	}
	const attachParentProcess = ^uintptr(0) // ATTACH_PARENT_PROCESS (-1)
	proc := windows.NewLazySystemDLL("kernel32.dll").NewProc("AttachConsole")
	if r, _, _ := proc.Call(attachParentProcess); r == 0 {
		return &consoleOrBox{}
	}
	f, err := os.OpenFile("CONOUT$", os.O_WRONLY, 0)
	if err != nil {
		return &consoleOrBox{}
	}
	// The shell already printed its prompt; start on a fresh line.
	fmt.Fprintln(f)
	return &consoleOrBox{console: f}
}

func report(out *consoleOrBox, code int, message string) int {
	fmt.Fprintln(out, message)
	if out.console == nil {
		flags := uint32(windows.MB_OK | windows.MB_ICONINFORMATION)
		if code != 0 {
			flags = windows.MB_OK | windows.MB_ICONERROR
		}
		text, _ := windows.UTF16PtrFromString(strings.TrimSpace(out.text.String()))
		title, _ := windows.UTF16PtrFromString("USOS Installer - MOK")
		windows.MessageBox(0, text, title, flags)
	}
	return code
}
