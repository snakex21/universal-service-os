package components

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Paths on the stick (relative to the ESP or DATA root).
var (
	winpeDataDir       = filepath.Join("Programs", "USOS", "WinPE")
	legacyWinpeDataDir = filepath.Join("Systems", "Windows", "Windows 10", "Images")
	legacyWinpeName    = regexp.MustCompile(`(?i)^PE10_.*_USOS\.iso$`)
	// XPStoreDir keeps the verified XP package zips on DATA when both
	// languages were chosen, so the other one can be installed later offline.
	XPStoreDir    = filepath.Join("Programs", "USOS", "XP")
	xpESPDir      = filepath.Join("EFI", "USOS-XP")
	baseInitramfs = filepath.Join("EFI", "USOS", "micro-linux", "initramfs-usos")
)

// Status is what the stick already has.
type Status struct {
	// WinPE: a donor ISO is in DATA\Programs\USOS\WinPE (or in the legacy
	// folder, from where install/update/repair move it).
	WinPE     bool
	WinPEName string
	// XPLang is the language of the XP package on the ESP ("" = none);
	// XPCurrent is false when it was built for another USOS build (after an
	// update it has to be replaced).
	XPLang    string
	XPCurrent bool
}

// Present reports whether id is installed and current.
func (s Status) Present(id ID) bool {
	switch id {
	case WinPE:
		return s.WinPE
	case XPPL, XPEN:
		return s.XPCurrent && s.XPLang == id.XPLang()
	}
	return false
}

// XPOK reports whether a current XP package (any language) is installed.
func (s Status) XPOK() bool { return s.XPLang != "" && s.XPCurrent }

// Complete: nothing to offer.
func (s Status) Complete() bool { return s.WinPE && s.XPOK() }

// Inspect reads the component state of a stick (read-only).
func Inspect(espRoot, dataRoot string) Status {
	var s Status
	if entries, err := os.ReadDir(filepath.Join(dataRoot, winpeDataDir)); err == nil {
		for _, entry := range entries {
			if !entry.IsDir() && strings.EqualFold(filepath.Ext(entry.Name()), ".iso") {
				s.WinPE, s.WinPEName = true, entry.Name()
				break
			}
		}
	}
	if !s.WinPE {
		if entries, err := os.ReadDir(filepath.Join(dataRoot, legacyWinpeDataDir)); err == nil {
			for _, entry := range entries {
				if !entry.IsDir() && legacyWinpeName.MatchString(entry.Name()) {
					s.WinPE, s.WinPEName = true, entry.Name()
					break
				}
			}
		}
	}
	manifest, err := ReadXPManifest(filepath.Join(espRoot, xpESPDir, "manifest.json"))
	if err == nil {
		s.XPLang = strings.ToLower(manifest.ReleaseLang)
		if s.XPLang == "" {
			s.XPLang = "?" // a development package: present, language unknown
		}
		if base, err := HashFile(filepath.Join(espRoot, baseInitramfs)); err == nil && strings.EqualFold(base, manifest.BaseInitramfsSHA256) {
			s.XPCurrent = true
		}
	}
	return s
}

// PreferredXP is the XP package matching the installer language.
func PreferredXP(uiLanguage string) ID {
	if strings.EqualFold(uiLanguage, "pl") {
		return XPPL
	}
	return XPEN
}
