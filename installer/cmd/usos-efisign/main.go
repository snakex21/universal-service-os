// usos-efisign signs UEFI images for the USOS Secure Boot chain
// (Microsoft-signed shim -> MOK-signed USOS) with the standard library only.
//
//	go run ./cmd/usos-efisign keygen                  create the signing key (once)
//	go run ./cmd/usos-efisign release -root ..        sign the release outputs and lay out the shim chain
//	go run ./cmd/usos-efisign sign -in A -out B [-sbat F] [-replace]
//	go run ./cmd/usos-efisign verify -in A [-cert C]
//	go run ./cmd/usos-efisign hash -in A
//	go run ./cmd/usos-efisign derive-check -unsigned A -signed B -sbat F
//	go run ./cmd/usos-efisign mok-request -cert C -password P -out DIR   dump MokNew.bin/MokAuth.bin
//
// The private key is read from %APPDATA%\USOS\signing (or USOS_SIGNING_DIR)
// and never enters the repository.
package main

import (
	"bytes"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/snakex21/universal-service-os/installer/internal/efisign"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	var err error
	switch os.Args[1] {
	case "keygen":
		err = keygen(os.Args[2:])
	case "sign":
		err = sign(os.Args[2:])
	case "verify":
		err = verify(os.Args[2:])
	case "hash":
		err = hash(os.Args[2:])
	case "release":
		err = release(os.Args[2:])
	case "derive-check":
		err = deriveCheck(os.Args[2:])
	case "mok-request":
		err = mokRequest(os.Args[2:])
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "[ERROR]", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: usos-efisign keygen|sign|verify|hash|release|derive-check|mok-request [flags]")
	os.Exit(2)
}

func keyDirFlag(set *flag.FlagSet) *string {
	return set.String("key-dir", "", "signing key directory (default %APPDATA%\\USOS\\signing or USOS_SIGNING_DIR)")
}

func resolveKeyDir(value string) (string, error) {
	if value != "" {
		return value, nil
	}
	return efisign.DefaultKeyDir()
}

func keygen(args []string) error {
	set := flag.NewFlagSet("keygen", flag.ExitOnError)
	dir := keyDirFlag(set)
	name := set.String("cn", "", "certificate common name (default: USOS Secure Boot Signing <year>)")
	set.Parse(args)
	keyDir, err := resolveKeyDir(*dir)
	if err != nil {
		return err
	}
	now := time.Now()
	commonName := *name
	if commonName == "" {
		commonName = fmt.Sprintf("USOS Secure Boot Signing %d", now.Year())
	}
	pair, err := efisign.GenerateKeyPair(commonName, now)
	if err != nil {
		return err
	}
	if err := efisign.WriteKeyPair(keyDir, pair); err != nil {
		return err
	}
	fmt.Printf("[KEY] %s\n[CERT] subject=%s sha256=%s\n", keyDir, pair.Cert.Subject, pair.Fingerprint())
	fmt.Println("[NOTE] Back up the key directory offline. Never copy the .key file into the repository.")
	return nil
}

func sign(args []string) error {
	set := flag.NewFlagSet("sign", flag.ExitOnError)
	in := set.String("in", "", "input PE")
	out := set.String("out", "", "output PE (may equal -in)")
	sbat := set.String("sbat", "", "optional SBAT CSV to add as a .sbat section")
	replace := set.Bool("replace", false, "replace an existing signature")
	dir := keyDirFlag(set)
	set.Parse(args)
	if *in == "" || *out == "" {
		return errors.New("sign needs -in and -out")
	}
	keyDir, err := resolveKeyDir(*dir)
	if err != nil {
		return err
	}
	pair, err := efisign.LoadKeyPair(keyDir)
	if err != nil {
		return err
	}
	options := efisign.SignOptions{ReplaceSignature: *replace}
	if *sbat != "" {
		if options.SBAT, err = os.ReadFile(*sbat); err != nil {
			return err
		}
	}
	return signFile(*in, *out, pair, options)
}

func signFile(in, out string, pair efisign.KeyPair, options efisign.SignOptions) error {
	data, err := os.ReadFile(in)
	if err != nil {
		return err
	}
	signed, err := efisign.Sign(data, pair.Key, pair.Cert, options)
	if err != nil {
		return fmt.Errorf("%s: %w", in, err)
	}
	if _, err := efisign.VerifyWith(signed, pair.Cert); err != nil {
		return fmt.Errorf("%s: self-check failed: %w", in, err)
	}
	return writeFileAtomic(out, signed)
}

func writeFileAtomic(path string, data []byte) error {
	temp := path + ".new"
	if err := os.WriteFile(temp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(temp, path)
}

func verify(args []string) error {
	set := flag.NewFlagSet("verify", flag.ExitOnError)
	in := set.String("in", "", "signed PE")
	certPath := set.String("cert", "", "DER certificate that must have signed the image (default: any embedded signer)")
	set.Parse(args)
	data, err := os.ReadFile(*in)
	if err != nil {
		return err
	}
	var trusted *x509.Certificate
	if *certPath != "" {
		der, err := os.ReadFile(*certPath)
		if err != nil {
			return err
		}
		if trusted, err = x509.ParseCertificate(der); err != nil {
			return err
		}
	}
	result, err := efisign.VerifyWith(data, trusted)
	if err != nil {
		return err
	}
	fmt.Printf("[PASS] %s authenticode-sha256=%s signer=%q cert-sha256=%s\n", *in, hex.EncodeToString(result.Digest), result.Signer.Subject.String(), efisign.CertFingerprint(result.Signer))
	return nil
}

func hash(args []string) error {
	set := flag.NewFlagSet("hash", flag.ExitOnError)
	in := set.String("in", "", "PE image")
	set.Parse(args)
	data, err := os.ReadFile(*in)
	if err != nil {
		return err
	}
	img, err := efisign.Parse(data)
	if err != nil {
		return err
	}
	digest, err := img.AuthenticodeHash()
	if err != nil {
		return err
	}
	fmt.Printf("%s  %s\n", hex.EncodeToString(digest), *in)
	blobs, err := img.Signatures()
	if err != nil {
		return err
	}
	for i, blob := range blobs {
		sig, err := efisign.ParseSignature(blob)
		if err != nil {
			fmt.Printf("  signature %d: unreadable: %v\n", i, err)
			continue
		}
		signer := "unknown"
		if cert, err := sig.Signer(); err == nil {
			signer = cert.Subject.String()
		}
		fmt.Printf("  signature %d: digest=%s match=%v signer=%q\n", i, hex.EncodeToString(sig.ImageDigest), bytes.Equal(sig.ImageDigest, digest), signer)
	}
	return nil
}

// deriveCheck proves that a signed second stage is exactly the unsigned
// build output plus the .sbat section, padding and a certificate table.
func deriveCheck(args []string) error {
	set := flag.NewFlagSet("derive-check", flag.ExitOnError)
	unsigned := set.String("unsigned", "", "unsigned build output")
	signed := set.String("signed", "", "signed (or unsigned-marked) release file")
	sbat := set.String("sbat", "", "SBAT CSV used for the release")
	set.Parse(args)
	source, err := os.ReadFile(*unsigned)
	if err != nil {
		return err
	}
	derived, err := os.ReadFile(*signed)
	if err != nil {
		return err
	}
	options := efisign.SignOptions{}
	if *sbat != "" {
		if options.SBAT, err = os.ReadFile(*sbat); err != nil {
			return err
		}
	}
	prepared, err := efisign.Prepare(source, options)
	if err != nil {
		return err
	}
	img, err := efisign.Parse(derived)
	if err != nil {
		return err
	}
	if img.Signed() {
		if err := img.StripSignature(); err != nil {
			return err
		}
	}
	if !bytes.Equal(img.Bytes(), prepared) {
		return fmt.Errorf("%s is not derived from %s", *signed, *unsigned)
	}
	fmt.Printf("[PASS] %s derives from %s (signed=%v)\n", *signed, *unsigned, len(derived) != len(prepared))
	return nil
}
