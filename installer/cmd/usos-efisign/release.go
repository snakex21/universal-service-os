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
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/efisign"
)

// Release layout of the removable-media path on the USOS ESP:
//
//	EFI/BOOT/BOOTX64.EFI  shim (Microsoft UEFI CA signed, vendored)
//	EFI/BOOT/mmx64.efi    MokManager (signed by the shim vendor)
//	EFI/BOOT/grubx64.efi  USOS, MOK-signed, with a .sbat section
//	EFI/USOS/ENROLL_THIS_KEY_IN_MOKMANAGER.cer, ENROLL-README.txt, secure-boot.ini
const (
	shimVendorDir     = "tools/vendor/shim/16.1-7"
	sbatPath          = "assets/secure-boot/usos.sbat.csv"
	readmePath        = "assets/secure-boot/ENROLL-README.txt"
	referenceCertPath = "assets/secure-boot/usos-secure-boot.cer"
	unsignedUsosPath  = "zig-out/manual-usb/EFI/BOOT/BOOTX64.EFI"
	usbRoot           = "zig-out/usb"
	enrollCertName    = "ENROLL_THIS_KEY_IN_MOKMANAGER.cer"
	secureBootINIPath = "EFI/USOS/secure-boot.ini"
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
		if err := os.WriteFile(filepath.Join(usosDir, enrollCertName), pair.Cert.Raw, 0o644); err != nil {
			return err
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
