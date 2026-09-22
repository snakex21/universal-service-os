// usos-i18n-gen derives the boot (Zig) and XP helper (C) string tables and
// the lang.bin test fixture from installer/internal/i18n/locales, reports the
// boot-font glyph gaps per language, and can export the per-language ESP files.
//
//	go run ./cmd/usos-i18n-gen -root ..            regenerate
//	go run ./cmd/usos-i18n-gen -root .. -check     fail if anything is stale
//	go run ./cmd/usos-i18n-gen -export pl -out DIR write the ESP files for pl
package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/i18n"
)

func main() {
	root := flag.String("root", "..", "repository root")
	check := flag.Bool("check", false, "verify generated files are current; write nothing")
	export := flag.String("export", "", "language whose ESP files are written to -out")
	out := flag.String("out", "", "output directory for -export (receives EFI/USOS/...)")
	flag.Parse()
	if err := run(*root, *check, *export, *out); err != nil {
		fmt.Fprintln(os.Stderr, "[ERROR]", err)
		os.Exit(1)
	}
}

func run(root string, check bool, export, out string) error {
	if err := i18n.LoadError(); err != nil {
		return err
	}
	if export != "" {
		if out == "" {
			return fmt.Errorf("-export requires -out")
		}
		if i18n.Normalize(export) != strings.ToLower(export) {
			return fmt.Errorf("no catalog for language %q", export)
		}
		files, err := i18n.DeviceFiles(export)
		if err != nil {
			return err
		}
		for _, file := range files {
			path := filepath.Join(out, filepath.FromSlash(file.Path))
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				return err
			}
			if err := os.WriteFile(path, file.Data, 0o644); err != nil {
				return err
			}
			fmt.Println("[EXPORT]", path)
		}
		return nil
	}
	zig, err := i18n.GenerateZigTable()
	if err != nil {
		return err
	}
	header, err := i18n.GenerateXPHeader()
	if err != nil {
		return err
	}
	fixture, err := i18n.BootBlob(i18n.ZigFixtureLang)
	if err != nil {
		return err
	}
	outputs := []struct {
		path string
		data []byte
	}{{i18n.ZigTablePath, zig}, {i18n.XPHeaderPath, header}, {i18n.ZigFixturePath, fixture}}
	stale := 0
	for _, output := range outputs {
		path := filepath.Join(root, filepath.FromSlash(output.path))
		current, readErr := os.ReadFile(path)
		if readErr == nil && bytes.Equal(current, output.data) {
			fmt.Println("[OK]", output.path)
			continue
		}
		if check {
			fmt.Println("[STALE]", output.path)
			stale++
			continue
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(path, output.data, 0o644); err != nil {
			return err
		}
		fmt.Println("[WROTE]", output.path)
	}
	reportGlyphGaps()
	if stale > 0 {
		return fmt.Errorf("%d generated file(s) are stale; run go run ./cmd/usos-i18n-gen -root ..", stale)
	}
	return nil
}

// The boot font is 5x7 printable ASCII (lowercase drawn as uppercase). A
// language is boot-renderable only when every boot.* string fits it.
func reportGlyphGaps() {
	for _, language := range i18n.Languages() {
		gaps, err := i18n.BootGlyphGaps(language.Code)
		if err != nil {
			fmt.Println("[GLYPHS]", language.Code, "error:", err)
			continue
		}
		if len(gaps) == 0 {
			fmt.Println("[GLYPHS]", language.Code, "boot-renderable")
			continue
		}
		missing := map[rune]bool{}
		for _, runes := range gaps {
			for _, r := range runes {
				missing[r] = true
			}
		}
		list := make([]string, 0, len(missing))
		for r := range missing {
			list = append(list, fmt.Sprintf("%c(U+%04X)", r, r))
		}
		sort.Strings(list)
		fmt.Printf("[GLYPHS] %s NOT boot-renderable: %d of its boot strings need %s; the EFI keeps English for them\n", language.Code, len(gaps), strings.Join(list, " "))
	}
}
