//go:build windows

package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
	"time"
)

func main() {
	_ = flag.String("serial", "", "ignored compatibility flag")
	_ = flag.Uint64("size", 0, "ignored compatibility flag")
	out := flag.String("out", "", "result file path")
	_ = flag.String("installer", "", "ignored compatibility flag")
	flag.Parse()
	if strings.TrimSpace(*out) == "" {
		fmt.Fprintln(os.Stderr, "missing -out")
		os.Exit(2)
	}
	text := fmt.Sprintf("BOOT_PROBE=PASS\r\nUTC=%s\r\n", time.Now().UTC().Format(time.RFC3339Nano))
	if err := os.WriteFile(*out, []byte(text), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
