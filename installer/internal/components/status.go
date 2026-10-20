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
	x86DonorToken      = regexp.MustCompile(`(?i)(^|[^a-z0-9])x86([^a-z0-9]|$)`)
	// XPStoreDir keeps the verified XP package zips on DATA when both
	// languages were chosen, so the other one can be installed later offline.
	XPStoreDir    = filepath.Join("Programs", "USOS", "XP")
	xpESPDir      = filepath.Join("EFI", "USOS-XP")
	baseInitramfs = filepath.Join("EFI", "USOS", "micro-linux", "initramfs-usos")
)

// IsX86DonorName tells the two PE10 donors in DATA\Programs\USOS\WinPE
// apart: an ISO whose name has the token "x86" (PE10_x86_19041_USOS.iso, a
// user's ..._x86_....iso) is the x86 donor, every other ISO the x64 one (the
// rule before the x86 donor was shipped, so existing sticks keep working).
// The UEFI menu still decides by the boot.wim metadata (src/windows7_iso.zig).
func IsX86DonorName(name string) bool { return x86DonorToken.MatchString(name) }

// Status is what the stick already has.
type Status struct {
	// WinPE: a donor ISO is in DATA\Programs\USOS\WinPE (or in the legacy
	// folder, from where install/update/repair move it).
	WinPE     bool
	WinPEName string
	// WinPEX86: the x86 donor (IsX86DonorName) is there.
	WinPEX86     bool
	WinPEX86Name string
	// XPLang is the language of the XP package on the ESP ("" = none);
	// XPCurrent is false when it was built for another USOS build (after an
	// update it has to be replaced).
	XPLang    string
	XPCurrent bool
	// LegacyMS: the legacy pack's Microsoft redistributables are on DATA
	// (Addons\USOS\MS\legacy-ms.json readable).
	LegacyMS bool
}

// Present reports whether id is installed and current.
func (s Status) Present(id ID) bool {
	switch id {
	case WinPE:
		return s.WinPE
	case WinPEX86:
		return s.WinPEX86
	case XPPL, XPEN:
		return s.XPCurrent && s.XPLang == id.XPLang()
	case LegacyMS:
		return s.LegacyMS
	}
	return false
}

// XPOK reports whether a current XP package (any language) is installed.
func (s Status) XPOK() bool { return s.XPLang != "" && s.XPCurrent }

// Complete: nothing to offer.
func (s Status) Complete() bool { return s.WinPE && s.WinPEX86 && s.XPOK() && s.LegacyMS }

// Inspect reads the component state of a stick (read-only).
func Inspect(espRoot, dataRoot string) Status {
	var s Status
	found := func(name string) {
		if IsX86DonorName(name) {
			if !s.WinPEX86 {
				s.WinPEX86, s.WinPEX86Name = true, name
			}
		} else if !s.WinPE {
			s.WinPE, s.WinPEName = true, name
		}
	}
	if entries, err := os.ReadDir(filepath.Join(dataRoot, winpeDataDir)); err == nil {
		for _, entry := range entries {
			if !entry.IsDir() && strings.EqualFold(filepath.Ext(entry.Name()), ".iso") {
				found(entry.Name())
			}
		}
	}
	// The legacy folder (install/update/repair move a donor from there) counts
	// per architecture only when the managed folder has none of it.
	have64, have86 := s.WinPE, s.WinPEX86
	if entries, err := os.ReadDir(filepath.Join(dataRoot, legacyWinpeDataDir)); err == nil {
		for _, entry := range entries {
			if entry.IsDir() || !legacyWinpeName.MatchString(entry.Name()) {
				continue
			}
			if x86 := IsX86DonorName(entry.Name()); (x86 && !have86) || (!x86 && !have64) {
				found(entry.Name())
			}
		}
	}
	if _, err := ReadLegacyMSIndex(filepath.Join(dataRoot, LegacyMSDataDir, "legacy-ms.json")); err == nil {
		s.LegacyMS = true
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
