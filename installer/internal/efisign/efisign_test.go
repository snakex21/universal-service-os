package efisign

import (
	"bytes"
	"encoding/asn1"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func repoFile(t *testing.T, relative string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", filepath.FromSlash(relative)))
	if err != nil {
		t.Skipf("fixture %s unavailable: %v", relative, err)
	}
	return data
}

// A Microsoft-signed PE carries the Authenticode digest Microsoft's signing
// service computed; our hash of the same bytes must equal it.
func assertMatchesVendorDigest(t *testing.T, name string, data []byte) {
	t.Helper()
	img, err := Parse(data)
	if err != nil {
		t.Fatalf("%s: parse: %v", name, err)
	}
	blobs, err := img.Signatures()
	if err != nil || len(blobs) == 0 {
		t.Fatalf("%s: no signature (%v)", name, err)
	}
	sig, err := ParseSignature(blobs[0])
	if err != nil {
		t.Fatalf("%s: parse signature: %v", name, err)
	}
	if !sig.ImageDigestAlgorithm.Equal(asn1.ObjectIdentifier{2, 16, 840, 1, 101, 3, 4, 2, 1}) {
		t.Skipf("%s: signature uses %v, not SHA-256", name, sig.ImageDigestAlgorithm)
	}
	digest, err := img.AuthenticodeHash()
	if err != nil {
		t.Fatalf("%s: hash: %v", name, err)
	}
	if !bytes.Equal(digest, sig.ImageDigest) {
		t.Fatalf("%s: Authenticode hash %x, signature says %x", name, digest, sig.ImageDigest)
	}
	signer, err := sig.Signer()
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	if !strings.Contains(signer.Subject.String(), "Microsoft") {
		t.Fatalf("%s: unexpected signer %s", name, signer.Subject)
	}
}

func TestHashMatchesMicrosoftSignedWimboot(t *testing.T) {
	assertMatchesVendorDigest(t, "wimboot", repoFile(t, "tools/vendor/wimboot/2.9.0/wimboot"))
}

func TestHashMatchesMicrosoftSignedShim(t *testing.T) {
	matches, _ := filepath.Glob(filepath.Join("..", "..", "..", "tools", "vendor", "shim", "*", "shimx64.efi"))
	if len(matches) == 0 {
		t.Skip("vendored shim not present")
	}
	for _, path := range matches {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		assertMatchesVendorDigest(t, path, data)
	}
}

func TestHashMatchesWindowsBootManager(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows boot manager only exists on Windows")
	}
	data, err := os.ReadFile(`C:\Windows\Boot\EFI\bootmgfw.efi`)
	if err != nil {
		t.Skip(err)
	}
	assertMatchesVendorDigest(t, "bootmgfw.efi", data)
}

func testKeyPair(t *testing.T) KeyPair {
	t.Helper()
	pair, err := GenerateKeyPair("USOS test key", time.Date(2026, 9, 24, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	return pair
}

// unsignedFixture strips wimboot's Microsoft signature and .sbat so the
// tests have an unsigned, section-appendable PE without a checked-in blob.
func unsignedFixture(t *testing.T) []byte {
	t.Helper()
	img, err := Parse(repoFile(t, "tools/vendor/wimboot/2.9.0/wimboot"))
	if err != nil {
		t.Fatal(err)
	}
	if err := img.StripSignature(); err != nil {
		t.Fatal(err)
	}
	return img.Bytes()
}

const testSBAT = "sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md\nusos,1,Universal Service OS,usos,1,https://example.invalid/usos\n"

func TestSignAndVerifyRoundTrip(t *testing.T) {
	pair := testKeyPair(t)
	// wimboot already has .sbat; sign without adding one.
	signed, err := Sign(unsignedFixture(t), pair.Key, pair.Cert, SignOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := VerifyWith(signed, pair.Cert); err != nil {
		t.Fatalf("verify: %v", err)
	}
	other := testKeyPair(t)
	if _, err := VerifyWith(signed, other.Cert); err == nil {
		t.Fatal("verification accepted a different certificate")
	}
	tampered := append([]byte(nil), signed...)
	tampered[0x600] ^= 0xff
	if _, err := VerifyWith(tampered, pair.Cert); err == nil {
		t.Fatal("verification accepted a modified image")
	}
	if len(signed)%8 != 0 {
		t.Fatalf("signed image length %d is not 8-byte aligned", len(signed))
	}
}

func TestSigningIsDeterministic(t *testing.T) {
	pair := testKeyPair(t)
	input := unsignedFixture(t)
	first, err := Sign(input, pair.Key, pair.Cert, SignOptions{})
	if err != nil {
		t.Fatal(err)
	}
	second, err := Sign(input, pair.Key, pair.Cert, SignOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first, second) {
		t.Fatal("two signatures of the same input differ")
	}
}

func TestSignRefusesVendorSignatureUnlessReplacing(t *testing.T) {
	pair := testKeyPair(t)
	wimboot := repoFile(t, "tools/vendor/wimboot/2.9.0/wimboot")
	if _, err := Sign(wimboot, pair.Key, pair.Cert, SignOptions{}); err == nil {
		t.Fatal("signed over an existing signature")
	}
	resigned, err := Sign(wimboot, pair.Key, pair.Cert, SignOptions{ReplaceSignature: true})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := VerifyWith(resigned, pair.Cert); err != nil {
		t.Fatal(err)
	}
}

func TestAddSBATSection(t *testing.T) {
	img, err := Parse(unsignedFixture(t))
	if err != nil {
		t.Fatal(err)
	}
	// Remove wimboot's own .sbat by rebuilding from a fixture without it is
	// not possible; use a fresh name to exercise AddSection instead.
	before := len(img.Sections)
	if err := img.AddSection(".usos", []byte(testSBAT)); err != nil {
		t.Fatal(err)
	}
	if len(img.Sections) != before+1 {
		t.Fatalf("sections %d, want %d", len(img.Sections), before+1)
	}
	section, ok := img.Section(".usos")
	if !ok {
		t.Fatal("added section missing")
	}
	if got := string(bytes.TrimRight(img.SectionData(section), "\x00")); got != testSBAT {
		t.Fatalf("section data %q", got)
	}
	if section.VirtualAddress%img.sectionAlignment != 0 || section.PointerToRaw%img.fileAlignment != 0 {
		t.Fatalf("misaligned section %+v", section)
	}
	for _, s := range img.Sections[:before] {
		if s.VirtualAddress+max(s.VirtualSize, s.SizeOfRawData) > section.VirtualAddress {
			t.Fatalf("new section overlaps %s", s.Name)
		}
	}
	if _, err := img.AuthenticodeHash(); err != nil {
		t.Fatal(err)
	}
}

func TestSignWithSBATAddsSectionAndRejectsConflicts(t *testing.T) {
	pair := testKeyPair(t)
	input := unsignedFixture(t)
	// wimboot's existing .sbat differs from testSBAT.
	if _, err := Sign(input, pair.Key, pair.Cert, SignOptions{SBAT: []byte(testSBAT)}); err == nil {
		t.Fatal("replaced an existing, different .sbat section")
	}
	img, _ := Parse(input)
	existing, _ := img.Section(".sbat")
	same := bytes.TrimRight(img.SectionData(existing), "\x00")
	if _, err := Sign(input, pair.Key, pair.Cert, SignOptions{SBAT: same}); err != nil {
		t.Fatalf("identical .sbat rejected: %v", err)
	}
}

func TestPrepareNormalizesCRLFSBAT(t *testing.T) {
	img, _ := Parse(unsignedFixture(t))
	existing, _ := img.Section(".sbat")
	lf := bytes.TrimRight(img.SectionData(existing), "\x00")
	crlf := bytes.ReplaceAll(lf, []byte("\n"), []byte("\r\n"))
	a, err := Prepare(unsignedFixture(t), SignOptions{SBAT: lf})
	if err != nil {
		t.Fatal(err)
	}
	b, err := Prepare(unsignedFixture(t), SignOptions{SBAT: crlf})
	if err != nil {
		t.Fatalf("CRLF SBAT rejected: %v", err)
	}
	if !bytes.Equal(a, b) {
		t.Fatal("CRLF and LF SBAT produce different images")
	}
}

func TestValidateSBAT(t *testing.T) {
	for _, bad := range []string{"", "usos,1,a,b,c,d\n", "sbat,1,SBAT Version,sbat,1,x", "sbat,1,SBAT Version,sbat,1,x\nshort,1\n"} {
		if validateSBAT([]byte(bad)) == nil {
			t.Errorf("accepted %q", bad)
		}
	}
	if err := validateSBAT([]byte(testSBAT)); err != nil {
		t.Fatal(err)
	}
}

func TestKeyPairRoundTripAndNoOverwrite(t *testing.T) {
	dir := t.TempDir()
	pair := testKeyPair(t)
	if err := WriteKeyPair(dir, pair); err != nil {
		t.Fatal(err)
	}
	loaded, err := LoadKeyPair(dir)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Fingerprint() != pair.Fingerprint() {
		t.Fatal("fingerprint changed after reload")
	}
	if err := WriteKeyPair(dir, testKeyPair(t)); err == nil {
		t.Fatal("overwrote an existing key")
	}
	if _, err := LoadKeyPair(t.TempDir()); err == nil {
		t.Fatal("loaded a key from an empty directory")
	}
	cert := pair.Cert
	if len(cert.ExtKeyUsage) != 1 || cert.IsCA || cert.PublicKeyAlgorithm.String() != "RSA" {
		t.Fatalf("unexpected certificate profile: eku=%v ca=%v alg=%v", cert.ExtKeyUsage, cert.IsCA, cert.PublicKeyAlgorithm)
	}
}
