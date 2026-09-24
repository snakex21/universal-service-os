// Package mokenroll prepares a shim MOK enrollment request from Windows, the
// equivalent of "mokutil --import usos.cer": it writes the MokNew and MokAuth
// UEFI variables so that shim, on the next start of the USOS drive, launches
// MokManager straight into "Enroll MOK" and asks for the password chosen here.
//
// The byte formats follow shim 16.1 (MokManager.c, PasswordCrypt.h) and
// mokutil (src/mokutil.c, password-crypt.c). The firmware itself is reached
// through the Firmware interface so everything but the Win32 calls is unit
// tested with a fake.
package mokenroll

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"strings"
)

// GUID is an EFI_GUID in its in-memory (mixed-endian) layout: Data1, Data2
// and Data3 little-endian, Data4 as bytes.
type GUID [16]byte

// MustParseGUID parses "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" (braces optional).
func MustParseGUID(s string) GUID {
	g, err := ParseGUID(s)
	if err != nil {
		panic(err)
	}
	return g
}

// ParseGUID parses the textual GUID form into the EFI byte layout.
func ParseGUID(s string) (GUID, error) {
	var g GUID
	s = strings.TrimSuffix(strings.TrimPrefix(s, "{"), "}")
	parts := strings.Split(s, "-")
	if len(parts) != 5 || len(parts[0]) != 8 || len(parts[1]) != 4 || len(parts[2]) != 4 || len(parts[3]) != 4 || len(parts[4]) != 12 {
		return g, fmt.Errorf("bad GUID %q", s)
	}
	raw, err := hex.DecodeString(strings.Join(parts, ""))
	if err != nil {
		return g, fmt.Errorf("bad GUID %q", s)
	}
	// Data1 (4), Data2 (2), Data3 (2) are stored little-endian.
	g[0], g[1], g[2], g[3] = raw[3], raw[2], raw[1], raw[0]
	g[4], g[5] = raw[5], raw[4]
	g[6], g[7] = raw[7], raw[6]
	copy(g[8:], raw[8:])
	return g, nil
}

// String returns the upper-case braced form Windows expects in
// SetFirmwareEnvironmentVariableEx, e.g. {605DAB50-E046-4300-ABB6-3DD810DD8B23}.
func (g GUID) String() string {
	return fmt.Sprintf("{%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X}",
		g[3], g[2], g[1], g[0], g[5], g[4], g[7], g[6], g[8], g[9], g[10], g[11], g[12], g[13], g[14], g[15])
}

var (
	// ShimLockGUID is the vendor GUID of every Mok* variable and the
	// SignatureOwner mokutil uses for imported keys.
	ShimLockGUID = MustParseGUID("605dab50-e046-4300-abb6-3dd810dd8b23")
	// GlobalVariableGUID is EFI_GLOBAL_VARIABLE (SecureBoot, SetupMode, ...).
	GlobalVariableGUID = MustParseGUID("8be4df61-93ca-11d2-aa0d-00e098032b8c")
	// CertX509GUID is EFI_CERT_X509_GUID.
	CertX509GUID = MustParseGUID("a5c059a1-94e4-4aa7-87b5-ab155c2bf072")
)

// Variable names and attributes.
const (
	VarMokNew     = "MokNew"
	VarMokAuth    = "MokAuth"
	VarMokListRT  = "MokListRT"
	VarSecureBoot = "SecureBoot"

	AttrNonVolatile       = 0x1
	AttrBootServiceAccess = 0x2
	AttrRuntimeAccess     = 0x4
	// MokAttributes is what mokutil uses for MokNew/MokAuth.
	MokAttributes = AttrNonVolatile | AttrBootServiceAccess | AttrRuntimeAccess
)

const (
	sigListHeaderSize = 28 // EFI_SIGNATURE_LIST without the optional header
	sigOwnerSize      = 16 // EFI_SIGNATURE_DATA.SignatureOwner
)

// SignatureList is one parsed EFI_SIGNATURE_LIST.
type SignatureList struct {
	Type   GUID
	Header []byte
	Size   uint32 // SignatureSize
	Data   []SignatureData
}

// SignatureData is one EFI_SIGNATURE_DATA entry.
type SignatureData struct {
	Owner GUID
	Data  []byte
}

// X509SignatureList returns an EFI_SIGNATURE_LIST holding one DER
// certificate owned by owner - the MokNew layout mokutil --import writes.
func X509SignatureList(der []byte, owner GUID) []byte {
	sigSize := uint32(sigOwnerSize + len(der))
	out := make([]byte, 0, sigListHeaderSize+int(sigSize))
	out = append(out, CertX509GUID[:]...)
	out = binary.LittleEndian.AppendUint32(out, sigListHeaderSize+sigSize) // SignatureListSize
	out = binary.LittleEndian.AppendUint32(out, 0)                         // SignatureHeaderSize
	out = binary.LittleEndian.AppendUint32(out, sigSize)                   // SignatureSize
	out = append(out, owner[:]...)
	return append(out, der...)
}

// ParseSignatureLists splits a concatenation of EFI_SIGNATURE_LISTs (MokNew,
// MokListRT, db, ...).
func ParseSignatureLists(data []byte) ([]SignatureList, error) {
	var lists []SignatureList
	for off := 0; off < len(data); {
		if len(data)-off < sigListHeaderSize {
			return nil, fmt.Errorf("signature list at %d: truncated header", off)
		}
		var l SignatureList
		copy(l.Type[:], data[off:off+16])
		listSize := binary.LittleEndian.Uint32(data[off+16:])
		headerSize := binary.LittleEndian.Uint32(data[off+20:])
		l.Size = binary.LittleEndian.Uint32(data[off+24:])
		if listSize < sigListHeaderSize || uint64(listSize) > uint64(len(data)-off) {
			return nil, fmt.Errorf("signature list at %d: bad size %d", off, listSize)
		}
		body := data[off+sigListHeaderSize : off+int(listSize)]
		if uint64(headerSize) > uint64(len(body)) {
			return nil, fmt.Errorf("signature list at %d: bad header size %d", off, headerSize)
		}
		l.Header = body[:headerSize]
		body = body[headerSize:]
		if l.Size < sigOwnerSize || len(body)%int(l.Size) != 0 {
			return nil, fmt.Errorf("signature list at %d: bad signature size %d", off, l.Size)
		}
		for i := 0; i < len(body); i += int(l.Size) {
			var d SignatureData
			copy(d.Owner[:], body[i:i+sigOwnerSize])
			d.Data = body[i+sigOwnerSize : i+int(l.Size)]
			l.Data = append(l.Data, d)
		}
		lists = append(lists, l)
		off += int(listSize)
	}
	return lists, nil
}

// encodeSignatureList serialises a parsed list again.
func encodeSignatureList(l SignatureList) []byte {
	size := sigListHeaderSize + len(l.Header) + len(l.Data)*int(l.Size)
	out := make([]byte, 0, size)
	out = append(out, l.Type[:]...)
	out = binary.LittleEndian.AppendUint32(out, uint32(size))
	out = binary.LittleEndian.AppendUint32(out, uint32(len(l.Header)))
	out = binary.LittleEndian.AppendUint32(out, l.Size)
	out = append(out, l.Header...)
	for _, d := range l.Data {
		out = append(out, d.Owner[:]...)
		out = append(out, d.Data...)
	}
	return out
}

// ContainsX509 reports whether an EFI_SIGNATURE_LIST blob holds der as an
// X.509 entry.
func ContainsX509(data, der []byte) (bool, error) {
	lists, err := ParseSignatureLists(data)
	if err != nil {
		return false, err
	}
	for _, l := range lists {
		if l.Type != CertX509GUID {
			continue
		}
		for _, d := range l.Data {
			if bytes.Equal(d.Data, der) {
				return true, nil
			}
		}
	}
	return false, nil
}

// BuildMokNew returns the MokNew payload: our certificate first, followed by
// the still valid part of an existing pending request (as mokutil appends
// the old request), with any earlier copy of our certificate dropped so it
// is never enrolled twice. An unparseable existing request is replaced.
func BuildMokNew(der, existing []byte) (data []byte, keptExisting bool) {
	out := X509SignatureList(der, ShimLockGUID)
	if len(existing) == 0 {
		return out, false
	}
	lists, err := ParseSignatureLists(existing)
	if err != nil {
		return out, false
	}
	for _, l := range lists {
		if l.Type == CertX509GUID {
			kept := l.Data[:0:0]
			for _, d := range l.Data {
				if !bytes.Equal(d.Data, der) {
					kept = append(kept, d)
				}
			}
			if len(kept) == 0 {
				continue
			}
			l.Data = kept
		}
		out = append(out, encodeSignatureList(l)...)
		keptExisting = true
	}
	return out, keptExisting
}

// ---- MokAuth (pw_crypt_t) -------------------------------------------------

// pw_crypt_t, packed: u16 method, u64 iter_count, u16 salt_size,
// u8 salt[32], u8 hash[128].
const (
	PasswordCryptSize = 2 + 8 + 2 + 32 + 128
	methodSHA512      = 4 // SHA512_BASED in PasswordCrypt.h
	saltLength        = 16
	saltField         = 32
	hashField         = 128

	// Password limits: MokManager accepts 1..256 characters but compares
	// each CHAR16 truncated to a byte, so only printable ASCII is safe; the
	// installer keeps it short enough to type on the firmware console.
	MinPasswordLength         = 1
	MaxPasswordLength         = 16
	RecommendedPasswordLength = 4
	DefaultPassword           = "usos"
)

var (
	ErrPasswordEmpty   = errors.New("password is empty")
	ErrPasswordTooLong = fmt.Errorf("password is longer than %d characters", MaxPasswordLength)
	ErrPasswordChars   = errors.New("password may contain only printable ASCII characters (no spaces)")
)

// ValidatePassword checks a MokManager password: 1-16 printable ASCII
// characters. Spaces are refused because firmware consoles differ in how
// they deliver them.
func ValidatePassword(password string) error {
	if len(password) < MinPasswordLength {
		return ErrPasswordEmpty
	}
	for _, r := range password {
		if r <= ' ' || r > '~' {
			return ErrPasswordChars
		}
	}
	if len(password) > MaxPasswordLength {
		return ErrPasswordTooLong
	}
	return nil
}

// NewSalt draws a 16-character salt from the crypt alphabet.
func NewSalt(random io.Reader) ([]byte, error) {
	if random == nil {
		random = rand.Reader
	}
	raw := make([]byte, saltLength)
	if _, err := io.ReadFull(random, raw); err != nil {
		return nil, fmt.Errorf("salt: %w", err)
	}
	for i, b := range raw {
		raw[i] = cryptAlphabet[int(b)%len(cryptAlphabet)] // 256 % 64 == 0: unbiased
	}
	return raw, nil
}

// BuildMokAuth returns the 172-byte pw_crypt_t for password with the given
// 16-character salt (SHA-512-crypt, 5000 rounds).
func BuildMokAuth(password string, salt []byte) ([]byte, error) {
	if err := ValidatePassword(password); err != nil {
		return nil, err
	}
	if len(salt) != saltLength {
		return nil, fmt.Errorf("salt must be %d bytes", saltLength)
	}
	digest := sha512CryptRaw([]byte(password), salt, sha512CryptDefaultRound)
	out := make([]byte, PasswordCryptSize)
	binary.LittleEndian.PutUint16(out[0:], methodSHA512)
	binary.LittleEndian.PutUint64(out[2:], sha512CryptDefaultRound)
	binary.LittleEndian.PutUint16(out[10:], saltLength)
	copy(out[12:12+saltField], salt)
	copy(out[12+saltField:], digest[:])
	return out, nil
}

// VerifyMokAuth recomputes the hash the way MokManager does and reports
// whether password unlocks the pw_crypt_t in auth.
func VerifyMokAuth(auth []byte, password string) bool {
	if len(auth) != PasswordCryptSize || binary.LittleEndian.Uint16(auth[0:]) != methodSHA512 {
		return false
	}
	saltSize := int(binary.LittleEndian.Uint16(auth[10:]))
	if saltSize > saltField {
		return false
	}
	salt := auth[12 : 12+saltSize]
	rounds := binary.LittleEndian.Uint64(auth[2:])
	if rounds != sha512CryptDefaultRound {
		return false // shim's sha512_crypt always runs 5000 rounds
	}
	digest := sha512CryptRaw([]byte(password), salt, int(rounds))
	return bytes.Equal(auth[12+saltField:12+saltField+len(digest)], digest[:])
}
