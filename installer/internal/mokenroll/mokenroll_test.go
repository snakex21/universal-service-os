package mokenroll

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// crypt reproduces crypt(3) output for "$6$[rounds=N$]salt" settings.
func crypt(key, setting string) string {
	rest := strings.TrimPrefix(setting, "$6$")
	rounds, prefix := sha512CryptDefaultRound, "$6$"
	if strings.HasPrefix(rest, "rounds=") {
		end := strings.IndexByte(rest, '$')
		var n int
		for _, c := range rest[len("rounds="):end] {
			n = n*10 + int(c-'0')
		}
		rounds, prefix, rest = n, "$6$"+rest[:end+1], rest[end+1:]
	}
	salt := strings.SplitN(rest, "$", 2)[0]
	if len(salt) > 16 {
		salt = salt[:16]
	}
	return prefix + salt + "$" + sha512CryptEncode(sha512CryptRaw([]byte(key), []byte(salt), rounds))
}

func TestSHA512CryptVectors(t *testing.T) {
	// Test vectors from Drepper's specification.
	cases := []struct{ setting, key, want string }{
		{"$6$saltstring", "Hello world!", "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1"},
		{"$6$rounds=10000$saltstringsaltstring", "Hello world!", "$6$rounds=10000$saltstringsaltst$OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sbHbbMCVNSnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v."},
		{"$6$rounds=5000$toolongsaltstring", "This is just a test", "$6$rounds=5000$toolongsaltstrin$lQ8jolhgVRVhY4b5pZKaysCLi0QBxGoNeKQzQ3glMhwllF7oGDZxUhx1yxdYcz/e1JSbq3y6JMxxl8audkUEm0"},
		{"$6$rounds=1400$anotherlongsaltstring", "a very much longer text to encrypt.  This one even stretches over morethan one line.", "$6$rounds=1400$anotherlongsalts$POfYwTEok97VWcjxIiSOjiykti.o/pQs.wPvMxQ6Fm7I6IoYN3CmLs66x9t0oSwbtEW7o7UmJEiDwGqd8p4ur1"},
		{"$6$rounds=10$roundstoolow", "the minimum number is still observed", "$6$rounds=10$roundstoolow$kUMsbe306n21p9R.FRkW3IGn.S9NPN0x50YhH1xhLsPuWGsUSklZt58jaTfF4ZEQpyUNGc0dqbpBYYBaHHrsX."},
	}
	for _, c := range cases {
		if strings.Contains(c.setting, "rounds=10$") {
			// crypt(3) clamps rounds to at least 1000; shim never uses it.
			got := "$6$rounds=10$roundstoolow$" + sha512CryptEncode(sha512CryptRaw([]byte(c.key), []byte("roundstoolow"), 1000))
			if got != c.want {
				t.Errorf("clamped rounds: got %s", got)
			}
			continue
		}
		if got := crypt(c.key, c.setting); got != c.want {
			t.Errorf("crypt(%q, %q)\n got %s\nwant %s", c.key, c.setting, got, c.want)
		}
	}
}

func testCert(t *testing.T, cn string) []byte {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: cn}, NotBefore: time.Unix(0, 0), NotAfter: time.Unix(1<<31, 0)}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return der
}

func TestGUIDLayout(t *testing.T) {
	want, _ := hex.DecodeString("50ab5d6046e00043abb63dd810dd8b23")
	if !bytes.Equal(ShimLockGUID[:], want) {
		t.Fatalf("SHIM_LOCK_GUID bytes %x", ShimLockGUID[:])
	}
	if got := ShimLockGUID.String(); got != "{605DAB50-E046-4300-ABB6-3DD810DD8B23}" {
		t.Fatalf("String() = %s", got)
	}
	x509Want, _ := hex.DecodeString("a159c0a5e494a74a87b5ab155c2bf072")
	if !bytes.Equal(CertX509GUID[:], x509Want) {
		t.Fatalf("EFI_CERT_X509_GUID bytes %x", CertX509GUID[:])
	}
	if GlobalVariableGUID.String() != "{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}" {
		t.Fatal(GlobalVariableGUID.String())
	}
}

func TestMokNewLayout(t *testing.T) {
	der := testCert(t, "a")
	got := X509SignatureList(der, ShimLockGUID)
	if len(got) != 28+16+len(der) {
		t.Fatalf("size %d", len(got))
	}
	if !bytes.Equal(got[:16], CertX509GUID[:]) ||
		binary.LittleEndian.Uint32(got[16:]) != uint32(28+16+len(der)) ||
		binary.LittleEndian.Uint32(got[20:]) != 0 ||
		binary.LittleEndian.Uint32(got[24:]) != uint32(16+len(der)) ||
		!bytes.Equal(got[28:44], ShimLockGUID[:]) || !bytes.Equal(got[44:], der) {
		t.Fatalf("bad layout % x", got[:48])
	}
	if ok, err := ContainsX509(got, der); !ok || err != nil {
		t.Fatalf("ContainsX509 = %v, %v", ok, err)
	}
}

func TestBuildMokNewMergesWithoutDuplicates(t *testing.T) {
	ours, other := testCert(t, "ours"), testCert(t, "other")
	fresh, merged := BuildMokNew(ours, nil)
	if merged {
		t.Fatal("merged without an existing request")
	}
	// Re-running on our own request must not duplicate the key.
	again, merged := BuildMokNew(ours, fresh)
	if merged || !bytes.Equal(again, fresh) {
		t.Fatal("re-running duplicated our key")
	}
	// A foreign pending key is kept after ours.
	existing := append(X509SignatureList(other, ShimLockGUID), fresh...)
	combined, merged := BuildMokNew(ours, existing)
	if !merged {
		t.Fatal("foreign request dropped")
	}
	lists, err := ParseSignatureLists(combined)
	if err != nil || len(lists) != 2 || !bytes.Equal(lists[0].Data[0].Data, ours) || !bytes.Equal(lists[1].Data[0].Data, other) {
		t.Fatalf("lists=%d err=%v", len(lists), err)
	}
	// Garbage is replaced.
	if out, merged := BuildMokNew(ours, []byte{1, 2, 3}); merged || !bytes.Equal(out, fresh) {
		t.Fatal("garbage not replaced")
	}
}

func TestMokAuthLayout(t *testing.T) {
	salt := []byte("abcdefghABCDEFGH")
	auth, err := BuildMokAuth("usos", salt)
	if err != nil {
		t.Fatal(err)
	}
	if len(auth) != 172 {
		t.Fatalf("size %d", len(auth))
	}
	if binary.LittleEndian.Uint16(auth[0:]) != 4 || binary.LittleEndian.Uint64(auth[2:]) != 5000 || binary.LittleEndian.Uint16(auth[10:]) != 16 {
		t.Fatalf("header % x", auth[:12])
	}
	if !bytes.Equal(auth[12:28], salt) || !bytes.Equal(auth[28:44], make([]byte, 16)) {
		t.Fatal("salt field")
	}
	digest := sha512CryptRaw([]byte("usos"), salt, 5000)
	if !bytes.Equal(auth[44:108], digest[:]) || !bytes.Equal(auth[108:], make([]byte, 64)) {
		t.Fatal("hash field")
	}
	// Cross-check with crypt(3) text: the stored bytes are the decoded
	// $6$ digest.
	if crypt("usos", "$6$"+string(salt)) != "$6$"+string(salt)+"$"+sha512CryptEncode(digest) {
		t.Fatal("encode mismatch")
	}
	if !VerifyMokAuth(auth, "usos") || VerifyMokAuth(auth, "usoS") {
		t.Fatal("VerifyMokAuth")
	}
}

func TestSaltAlphabet(t *testing.T) {
	salt, err := NewSalt(nil)
	if err != nil || len(salt) != 16 {
		t.Fatal(err)
	}
	for _, c := range salt {
		if !strings.ContainsRune(cryptAlphabet, rune(c)) {
			t.Fatalf("salt char %q", c)
		}
	}
}

func TestValidatePassword(t *testing.T) {
	for _, ok := range []string{"usos", "a", "Pa$$w0rd!", strings.Repeat("x", 16)} {
		if err := ValidatePassword(ok); err != nil {
			t.Errorf("%q: %v", ok, err)
		}
	}
	for bad, want := range map[string]error{"": ErrPasswordEmpty, "has space": ErrPasswordChars, "zażółć": ErrPasswordChars, "tab\t": ErrPasswordChars, strings.Repeat("x", 17): ErrPasswordTooLong} {
		if err := ValidatePassword(bad); !errors.Is(err, want) {
			t.Errorf("%q: %v want %v", bad, err, want)
		}
	}
}

// fakeFirmware records writes in memory; it never touches real NVRAM.
type fakeFirmware struct {
	uefi    bool
	vars    map[string][]byte
	failSet map[string]error
	writes  []string
}

func newFake() *fakeFirmware {
	return &fakeFirmware{uefi: true, vars: map[string][]byte{}, failSet: map[string]error{}}
}

func (f *fakeFirmware) key(name string, g GUID) string { return g.String() + name }

func (f *fakeFirmware) UEFI() (bool, error) { return f.uefi, nil }

func (f *fakeFirmware) Get(name string, g GUID) ([]byte, uint32, error) {
	v, ok := f.vars[f.key(name, g)]
	if !ok {
		return nil, 0, ErrNotFound
	}
	return append([]byte(nil), v...), MokAttributes, nil
}

func (f *fakeFirmware) Set(name string, g GUID, data []byte, attrs uint32) error {
	if err := f.failSet[name]; err != nil && len(data) > 0 {
		return err
	}
	if attrs != MokAttributes {
		return errors.New("wrong attributes")
	}
	f.writes = append(f.writes, name)
	if len(data) == 0 {
		delete(f.vars, f.key(name, g))
		return nil
	}
	f.vars[f.key(name, g)] = append([]byte(nil), data...)
	return nil
}

func TestPrepareWritesRequest(t *testing.T) {
	der := testCert(t, "usos")
	fw := newFake()
	res, err := Prepare(fw, der, "usos", nil)
	if err != nil || res.AlreadyEnrolled {
		t.Fatalf("%+v %v", res, err)
	}
	if strings.Join(fw.writes, ",") != "MokNew,MokAuth" {
		t.Fatalf("writes %v", fw.writes)
	}
	auth, _, _ := fw.Get(VarMokAuth, ShimLockGUID)
	if !VerifyMokAuth(auth, "usos") {
		t.Fatal("MokAuth does not verify")
	}
	st, err := Check(fw, der)
	if err != nil || !st.Pending || !st.PendingAuth || st.Enrolled != Unknown {
		t.Fatalf("%+v %v", st, err)
	}
}

func TestPrepareRollsBackWhenMokAuthFails(t *testing.T) {
	der := testCert(t, "usos")
	fw := newFake()
	fw.failSet[VarMokAuth] = errors.New("nvram full")
	if _, err := Prepare(fw, der, "usos", nil); err == nil {
		t.Fatal("expected an error")
	}
	if _, _, err := fw.Get(VarMokNew, ShimLockGUID); !errors.Is(err, ErrNotFound) {
		t.Fatal("MokNew left behind")
	}
	// An earlier foreign request is restored, not deleted.
	other := X509SignatureList(testCert(t, "other"), ShimLockGUID)
	fw.vars[fw.key(VarMokNew, ShimLockGUID)] = other
	if _, err := Prepare(fw, der, "usos", nil); err == nil {
		t.Fatal("expected an error")
	}
	if got, _, _ := fw.Get(VarMokNew, ShimLockGUID); !bytes.Equal(got, other) {
		t.Fatal("previous MokNew not restored")
	}
}

func TestPrepareSkipsWhenEnrolled(t *testing.T) {
	der := testCert(t, "usos")
	fw := newFake()
	fw.vars[fw.key(VarMokListRT, ShimLockGUID)] = append(X509SignatureList(testCert(t, "x"), ShimLockGUID), X509SignatureList(der, ShimLockGUID)...)
	fw.vars[fw.key(VarSecureBoot, GlobalVariableGUID)] = []byte{1}
	res, err := Prepare(fw, der, "usos", nil)
	if err != nil || !res.AlreadyEnrolled || len(fw.writes) != 0 {
		t.Fatalf("%+v %v %v", res, err, fw.writes)
	}
	st, _ := Check(fw, der)
	if st.Enrolled != Yes || st.SecureBoot != Yes {
		t.Fatalf("%+v", st)
	}
}

func TestPrepareRejectsLegacyBIOSAndBadInput(t *testing.T) {
	der := testCert(t, "usos")
	fw := newFake()
	fw.uefi = false
	if _, err := Prepare(fw, der, "usos", nil); !errors.Is(err, ErrNotUEFI) {
		t.Fatal(err)
	}
	fw.uefi = true
	if _, err := Prepare(fw, der, "", nil); !errors.Is(err, ErrPasswordEmpty) {
		t.Fatal(err)
	}
	if _, err := Prepare(fw, []byte("not a cert"), "usos", nil); err == nil {
		t.Fatal("accepted a bad certificate")
	}
	if len(fw.writes) != 0 {
		t.Fatal(fw.writes)
	}
}

// The real USOS certificate (when the repository is checked out) round-trips.
func TestReferenceCertificate(t *testing.T) {
	der, err := os.ReadFile(filepath.Join("..", "..", "..", "assets", "secure-boot", "usos-secure-boot.cer"))
	if err != nil {
		t.Skip(err)
	}
	if sum := sha256.Sum256(der); hex.EncodeToString(sum[:]) != "1039d6f0c8cddf1769f13766edaaac4a30daf55986654655f9d41d6ea517d230" {
		t.Skip("reference certificate rotated")
	}
	mokNew, mokAuth, _, err := Request(der, DefaultPassword, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(mokNew) != 44+len(der) || len(mokAuth) != PasswordCryptSize {
		t.Fatal(len(mokNew), len(mokAuth))
	}
}
