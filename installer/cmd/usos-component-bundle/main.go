// usos-component-bundle writes the all-in-one installer: the installer
// executable followed by the component zips as an overlay
// (internal/components/bundle.go). Used by tools/release/make_release.ps1.
//
//	usos-component-bundle -exe "USOS Installer.exe" -out all-in-one.exe a.zip b.zip ...
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/snakex21/universal-service-os/installer/internal/components"
)

func main() {
	exe := flag.String("exe", "", "installer executable (the online build)")
	out := flag.String("out", "", "all-in-one executable to write")
	flag.Parse()
	if *exe == "" || *out == "" || flag.NArg() == 0 {
		fmt.Fprintln(os.Stderr, "usage: usos-component-bundle -exe IN.exe -out OUT.exe ZIP...")
		os.Exit(2)
	}
	if err := components.WriteBundle(*out, *exe, flag.Args()); err != nil {
		fmt.Fprintln(os.Stderr, "bundle:", err)
		os.Exit(1)
	}
	bundle, err := components.OpenBundle(*out)
	if err != nil {
		fmt.Fprintln(os.Stderr, "bundle readback:", err)
		os.Exit(1)
	}
	for name, entry := range bundle.Entries {
		fmt.Printf("[BUNDLE] %s offset=%d size=%d\n", name, entry.Offset, entry.Size)
	}
	fmt.Println("[PASS] all-in-one installer", *out)
}
