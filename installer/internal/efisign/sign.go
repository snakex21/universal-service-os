package efisign

import (
	"bytes"
	"crypto/rsa"
	"crypto/x509"
	"errors"
	"fmt"
)

// SignOptions controls how an image is prepared before it is signed.
type SignOptions struct {
	// SBAT, when non-empty, is added as a .sbat section. shim requires one
	// in the binary it starts itself (the second stage); images verified
	// later through the SHIM_LOCK protocol may omit it.
	SBAT []byte
	// ReplaceSignature strips an existing certificate table first. Without
	// it a signed input is an error, so a vendor (Microsoft) signature is
	// never dropped by accident.
	ReplaceSignature bool
}

// Sign returns image signed with key/cert.
func Sign(image []byte, key *rsa.PrivateKey, cert *x509.Certificate, options SignOptions) ([]byte, error) {
	prepared, err := Prepare(image, options)
	if err != nil {
		return nil, err
	}
	img, err := Parse(prepared)
	if err != nil {
		return nil, err
	}
	digest, err := img.AuthenticodeHash()
	if err != nil {
		return nil, err
	}
	blob, err := buildSignedData(digest, key, cert)
	if err != nil {
		return nil, err
	}
	if err := img.appendSignature(blob); err != nil {
		return nil, err
	}
	return img.Bytes(), nil
}

// Prepare returns the exact unsigned bytes Sign hashes: the input without
// a signature, with the optional .sbat section, padded to 8 bytes.
func Prepare(image []byte, options SignOptions) ([]byte, error) {
	img, err := Parse(image)
	if err != nil {
		return nil, err
	}
	if img.Signed() {
		if !options.ReplaceSignature {
			return nil, errors.New("image is already signed")
		}
		if err := img.StripSignature(); err != nil {
			return nil, err
		}
	}
	if len(options.SBAT) > 0 {
		// A Windows checkout (core.autocrlf) turns the CSV into CRLF; shim
		// expects LF records, and the result must not depend on checkout.
		options.SBAT = bytes.ReplaceAll(options.SBAT, []byte("\r\n"), []byte("\n"))
		if err := validateSBAT(options.SBAT); err != nil {
			return nil, err
		}
		if existing, ok := img.Section(".sbat"); ok {
			data := bytes.TrimRight(img.SectionData(existing), "\x00")
			if !bytes.Equal(data, bytes.TrimRight(options.SBAT, "\x00")) {
				return nil, errors.New("image already has a different .sbat section")
			}
		} else if err := img.AddSection(".sbat", options.SBAT); err != nil {
			return nil, fmt.Errorf("add .sbat: %w", err)
		}
	}
	if err := img.padForCertificate(); err != nil {
		return nil, err
	}
	return img.Bytes(), nil
}

// validateSBAT checks the CSV shape shim parses: the first record must be
// the "sbat,1,..." self-description and every record needs six fields.
func validateSBAT(data []byte) error {
	text := bytes.TrimRight(data, "\x00")
	if !bytes.HasSuffix(text, []byte("\n")) {
		return errors.New("SBAT data must end with a newline")
	}
	lines := bytes.Split(bytes.TrimSuffix(text, []byte("\n")), []byte("\n"))
	if !bytes.HasPrefix(lines[0], []byte("sbat,1,")) {
		return errors.New(`SBAT data must start with the "sbat,1," record`)
	}
	for i, line := range lines {
		if bytes.ContainsAny(line, "\r\x00") {
			return fmt.Errorf("SBAT line %d contains CR or NUL", i+1)
		}
		if fields := bytes.Split(line, []byte(",")); len(fields) != 6 {
			return fmt.Errorf("SBAT line %d has %d fields, want 6", i+1, len(fields))
		}
	}
	return nil
}

// Verification describes a checked Authenticode signature.
type Verification struct {
	Digest []byte
	Signer *x509.Certificate
}

// VerifyWith checks that image carries a signature whose digest matches the
// image and whose RSA signature verifies with trusted (a self-signed MOK
// certificate, compared byte for byte). It is the same decision shim makes
// for a MOK-signed binary, minus SBAT and revocation lists.
func VerifyWith(image []byte, trusted *x509.Certificate) (Verification, error) {
	img, err := Parse(image)
	if err != nil {
		return Verification{}, err
	}
	digest, err := img.AuthenticodeHash()
	if err != nil {
		return Verification{}, err
	}
	blobs, err := img.Signatures()
	if err != nil {
		return Verification{}, err
	}
	if len(blobs) == 0 {
		return Verification{}, errors.New("image is not signed")
	}
	var lastErr error
	for _, blob := range blobs {
		sig, err := ParseSignature(blob)
		if err != nil {
			lastErr = err
			continue
		}
		if !bytes.Equal(sig.ImageDigest, digest) {
			lastErr = errors.New("signed digest does not match the image")
			continue
		}
		signer, err := sig.VerifyRSA()
		if err != nil {
			lastErr = err
			continue
		}
		if trusted != nil && !bytes.Equal(signer.Raw, trusted.Raw) {
			lastErr = errors.New("signed by a different certificate")
			continue
		}
		return Verification{Digest: digest, Signer: signer}, nil
	}
	return Verification{}, lastErr
}
