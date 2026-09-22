package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestVerifyFreshSourcesRejectsNewerInput(t *testing.T) {
	root := t.TempDir()
	payloadPath := filepath.Join(root, "payload.zip")
	sourcePath := filepath.Join(root, "BOOTX64.EFI")
	if err := os.WriteFile(payloadPath, []byte("payload"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sourcePath, []byte("source"), 0o644); err != nil {
		t.Fatal(err)
	}
	base := time.Now().Add(-time.Hour)
	if err := os.Chtimes(payloadPath, base, base); err != nil {
		t.Fatal(err)
	}
	newer := base.Add(time.Minute)
	if err := os.Chtimes(sourcePath, newer, newer); err != nil {
		t.Fatal(err)
	}
	if err := verifyFreshSources(payloadPath, []string{sourcePath}); err == nil || !strings.Contains(err.Error(), "STALE payload.zip") {
		t.Fatalf("expected stale payload failure, got %v", err)
	}
}

func TestVerifyFreshSourcesAcceptsArchiveNewerThanInputs(t *testing.T) {
	root := t.TempDir()
	payloadPath := filepath.Join(root, "payload.zip")
	sourcePath := filepath.Join(root, "BOOTX64.EFI")
	if err := os.WriteFile(payloadPath, []byte("payload"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sourcePath, []byte("source"), 0o644); err != nil {
		t.Fatal(err)
	}
	base := time.Now().Add(-time.Hour)
	if err := os.Chtimes(sourcePath, base, base); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(payloadPath, base.Add(time.Minute), base.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if err := verifyFreshSources(payloadPath, []string{sourcePath}); err != nil {
		t.Fatal(err)
	}
}
