package efisign

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"time"
)

// Key custody: the private key lives outside the repository, by default in
// %APPDATA%\USOS\signing (USOS_SIGNING_DIR overrides it). Only the public
// certificate is copied onto the USB stick for MokManager enrollment.
const (
	KeyFileName  = "usos-secure-boot.key"
	CertFileName = "usos-secure-boot.cer"
	signingDirEnv = "USOS_SIGNING_DIR"
)

// DefaultKeyDir returns the signing key directory.
func DefaultKeyDir() (string, error) {
	if dir := os.Getenv(signingDirEnv); dir != "" {
		return dir, nil
	}
	config, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("locate the user configuration directory: %w", err)
	}
	return filepath.Join(config, "USOS", "signing"), nil
}

// KeyPair is the USOS Secure Boot signing identity.
type KeyPair struct {
	Key  *rsa.PrivateKey
	Cert *x509.Certificate
}

// Fingerprint is the SHA-256 of the DER certificate, as MokManager and
// `mokutil --list-enrolled` show it.
func (k KeyPair) Fingerprint() string { return CertFingerprint(k.Cert) }

// CertFingerprint returns the lower-case hex SHA-256 of a certificate.
func CertFingerprint(cert *x509.Certificate) string {
	sum := sha256.Sum256(cert.Raw)
	return hex.EncodeToString(sum[:])
}

// GenerateKeyPair creates an RSA-2048 key and a self-signed certificate
// usable as a MOK: code-signing EKU, digital signature key usage, no CA
// basic constraint. commonName should identify the key owner and year.
func GenerateKeyPair(commonName string, now time.Time) (KeyPair, error) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return KeyPair{}, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	if err != nil {
		return KeyPair{}, err
	}
	template := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: commonName, Organization: []string{"Universal Service OS"}},
		NotBefore:             now.Add(-time.Hour).UTC(),
		NotAfter:              now.AddDate(30, 0, 0).UTC(),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageCodeSigning},
		BasicConstraintsValid: true,
		IsCA:                  false,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return KeyPair{}, err
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return KeyPair{}, err
	}
	return KeyPair{Key: key, Cert: cert}, nil
}

// WriteKeyPair stores the key (PKCS#8 PEM, owner-only permissions) and the
// DER certificate in dir. Existing files are never overwritten: losing the
// old key would force every user to enroll a new certificate.
func WriteKeyPair(dir string, pair KeyPair) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	keyPath := filepath.Join(dir, KeyFileName)
	certPath := filepath.Join(dir, CertFileName)
	for _, path := range []string{keyPath, certPath} {
		if _, err := os.Stat(path); err == nil {
			return fmt.Errorf("refusing to overwrite existing %s", path)
		}
	}
	pkcs8, err := x509.MarshalPKCS8PrivateKey(pair.Key)
	if err != nil {
		return err
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pkcs8})
	if err := writeNew(keyPath, keyPEM, 0o600); err != nil {
		return err
	}
	return writeNew(certPath, pair.Cert.Raw, 0o644)
}

func writeNew(path string, data []byte, mode os.FileMode) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}

// ErrNoKey reports that the signing directory has no key pair.
var ErrNoKey = errors.New("USOS Secure Boot signing key not found")

// LoadKeyPair reads the key pair from dir and checks that they match.
func LoadKeyPair(dir string) (KeyPair, error) {
	keyPEM, err := os.ReadFile(filepath.Join(dir, KeyFileName))
	if errors.Is(err, os.ErrNotExist) {
		return KeyPair{}, fmt.Errorf("%w in %s", ErrNoKey, dir)
	}
	if err != nil {
		return KeyPair{}, err
	}
	certDER, err := os.ReadFile(filepath.Join(dir, CertFileName))
	if err != nil {
		return KeyPair{}, fmt.Errorf("read certificate: %w", err)
	}
	block, _ := pem.Decode(keyPEM)
	if block == nil || block.Type != "PRIVATE KEY" {
		return KeyPair{}, errors.New("signing key is not a PKCS#8 PEM PRIVATE KEY")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return KeyPair{}, err
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return KeyPair{}, errors.New("signing key is not RSA")
	}
	cert, err := x509.ParseCertificate(certDER)
	if err != nil {
		return KeyPair{}, fmt.Errorf("parse certificate: %w", err)
	}
	public, ok := cert.PublicKey.(*rsa.PublicKey)
	if !ok || public.N.Cmp(key.N) != 0 || public.E != key.E {
		return KeyPair{}, errors.New("certificate does not match the signing key")
	}
	return KeyPair{Key: key, Cert: cert}, nil
}
