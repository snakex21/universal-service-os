// usos-installer-rsrc generates cmd/usos-installer/rsrc_windows_amd64.syso:
// a COFF object with a .rsrc section holding the application icon (drawn by
// internal/ui/logo, so no image asset is stored), the version information and
// the application manifest (per-monitor DPI v2, common controls 6, asInvoker).
// The Go linker merges it into the EXE. The output is deterministic; a test
// checks that the committed .syso is current.
//
//	go run ./cmd/usos-installer-rsrc -out cmd/usos-installer/rsrc_windows_amd64.syso [-ico usos.ico]
package main

import (
	"flag"
	"fmt"
	"os"
)

func main() {
	out := flag.String("out", "rsrc_windows_amd64.syso", "output .syso path")
	ico := flag.String("ico", "", "optionally also write the icon as an .ico file")
	flag.Parse()
	if err := os.WriteFile(*out, buildSyso(), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if *ico != "" {
		if err := os.WriteFile(*ico, buildICO(), 0o644); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
}
