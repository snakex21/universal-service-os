package efisign

import (
	"bytes"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/snakex21/universal-service-os/installer/internal/portable"
)

// TestMain points %APPDATA% at a temp folder for the whole package, so no
// test can read, copy or change the real %APPDATA%\USOS\signing key.
func TestMain(m *testing.M) {
	tmp, err := os.MkdirTemp("", "efisign-appdata-")
	if err != nil {
		panic(err)
	}
	os.Setenv("APPDATA", tmp)
	os.Setenv("XDG_CONFIG_HOME", tmp)
	os.Setenv("USOS_SIGNING_DIR", "")
	code := m.Run()
	os.RemoveAll(tmp)
	os.Exit(code)
}

func testPair(t *testing.T) KeyPair {
	t.Helper()
	pair, err := GenerateKeyPair("USOS custody test", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return pair
}

func captureNotices(t *testing.T) *[]string {
	t.Helper()
	var lines []string
	saved := KeyNotice
	KeyNotice = func(l string) { lines = append(lines, l) }
	t.Cleanup(func() { KeyNotice = saved })
	return &lines
}

func TestDefaultKeyDirIsPortableSigningAndCopiesLegacyKeyOnce(t *testing.T) {
	appdata, _ := os.UserConfigDir()
	legacy := filepath.Join(appdata, "USOS", "signing")
	if err := WriteKeyPair(legacy, testPair(t)); err != nil {
		t.Fatal(err)
	}
	keyBefore, _ := os.ReadFile(filepath.Join(legacy, KeyFileName))
	notices := captureNotices(t)

	dir, err := DefaultKeyDir()
	if err != nil {
		t.Fatal(err)
	}
	data, err := portable.DataDir()
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(data, "signing"); dir != want {
		t.Fatalf("key dir %s != %s", dir, want)
	}
	if rel, err := filepath.Rel(appdata, dir); err == nil && !strings.HasPrefix(rel, "..") {
		t.Fatalf("key dir %s is inside %%APPDATA%%", dir)
	}
	copied, err := os.ReadFile(filepath.Join(dir, KeyFileName))
	if err != nil || !bytes.Equal(copied, keyBefore) {
		t.Fatalf("key not copied byte for byte: %v", err)
	}
	if _, err := LoadKeyPair(dir); err != nil {
		t.Fatal(err)
	}
	// Original untouched.
	if after, _ := os.ReadFile(filepath.Join(legacy, KeyFileName)); !bytes.Equal(after, keyBefore) {
		t.Fatal("legacy key changed")
	}
	if len(*notices) == 0 {
		t.Fatal("copy was not reported")
	}
	assertNoKeyInNotices(t, *notices, keyBefore)

	// Second call: nothing copied again.
	*notices = nil
	if _, err := DefaultKeyDir(); err != nil {
		t.Fatal(err)
	}
	if len(*notices) != 0 {
		t.Fatalf("copied again: %v", *notices)
	}
}

func TestMigrateLegacyKeyKeepsDifferentPortableKey(t *testing.T) {
	legacy, dir := t.TempDir(), t.TempDir()
	if err := WriteKeyPair(legacy, testPair(t)); err != nil {
		t.Fatal(err)
	}
	if err := WriteKeyPair(dir, testPair(t)); err != nil {
		t.Fatal(err)
	}
	mine, _ := os.ReadFile(filepath.Join(dir, KeyFileName))
	old, _ := os.ReadFile(filepath.Join(legacy, KeyFileName))
	notices := captureNotices(t)
	if err := MigrateLegacyKey(legacy, dir); err != nil {
		t.Fatal(err)
	}
	if now, _ := os.ReadFile(filepath.Join(dir, KeyFileName)); !bytes.Equal(now, mine) {
		t.Fatal("portable key overwritten")
	}
	if now, _ := os.ReadFile(filepath.Join(legacy, KeyFileName)); !bytes.Equal(now, old) {
		t.Fatal("legacy key changed")
	}
	if len(*notices) == 0 || !strings.Contains((*notices)[0], "differs") {
		t.Fatalf("mismatch not reported: %v", *notices)
	}
	assertNoKeyInNotices(t, *notices, mine)
	assertNoKeyInNotices(t, *notices, old)
}

func TestMigrateLegacyKeyWithoutLegacyKeyDoesNothing(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "signing")
	if err := MigrateLegacyKey(filepath.Join(t.TempDir(), "none"), dir); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); err == nil {
		t.Fatal("empty signing folder created")
	}
}

func assertNoKeyInNotices(t *testing.T, lines []string, keyPEM []byte) {
	t.Helper()
	body := strings.TrimSpace(string(keyPEM))
	body = strings.TrimPrefix(body, "-----BEGIN PRIVATE KEY-----")
	body = strings.TrimSuffix(body, "-----END PRIVATE KEY-----")
	chunks := strings.Fields(body)
	for _, l := range lines {
		if strings.Contains(l, "PRIVATE KEY") {
			t.Fatalf("notice carries key material: %q", l)
		}
		for _, c := range chunks {
			if len(c) >= 16 && strings.Contains(l, c) {
				t.Fatalf("notice carries key material: %q", l)
			}
		}
	}
}

// TestSigningKeyStaysInSigningTools: only the signing tool and this package
// know the key; installer deploy/update/repair code (which writes USOS
// drives and images) never imports efisign or names the key file, so it
// cannot copy data\signing anywhere.
func TestSigningKeyStaysInSigningTools(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	allowed := []string{filepath.Join("internal", "efisign"), filepath.Join("cmd", "usos-efisign")}
	needles := []string{`installer/internal/efisign"`, KeyFileName, `"signing"`, `portable.SigningDirName`}
	err = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if name := d.Name(); name == "data" || strings.HasPrefix(name, ".") {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		rel, _ := filepath.Rel(root, path)
		for _, a := range allowed {
			if strings.HasPrefix(rel, a+string(filepath.Separator)) {
				return nil
			}
		}
		switch rel {
		case filepath.Join("internal", "portable", "portable.go"), // defines SigningDirName, skips it in the generic copy
			filepath.Join("cmd", "usos-payload-pack", "payload_policy.go"): // refuses key material in payloads
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for _, n := range needles {
			if bytes.Contains(b, []byte(n)) {
				t.Errorf("%s references %s; the signing key must stay in internal/efisign and cmd/usos-efisign", rel, n)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
