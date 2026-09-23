package main

import (
	"bytes"
	"os"
	"testing"
)

// The committed resource object must match the generator; run
// `go generate ./cmd/usos-installer` after changing the logo or manifest.
func TestCommittedSysoIsCurrent(t *testing.T) {
	committed, err := os.ReadFile("../usos-installer/rsrc_windows_amd64.syso")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(committed, buildSyso()) {
		t.Fatal("cmd/usos-installer/rsrc_windows_amd64.syso is stale; run go generate ./cmd/usos-installer")
	}
}

func TestICOHasEveryIconSize(t *testing.T) {
	ico := buildICO()
	if len(ico) < 6 || int(ico[4]) != len(iconSizes) {
		t.Fatalf("ico header count = %d, want %d", ico[4], len(iconSizes))
	}
}
