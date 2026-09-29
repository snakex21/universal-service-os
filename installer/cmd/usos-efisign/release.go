package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/efisign"
)

// Release layout of the removable-media path on the USOS ESP:
//
//	EFI/BOOT/BOOTX64.EFI  shim (Microsoft UEFI CA signed, vendored)
//	EFI/BOOT/mmx64.efi    MokManager (signed by the shim vendor)
//	EFI/BOOT/grubx64.efi  USOS, MOK-signed, with a .sbat section
//	EFI/USOS/ENROLL_THIS_KEY_IN_MOKMANAGER.cer, ENROLL-README.txt, secure-boot.ini
//	USOS-KEY.cer          the same certificate at the ESP root, so MokManager's
//	                      "Enroll key from disk" needs one click: USOS_ESP -> USOS-KEY.cer
const (
	shimVendorDir     = "tools/vendor/shim/16.1-7"
	sbatPath          = "assets/secure-boot/usos.sbat.csv"
	readmePath        = "assets/secure-boot/ENROLL-README.txt"
	referenceCertPath = "assets/secure-boot/usos-secure-boot.cer"
	unsignedUsosPath  = "zig-out/manual-usb/EFI/BOOT/BOOTX64.EFI"
	usbRoot           = "zig-out/usb"
	enrollCertName    = "ENROLL_THIS_KEY_IN_MOKMANAGER.cer"
	rootCertName      = "USOS-KEY.cer"
	secureBootINIPath = "EFI/USOS/secure-boot.ini"

	// Handheld I2C touch driver (tools/vendor/touchi2cdxe): copied from the
	// vendored build after its manifest hash check, then signed like the
	// NTFS driver. USOS starts it only on matching SMBIOS (touch_driver.zig).
	touchVendorDir    = "tools/vendor/touchi2cdxe/v1.3.1-usos1"
	touchDriverTarget = "EFI/USOS/touchi2c_x64.efi"
	// CSMWrap 3.1.2-usos3 (a MODIFIED CSMWrap 3.1.2: quiet boot unless
	// csmwrap.ini sets verbose = true, and SeaBIOS boot priorities from
	// CSMWrap's BBS table, USB included; docs/research/csmwrap.md sections 6
	// and 7, docs/design/bios-via-csmwrap.md) for XP / Vista without firmware
	// CSM and for the UEFI menu's "Legacy BIOS mode (CSMWrap)": copied
	// hash-checked, never signed; the preparers put it on the target's own
	// ESP (tools/xp_csmwrap_esp.sh, the BIOS Core DOS installer). The LGPL
	// source (the unpatched archive plus the patches) and every licence
	// notice travel with it.
	csmwrapVendorDir  = "tools/vendor/csmwrap/3.1.2-usos3"
	csmwrapLicenseDir = "tools/vendor/csmwrap/3.1.2"
	csmwrapSourceDir  = "tools/vendor/csmwrap/3.1.2-src"
	csmwrapTargetDir  = "EFI/USOS/csmwrap"
	// SeaBIOS (inside CSMWrap) is LGPLv3, which incorporates the GPLv3 text.
	seabiosGPLv3Source = "tools/vendor/wimlib/1.14.5/COPYING.GPLv3.txt"
	seabiosGPLv3SHA256 = "230184f60bae2feaf244f10a8bac053c8ff33a183bcc365b4d8b876d2b7f4809"
	touchLicenseDir    = "EFI/USOS/licenses/touchi2cdxe"
	// EDK2 UEFI Shell (Utilities -> UEFI Shell, src/platform/uefi/uefi_shell.zig):
	// the official edk2-stable202002 binary, copied hash-checked and signed
	// like the NTFS driver, next to its start script, licence and
	// SOURCES.txt. No .sbat: its headers have no room for another section,
	// and shim requires SBAT only in the second stage it starts itself
	// (images USOS loads later are verified against db/MOK without it).
	uefiShellVendorDir   = "tools/vendor/uefi-shell/edk2-stable202002"
	uefiShellTargetDir   = "EFI/USOS/shell"
	uefiShellStartupPath = "assets/uefi-shell/startup.nsh"
)

// signedInPlace are the non-Microsoft EFI binaries USOS loads after itself.
// wimboot is left alone: the vendored 2.9.0 build is already signed by the
// Microsoft UEFI CA. UefiSeven (int10.efi), CSMWrap and the XP package are
// Secure Boot incompatible paths and stay unsigned on purpose.
var signedInPlace = []string{
	"zig-out/micro-linux/systemd-bootx64.efi",
	"zig-out/micro-linux/vmlinuz-virt",
	"zig-out/test-assets/ntfs_x64.efi",
}

var microsoftSigned = []string{"zig-out/windows-native/wimboot"}

type shimManifest struct {
	Version     string            `json:"version"`
	SecondStage string            `json:"second_stage"`
	MokManager  string            `json:"mok_manager"`
	Files       map[string]string `json:"files"`
}

func release(args []string) error {
	set := flag.NewFlagSet("release", flag.ExitOnError)
	rootFlag := set.String("root", "..", "repository root")
	dir := keyDirFlag(set)
	requireKey := set.Bool("require-key", false, "fail instead of emitting an unsigned layout when the key is missing")
	set.Parse(args)
	root := filepath.Clean(*rootFlag)
	at := func(relative string) string { return filepath.Join(root, filepath.FromSlash(relative)) }

	manifest, err := loadShimManifest(at(shimVendorDir))
	if err != nil {
		return err
	}
	sbat, err := os.ReadFile(at(sbatPath))
	if err != nil {
		return err
	}
	readme, err := os.ReadFile(at(readmePath))
	if err != nil {
		return err
	}
	keyDir, err := resolveKeyDir(*dir)
	if err != nil {
		return err
	}
	pair, keyErr := efisign.LoadKeyPair(keyDir)
	signed := keyErr == nil
	if !signed {
		if *requireKey || !errors.Is(keyErr, efisign.ErrNoKey) {
			return keyErr
		}
		fmt.Println("[WARN] ================================================================")
		fmt.Printf("[WARN] UNSIGNED BUILD: %v\n", keyErr)
		fmt.Println("[WARN] USOS (EFI/BOOT/grubx64.efi) and its helpers are NOT signed.")
		fmt.Println("[WARN] The stick boots only with Secure Boot disabled.")
		fmt.Println("[WARN] Create a key once: go run ./cmd/usos-efisign keygen")
		fmt.Println("[WARN] ================================================================")
	}

	if signed {
		// The tracked public certificate is the one users enroll; a different
		// local key still signs, but its sticks need their own enrollment.
		if reference, err := os.ReadFile(at(referenceCertPath)); err == nil && !bytes.Equal(reference, pair.Cert.Raw) {
			fmt.Printf("[WARN] Signing key in %s is not the USOS release key (%s); sticks from this build need their own MOK enrollment.\n", keyDir, referenceCertPath)
		}
	}

	for _, relative := range microsoftSigned {
		if err := requireMicrosoftSignature(at(relative)); err != nil {
			return err
		}
	}

	bootDir := at(usbRoot + "/EFI/BOOT")
	usosDir := at(usbRoot + "/EFI/USOS")
	for _, directory := range []string{bootDir, usosDir, filepath.Join(usosDir, "licenses", "shim")} {
		if err := os.MkdirAll(directory, 0o755); err != nil {
			return err
		}
	}
	shimDir := at(shimVendorDir)
	if err := copyVerified(filepath.Join(shimDir, "shimx64.efi"), filepath.Join(bootDir, "BOOTX64.EFI"), manifest.Files["shimx64.efi"]); err != nil {
		return err
	}
	if err := copyVerified(filepath.Join(shimDir, "mmx64.efi"), filepath.Join(bootDir, manifest.MokManager), manifest.Files["mmx64.efi"]); err != nil {
		return err
	}
	for _, name := range []string{"LICENSE", "README.md"} {
		data, err := os.ReadFile(filepath.Join(shimDir, name))
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(usosDir, "licenses", "shim", name), data, 0o644); err != nil {
			return err
		}
	}

	touchDriver, err := stageTouchDriver(at(touchVendorDir), at(usbRoot))
	if err != nil {
		return err
	}
	if err := stageCSMWrap(at(csmwrapVendorDir), at(csmwrapLicenseDir), at(csmwrapSourceDir), at(seabiosGPLv3Source), at(usbRoot)); err != nil {
		return err
	}
	uefiShell, err := stageUefiShell(at(uefiShellVendorDir), at(uefiShellStartupPath), at(usbRoot))
	if err != nil {
		return err
	}

	secondStage := filepath.Join(bootDir, manifest.SecondStage)
	options := efisign.SignOptions{SBAT: sbat}
	if signed {
		if err := signFile(at(unsignedUsosPath), secondStage, pair, options); err != nil {
			return err
		}
		for _, relative := range signedInPlace {
			if err := signFile(at(relative), at(relative), pair, efisign.SignOptions{ReplaceSignature: true}); err != nil {
				return err
			}
			fmt.Printf("[SIGN] %s\n", relative)
		}
		if err := signFile(touchDriver, touchDriver, pair, efisign.SignOptions{ReplaceSignature: true}); err != nil {
			return err
		}
		fmt.Printf("[SIGN] %s/%s\n", usbRoot, touchDriverTarget)
		if err := signFile(uefiShell, uefiShell, pair, efisign.SignOptions{ReplaceSignature: true}); err != nil {
			return err
		}
		fmt.Printf("[SIGN] %s/%s/Shell.efi\n", usbRoot, uefiShellTargetDir)
		for _, target := range []string{filepath.Join(usosDir, enrollCertName), at(usbRoot + "/" + rootCertName)} {
			if err := os.WriteFile(target, pair.Cert.Raw, 0o644); err != nil {
				return err
			}
		}
	} else {
		unsigned, err := os.ReadFile(at(unsignedUsosPath))
		if err != nil {
			return err
		}
		prepared, err := efisign.Prepare(unsigned, options)
		if err != nil {
			return err
		}
		if err := writeFileAtomic(secondStage, prepared); err != nil {
			return err
		}
		_ = os.Remove(filepath.Join(usosDir, enrollCertName))
		_ = os.Remove(at(usbRoot + "/" + rootCertName))
	}
	fmt.Printf("[SIGN] %s <- %s (%s)\n", filepath.ToSlash(filepath.Join(usbRoot, "EFI/BOOT", manifest.SecondStage)), unsignedUsosPath, map[bool]string{true: "signed", false: "UNSIGNED"}[signed])

	if err := os.WriteFile(filepath.Join(usosDir, "ENROLL-README.txt"), readme, 0o644); err != nil {
		return err
	}
	ini := secureBootINI(signed, pair, manifest)
	if err := os.WriteFile(at(usbRoot+"/"+secureBootINIPath), []byte(ini), 0o644); err != nil {
		return err
	}
	if signed {
		fmt.Printf("[PASS] Secure Boot chain: shim %s -> %s signed by %s (cert sha256 %s)\n", manifest.Version, manifest.SecondStage, pair.Cert.Subject.CommonName, pair.Fingerprint())
	}
	return nil
}

func secureBootINI(signed bool, pair efisign.KeyPair, manifest shimManifest) string {
	var b strings.Builder
	b.WriteString("[secure_boot]\r\n")
	fmt.Fprintf(&b, "shim=%s\r\n", manifest.Version)
	fmt.Fprintf(&b, "second_stage=EFI/BOOT/%s\r\n", manifest.SecondStage)
	if signed {
		b.WriteString("signed=1\r\n")
		fmt.Fprintf(&b, "certificate=EFI/USOS/%s\r\n", enrollCertName)
		// Informational: the same certificate at the ESP root, the file
		// MokManager's "Enroll key from disk" picks with one click.
		fmt.Fprintf(&b, "certificate_root=%s\r\n", rootCertName)
		fmt.Fprintf(&b, "certificate_sha256=%s\r\n", pair.Fingerprint())
		fmt.Fprintf(&b, "certificate_subject=%s\r\n", pair.Cert.Subject.CommonName)
	} else {
		b.WriteString("signed=0\r\n")
		b.WriteString("note=UNSIGNED BUILD - boots only with Secure Boot disabled\r\n")
	}
	return b.String()
}

func loadShimManifest(dir string) (shimManifest, error) {
	var manifest shimManifest
	data, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		return manifest, fmt.Errorf("vendored shim manifest: %w", err)
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		return manifest, fmt.Errorf("vendored shim manifest: %w", err)
	}
	if manifest.SecondStage == "" || manifest.MokManager == "" || manifest.Files["shimx64.efi"] == "" || manifest.Files["mmx64.efi"] == "" {
		return manifest, errors.New("vendored shim manifest lacks second_stage, mok_manager or file hashes")
	}
	if err := requireMicrosoftSignature(filepath.Join(dir, "shimx64.efi")); err != nil {
		return manifest, err
	}
	return manifest, nil
}

// requireMicrosoftSignature checks that the file carries an intact
// Authenticode signature whose signer chain names Microsoft. Firmware db
// verification happens on the target; this only catches a wrong or damaged
// vendored file at build time.
func requireMicrosoftSignature(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	img, err := efisign.Parse(data)
	if err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	digest, err := img.AuthenticodeHash()
	if err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	blobs, err := img.Signatures()
	if err != nil || len(blobs) == 0 {
		return fmt.Errorf("%s: expected a Microsoft signature, found none", path)
	}
	for _, blob := range blobs {
		sig, err := efisign.ParseSignature(blob)
		if err != nil || !bytes.Equal(sig.ImageDigest, digest) {
			continue
		}
		for _, cert := range sig.Certificates {
			if strings.Contains(cert.Issuer.String(), "Microsoft") && strings.Contains(cert.Issuer.String(), "UEFI CA") {
				return nil
			}
		}
	}
	return fmt.Errorf("%s: no intact signature chaining to a Microsoft UEFI CA", path)
}

func copyVerified(source, target, expected string) error {
	data, err := os.ReadFile(source)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(data)
	if actual := hex.EncodeToString(sum[:]); !strings.EqualFold(actual, expected) {
		return fmt.Errorf("%s SHA-256 %s, manifest pins %s", source, actual, expected)
	}
	return writeFileAtomic(target, data)
}

// csmwrapBuild is the manifest of the USOS CSMWrap build (3.1.2-usos1).
type csmwrapBuild struct {
	Version       string            `json:"version"`
	Files         map[string]string `json:"files"`
	Patches       map[string]string `json:"patches"`
	SourceArchive struct {
		File   string `json:"file"`
		SHA256 string `json:"sha256"`
	} `json:"source_archive"`
}

// csmwrapSource is the manifest of the vendored complete source (the
// unpatched archive and the licence texts of every component).
type csmwrapSource struct {
	Archive struct {
		File   string `json:"file"`
		SHA256 string `json:"sha256"`
	} `json:"archive"`
	Licenses map[string]string `json:"licenses"`
}

func readJSON(path string, into any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, into)
}

// stageCSMWrap copies the USOS CSMWrap build (manifest hash), its LGPL-2.1
// licence, the SeaBIOS LGPLv3 and GPLv3 texts, the complete corresponding
// source (the unpatched archive and the USOS patches), the licence notices
// of the other components and a SOURCES.txt that marks the binary as
// MODIFIED into EFI/USOS/csmwrap.
func stageCSMWrap(vendorDir, licenseDir, sourceDir, gplv3, usb string) error {
	var build csmwrapBuild
	if err := readJSON(filepath.Join(vendorDir, "manifest.json"), &build); err != nil {
		return fmt.Errorf("vendored CSMWrap build manifest: %w", err)
	}
	var upstream touchManifest
	if err := readJSON(filepath.Join(licenseDir, "manifest.json"), &upstream); err != nil {
		return fmt.Errorf("vendored CSMWrap manifest: %w", err)
	}
	var source csmwrapSource
	if err := readJSON(filepath.Join(sourceDir, "manifest.json"), &source); err != nil {
		return fmt.Errorf("vendored CSMWrap source manifest: %w", err)
	}
	if build.Files["csmwrapx64.efi"] == "" || upstream.Files["LICENSE"] == "" || upstream.Files["COPYING.LESSER"] == "" {
		return errors.New("vendored CSMWrap manifests lack the csmwrapx64.efi, LICENSE or COPYING.LESSER hash")
	}
	if len(build.Patches) == 0 || build.SourceArchive.SHA256 == "" || !strings.EqualFold(build.SourceArchive.SHA256, source.Archive.SHA256) || len(source.Licenses) == 0 {
		return errors.New("vendored CSMWrap build: patches, source archive or licence notices missing, or the archive hashes disagree")
	}
	dir := filepath.Join(usb, filepath.FromSlash(csmwrapTargetDir))
	for _, sub := range []string{"", "patches", "licenses"} {
		if err := os.MkdirAll(filepath.Join(dir, sub), 0o755); err != nil {
			return err
		}
	}
	copies := [][3]string{
		{filepath.Join(vendorDir, "csmwrapx64.efi"), "csmwrapx64.efi", build.Files["csmwrapx64.efi"]},
		{filepath.Join(licenseDir, "LICENSE"), "LICENSE-CSMWrap-LGPL-2.1.txt", upstream.Files["LICENSE"]},
		{filepath.Join(licenseDir, "COPYING.LESSER"), "COPYING-SeaBIOS-LGPLv3.txt", upstream.Files["COPYING.LESSER"]},
		{gplv3, "COPYING-SeaBIOS-GPLv3.txt", seabiosGPLv3SHA256},
		{filepath.Join(sourceDir, source.Archive.File), source.Archive.File, source.Archive.SHA256},
	}
	patches := make([]string, 0, len(build.Patches))
	for name := range build.Patches {
		patches = append(patches, name)
	}
	sort.Strings(patches)
	for _, name := range patches {
		copies = append(copies, [3]string{filepath.Join(vendorDir, "patches", name), "patches/" + name, build.Patches[name]})
	}
	notices := make([]string, 0, len(source.Licenses))
	for name := range source.Licenses {
		notices = append(notices, name)
	}
	sort.Strings(notices)
	for _, name := range notices {
		copies = append(copies, [3]string{filepath.Join(sourceDir, filepath.FromSlash(name)), "licenses/" + filepath.Base(filepath.FromSlash(name)), source.Licenses[name]})
	}
	for _, c := range copies {
		if err := copyVerified(c[0], filepath.Join(dir, filepath.FromSlash(c[1])), c[2]); err != nil {
			return err
		}
	}
	patchList := ""
	for _, name := range patches {
		patchList += "  patches/" + name + "\r\n"
	}
	sources := "CSMWrap " + build.Version + " (csmwrapx64.efi, unsigned)\r\n" +
		"MODIFIED: this is a modified version of CSMWrap 3.1.2 and of its SeaBIOS fork,\r\n" +
		"changed by the Universal Service OS project on 2026-09-27 (patches 0001-0003):\r\n" +
		"quiet boot unless csmwrap.ini sets verbose = true (no CSMWrap logo, no SeaBIOS\r\n" +
		"banner or UUID line, no 'Booting from ...' lines, no boot-menu prompt or wait),\r\n" +
		"and on 2026-09-29 (patch 0004): SeaBIOS takes the boot priorities from\r\n" +
		"CSMWrap's BBS table by PCI address, USB mass storage included, so the drive\r\n" +
		"CSMWrap was loaded from boots first. Version strings: CSMWrap Version\r\n" +
		"3.1.2-usos3, SeaBIOS 578d260b-CSMWrap-3.1.2-usos3.\r\n" +
		"\r\n" +
		"Complete corresponding source, next to this file:\r\n" +
		"  " + source.Archive.File + " (unpatched CSMWrap 3.1.2, commit 808ac8e, with all\r\n" +
		"  submodules; SeaBIOS fork commit 578d260b; SHA-256 " + source.Archive.SHA256 + ")\r\n" +
		"plus the USOS patches, applied in order with patch -p1:\r\n" + patchList +
		"Build scripts: tools/build_csmwrap.ps1 and tools/csmwrap_build/ in the USOS\r\n" +
		"sources. The USOS project provides the same source on request for as long as\r\n" +
		"it distributes this binary.\r\n" +
		"\r\n" +
		"Licences: CSMWrap LGPL-2.1 (LICENSE-CSMWrap-LGPL-2.1.txt); SeaBIOS LGPLv3\r\n" +
		"(COPYING-SeaBIOS-LGPLv3.txt; it incorporates the GPLv3 text in\r\n" +
		"COPYING-SeaBIOS-GPLv3.txt); the other components' notices in the licenses folder.\r\n" +
		"The modified files stay under their licences (LGPL-2.1 for CSMWrap files,\r\n" +
		"LGPLv3 for SeaBIOS files).\r\n" +
		"Upstream: https://github.com/CSMWrap/CSMWrap (tag 3.1.2),\r\n" +
		"  https://github.com/CSMWrap/seabios-csmwrap, https://www.seabios.org/\r\n" +
		"Used by Universal Service OS for Windows XP / Vista and DOS / Windows 3.x\r\n" +
		"without firmware CSM, and for the boot menu's Legacy BIOS mode (CSMWrap).\r\n"
	if err := writeFileAtomic(filepath.Join(dir, "SOURCES.txt"), []byte(sources)); err != nil {
		return err
	}
	fmt.Printf("[STAGE] %s <- %s (CSMWrap %s, MODIFIED, unsigned; source + %d patches)\n",csmwrapTargetDir, filepath.ToSlash(vendorDir), build.Version, len(patches))
	return nil
}

// stageUefiShell copies the pinned EDK2 Shell.efi (manifest hash), its
// BSD-2-Clause-Patent licence, SOURCES.txt and the USOS startup.nsh into
// EFI/USOS/shell and returns the Shell.efi path there (signed afterwards).
func stageUefiShell(vendorDir, startup, usb string) (string, error) {
	var manifest touchManifest
	data, err := os.ReadFile(filepath.Join(vendorDir, "manifest.json"))
	if err != nil {
		return "", fmt.Errorf("vendored UEFI Shell manifest: %w", err)
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		return "", fmt.Errorf("vendored UEFI Shell manifest: %w", err)
	}
	if manifest.Files["Shell.efi"] == "" || manifest.Files["License.txt"] == "" {
		return "", errors.New("vendored UEFI Shell manifest lacks the Shell.efi or License.txt hash")
	}
	dir := filepath.Join(usb, filepath.FromSlash(uefiShellTargetDir))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	target := filepath.Join(dir, "Shell.efi")
	if err := copyVerified(filepath.Join(vendorDir, "Shell.efi"), target, manifest.Files["Shell.efi"]); err != nil {
		return "", err
	}
	if err := copyVerified(filepath.Join(vendorDir, "License.txt"), filepath.Join(dir, "License.txt"), manifest.Files["License.txt"]); err != nil {
		return "", err
	}
	for _, item := range []struct{ source, name string }{{filepath.Join(vendorDir, "SOURCES.txt"), "SOURCES.txt"}, {startup, "startup.nsh"}} {
		content, err := os.ReadFile(item.source)
		if err != nil {
			return "", err
		}
		if err := writeFileAtomic(filepath.Join(dir, item.name), content); err != nil {
			return "", err
		}
	}
	fmt.Printf("[STAGE] %s <- %s (EDK2 UEFI Shell %s)\n", uefiShellTargetDir, filepath.ToSlash(vendorDir), manifest.Version)
	return target, nil
}

type touchManifest struct {
	Version string            `json:"version"`
	Files   map[string]string `json:"files"`
}

// stageTouchDriver copies the vendored TouchI2cDxe.efi (hash-checked against
// its manifest) and its licence into the release ESP tree and returns the
// driver's path there.
func stageTouchDriver(vendorDir, usb string) (string, error) {
	var manifest touchManifest
	data, err := os.ReadFile(filepath.Join(vendorDir, "manifest.json"))
	if err != nil {
		return "", fmt.Errorf("vendored touch driver manifest: %w", err)
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		return "", fmt.Errorf("vendored touch driver manifest: %w", err)
	}
	if manifest.Files["TouchI2cDxe.efi"] == "" || manifest.Files["LICENSE"] == "" {
		return "", errors.New("vendored touch driver manifest lacks the TouchI2cDxe.efi or LICENSE hash")
	}
	target := filepath.Join(usb, filepath.FromSlash(touchDriverTarget))
	licenseDir := filepath.Join(usb, filepath.FromSlash(touchLicenseDir))
	if err := os.MkdirAll(licenseDir, 0o755); err != nil {
		return "", err
	}
	if err := copyVerified(filepath.Join(vendorDir, "TouchI2cDxe.efi"), target, manifest.Files["TouchI2cDxe.efi"]); err != nil {
		return "", err
	}
	if err := copyVerified(filepath.Join(vendorDir, "LICENSE"), filepath.Join(licenseDir, "LICENSE"), manifest.Files["LICENSE"]); err != nil {
		return "", err
	}
	fmt.Printf("[STAGE] %s <- %s (TouchI2cDxe %s)\n", touchDriverTarget, filepath.ToSlash(vendorDir), manifest.Version)
	return target, nil
}
