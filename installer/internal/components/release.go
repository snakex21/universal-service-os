// Package components gets the optional USOS components that are separate
// release assets (the WinPE PE10 donors x64 and x86, the Windows XP UEFI packages and
// the Microsoft redistributables of the Windows 95/98/Me/NT4 legacy pack):
// download from the installer's own GitHub release or pick a local zip,
// verify against SHA256SUMS and the hash list compiled into the installer,
// and unpack. Installing onto the stick is winhost's job (the same WinPE
// donor code and install-xp-package.ps1 as before).
package components

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/buildinfo"
)

// ReleaseBaseURL is the one place the download location is configured:
// assets are fetched from ReleaseBaseURL/<tag>/<asset>.
const ReleaseBaseURL = "https://github.com/snakex21/universal-service-os/releases/download"

// SumsAsset is the checksum list published with every release.
const SumsAsset = "SHA256SUMS"

// ID names one optional component.
type ID string

const (
	WinPE ID = "winpe"
	// WinPEX86: the x86 PE10 donor of 32-bit Windows 7 / Vista / 2008 on
	// UEFI without CSM (win-nt6-x86-uefi-csmwrap; user decision 2026-10-20).
	WinPEX86 ID = "winpe-x86"
	XPPL     ID = "xp-pl"
	XPEN     ID = "xp-en"
	// LegacyMS: Microsoft redistributables of the legacy compatibility pack
	// (maintainer decision 2026-09-30), unpacked to DATA\Addons\USOS\MS.
	LegacyMS ID = "legacy-ms"
	// Win7NetIntel: Intel's e1r62x86/e1r62x64 Net driver for the Intel I211
	// under Windows 7 / Server 2008 R2, unpacked to
	// DATA\Systems\Windows\Windows 7\Drivers\<arch>\Net\Intel-I211
	// (maintainer decision 2026-10-22: its own release asset, never in the
	// repository; the user accepts Intel's licence when downloading).
	Win7NetIntel ID = "win7-net-intel"
)

// All lists the components in display order.
var All = []ID{WinPE, WinPEX86, XPPL, XPEN, LegacyMS, Win7NetIntel}

// IsWinPE reports whether id is one of the PE10 donors.
func (id ID) IsWinPE() bool { return id == WinPE || id == WinPEX86 }

// IsXP reports whether id is one of the XP packages.
func (id ID) IsXP() bool { return id == XPPL || id == XPEN }

// XPLang is "pl" or "en" for an XP package, "" otherwise.
func (id ID) XPLang() string {
	switch id {
	case XPPL:
		return "pl"
	case XPEN:
		return "en"
	}
	return ""
}

// AssetName is the release asset of id, as tools/release/assemble_release.py
// names it.
func AssetName(id ID, version string) string {
	switch id {
	case WinPE:
		return "USOS-" + version + "-WinPE-PE10-donor.zip"
	case WinPEX86:
		return "USOS-" + version + "-WinPE-PE10-x86-donor.zip"
	case XPPL:
		return "USOS-" + version + "-XP-package-PL.zip"
	case XPEN:
		return "USOS-" + version + "-XP-package-EN.zip"
	case LegacyMS:
		return "USOS-" + version + "-Legacy-pack-MS.zip"
	case Win7NetIntel:
		return "USOS-" + version + "-NetDrivers-Intel.zip"
	}
	return ""
}

// Release is where the components come from and what they must hash to.
type Release struct {
	BaseURL string
	Tag     string
	Version string
	// Pinned is the hash list compiled into the installer (asset -> sha256).
	// Empty in development builds.
	Pinned map[string]string
}

// CurrentRelease is the release of this installer build.
func CurrentRelease() Release {
	info := buildinfo.Current()
	tag := strings.TrimSpace(buildinfo.ReleaseTag)
	if tag == "" && info.Version != "" {
		tag = "v" + info.Version
	}
	return Release{BaseURL: ReleaseBaseURL, Tag: tag, Version: info.Version, Pinned: ParsePinned(buildinfo.ComponentSHA256)}
}

// Asset is the asset name of id in this release ("" without a version).
func (r Release) Asset(id ID) string {
	if r.Version == "" {
		return ""
	}
	return AssetName(id, r.Version)
}

// CanDownload reports whether the release location is known.
func (r Release) CanDownload() bool { return r.BaseURL != "" && r.Tag != "" && r.Version != "" }

// URL of an asset of this release.
func (r Release) URL(asset string) string {
	return strings.TrimSuffix(r.BaseURL, "/") + "/" + r.Tag + "/" + asset
}

// ParsePinned decodes "ASSET=sha256;ASSET=sha256" (the ldflags form).
func ParsePinned(text string) map[string]string {
	result := map[string]string{}
	for _, item := range strings.FieldsFunc(text, func(r rune) bool { return r == ';' || r == ',' || r == '\n' }) {
		name, sum, ok := strings.Cut(strings.TrimSpace(item), "=")
		sum = strings.ToLower(strings.TrimSpace(sum))
		if ok && strings.TrimSpace(name) != "" && isSHA256(sum) {
			result[strings.TrimSpace(name)] = sum
		}
	}
	return result
}

// ParseSums reads a SHA256SUMS file ("<sha256> *<name>" or "<sha256>  <name>").
func ParseSums(r io.Reader) (map[string]string, error) {
	result := map[string]string{}
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		sum, name, ok := strings.Cut(line, " ")
		sum = strings.ToLower(sum)
		name = strings.TrimPrefix(strings.TrimSpace(name), "*")
		if !ok || !isSHA256(sum) || name == "" {
			return nil, fmt.Errorf("SHA256SUMS: malformed line %q", line)
		}
		result[name] = sum
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(result) == 0 {
		return nil, errors.New("SHA256SUMS is empty")
	}
	return result, nil
}

func isSHA256(s string) bool {
	if len(s) != 64 {
		return false
	}
	_, err := hex.DecodeString(s)
	return err == nil
}

// ErrHashMismatch: the file differs from a published or compiled hash.
var ErrHashMismatch = errors.New("SHA-256 mismatch")

// ErrUnverifiable: no hash list names the asset.
var ErrUnverifiable = errors.New("no checksum available")

// Check accepts actual as the SHA-256 of asset only when every available list
// agrees: the compiled list (when the installer has one) must name the asset,
// and SHA256SUMS (when given) must name it with the same hash. A development
// build without a compiled list needs SHA256SUMS.
func Check(asset, actual string, pinned, sums map[string]string) error {
	actual = strings.ToLower(actual)
	checked := false
	if len(pinned) > 0 {
		want, ok := pinned[asset]
		if !ok {
			return fmt.Errorf("%s: not in the hash list compiled into this installer: %w", asset, ErrUnverifiable)
		}
		if want != actual {
			return fmt.Errorf("%s: SHA-256 %s, this installer expects %s: %w", asset, actual, want, ErrHashMismatch)
		}
		checked = true
	}
	if sums != nil {
		want, ok := sums[asset]
		if !ok {
			return fmt.Errorf("%s: not listed in SHA256SUMS: %w", asset, ErrUnverifiable)
		}
		if want != actual {
			return fmt.Errorf("%s: SHA-256 %s, SHA256SUMS says %s: %w", asset, actual, want, ErrHashMismatch)
		}
		checked = true
	}
	if !checked {
		return fmt.Errorf("%s: %w", asset, ErrUnverifiable)
	}
	return nil
}

// HashFile returns the lower-case SHA-256 of a file.
func HashFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
