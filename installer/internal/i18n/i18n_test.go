package i18n

import (
	"bytes"
	"encoding/binary"
	"hash/crc32"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"unicode/utf16"
)

var pluralSuffix = regexp.MustCompile(`\.(one|few|many|other)$`)
var formatVerb = regexp.MustCompile(`%[-+# 0]*[0-9]*(\.[0-9]+)?[a-zA-Z%]`)

func TestCatalogsLoad(t *testing.T) {
	if err := LoadError(); err != nil {
		t.Fatal(err)
	}
	if got := Languages(); len(got) < 2 || got[0].Code != Fallback {
		t.Fatalf("Languages()=%v, want en first and at least pl", got)
	}
}

func TestParseCatalogRejectsDuplicatesAndNonStrings(t *testing.T) {
	for _, input := range []string{`{"a":"1","a":"2"}`, `{"a":1}`, `["a"]`, `{"a":"1"} {}`} {
		if _, err := ParseCatalog([]byte(input)); err == nil {
			t.Errorf("ParseCatalog(%s) accepted invalid catalog", input)
		}
	}
}

// splitKeys separates plain keys from counted (plural) base keys.
func splitKeys(catalog map[string]string) (map[string]bool, map[string]map[string]bool) {
	plain := map[string]bool{}
	plural := map[string]map[string]bool{}
	for key := range catalog {
		if m := pluralSuffix.FindStringSubmatch(key); m != nil {
			base := strings.TrimSuffix(key, m[0])
			if plural[base] == nil {
				plural[base] = map[string]bool{}
			}
			plural[base][m[1]] = true
			continue
		}
		plain[key] = true
	}
	return plain, plural
}

func verbs(value string) string {
	found := formatVerb.FindAllString(value, -1)
	sort.Strings(found)
	return strings.Join(found, " ")
}

// Every catalog must translate exactly the English key set, keep the same
// format verbs, and define every plural form its language needs.
func TestEveryLanguageIsComplete(t *testing.T) {
	english, _ := Catalog(Fallback)
	enPlain, enPlural := splitKeys(english)
	for _, language := range Languages() {
		catalog, _ := Catalog(language.Code)
		plain, plural := splitKeys(catalog)
		for key := range enPlain {
			if !plain[key] {
				t.Errorf("%s: missing key %s", language.Code, key)
			} else if verbs(catalog[key]) != verbs(english[key]) {
				t.Errorf("%s: %s format verbs %q, English has %q", language.Code, key, verbs(catalog[key]), verbs(english[key]))
			}
		}
		for key := range plain {
			if !enPlain[key] {
				t.Errorf("%s: key %s does not exist in English", language.Code, key)
			}
		}
		for base := range enPlural {
			for _, form := range RequiredPluralForms(language.Code) {
				if !plural[base][form] {
					t.Errorf("%s: plural %s lacks form %s", language.Code, base, form)
				}
			}
		}
		for base := range plural {
			if enPlural[base] == nil {
				t.Errorf("%s: plural %s does not exist in English", language.Code, base)
			}
		}
	}
}

func TestLookupFallsBackToEnglishThenKey(t *testing.T) {
	if got := TIn("xx", "installer.common.back"); got != "Back" {
		t.Fatalf("unknown language: got %q", got)
	}
	if got := TIn("pl", "installer.common.back"); got != "Wstecz" {
		t.Fatalf("pl: got %q", got)
	}
	if got := TIn("pl", "installer.no.such.key"); got != "installer.no.such.key" {
		t.Fatalf("missing key: got %q", got)
	}
	if got := TIn("en", "installer.common.scan_error", "boom"); got != "Scan error: boom" {
		t.Fatalf("format: got %q", got)
	}
}

func TestNormalizeAndWindowsLanguage(t *testing.T) {
	cases := map[string]string{"pl": "pl", "pl-PL": "pl", "PL_pl": "pl", "en-US": "en", "": "en", "xx": "en"}
	for input, want := range cases {
		if got := Normalize(input); got != want {
			t.Errorf("Normalize(%q)=%q want %q", input, got, want)
		}
	}
	if got := FromWindowsLangID(0x0415); got != "pl" {
		t.Errorf("0x0415 -> %q", got)
	}
	if got := FromWindowsLangID(0x0409); got != "en" {
		t.Errorf("0x0409 -> %q", got)
	}
	// A language without a catalog yet (Hungarian) falls back to English.
	if got := FromWindowsLangID(0x040e); got != "en" {
		t.Errorf("0x040e -> %q", got)
	}
	if got := SystemLanguage(); Normalize(got) != got {
		t.Errorf("SystemLanguage()=%q is not a catalog code", got)
	}
}

func TestPluralForms(t *testing.T) {
	cases := []struct {
		lang string
		n    int
		want string
	}{{"pl", 1, "one"}, {"pl", 2, "few"}, {"pl", 4, "few"}, {"pl", 5, "many"}, {"pl", 12, "many"}, {"pl", 22, "few"}, {"pl", 0, "many"},
		{"en", 1, "one"}, {"en", 2, "other"}, {"cs", 3, "few"}, {"cs", 5, "other"}}
	for _, c := range cases {
		if got := PluralForm(c.lang, c.n); got != c.want {
			t.Errorf("PluralForm(%s,%d)=%s want %s", c.lang, c.n, got, c.want)
		}
	}
	previous := Current()
	defer SetLanguage(previous)
	SetLanguage("pl")
	if got := N("installer.device.hidden", 3); !strings.Contains(got, "na 3 nośnikach") {
		t.Errorf("pl N(3)=%q", got)
	}
	SetLanguage("en")
	if got := N("installer.device.hidden", 1); !strings.Contains(got, "1 drive ") {
		t.Errorf("en N(1)=%q", got)
	}
}

func TestDeviceFilesCarryOnlyTheChosenLanguage(t *testing.T) {
	files, err := DeviceFiles("pl-PL")
	if err != nil {
		t.Fatal(err)
	}
	byPath := map[string][]byte{}
	for _, file := range files {
		byPath[file.Path] = file.Data
	}
	if got, ok := ParseSettingsLanguage(byPath[SettingsPath]); !ok || got != "pl" {
		t.Fatalf("settings language %q %v", got, ok)
	}
	blob := byPath[BootBlobPath]
	if string(blob[:8]) != bootBlobMagic || string(bytes.TrimRight(blob[12:20], "\x00")) != "pl" {
		t.Fatalf("bad boot blob header % x", blob[:bootHeaderSize])
	}
	payload := blob[bootHeaderSize:]
	if binary.LittleEndian.Uint32(blob[20:24]) != uint32(len(payload)) || binary.LittleEndian.Uint32(blob[24:28]) != crc32.ChecksumIEEE(payload) {
		t.Fatal("boot blob length/CRC mismatch")
	}
	english, _ := Catalog("en")
	polish, _ := Catalog("pl")
	for key, value := range english {
		if strings.HasPrefix(key, BootKeyPrefix) && value != polish[key] && bytes.Contains(blob, []byte(value)) {
			t.Errorf("Polish boot blob contains English %s", key)
		}
	}
	xp := byPath[XPHelperPath]
	if xp[0] != 0xff || xp[1] != 0xfe {
		t.Fatal("XP helper INI lacks the UTF-16LE BOM")
	}
	units := make([]uint16, (len(xp)-2)/2)
	for i := range units {
		units[i] = binary.LittleEndian.Uint16(xp[2+2*i:])
	}
	text := string(utf16.Decode(units))
	if !strings.HasPrefix(text, "[xp_pae]\r\nlanguage=pl\r\n") || !strings.Contains(text, "restart_prompt="+polish["xp_pae.restart_prompt"]+"\r\n") {
		t.Fatalf("XP helper INI:\n%s", text)
	}
	if strings.Contains(text, english["xp_pae.restart_prompt"]) {
		t.Fatal("XP helper INI contains the English prompt")
	}
}

// The Zig table, the XP header and the Zig lang.bin fixture are derived from
// the catalogs; regenerate with `go run ./cmd/usos-i18n-gen -root ..`.
func TestGeneratedFilesAreCurrent(t *testing.T) {
	root := filepath.Join("..", "..", "..")
	zig, err := GenerateZigTable()
	if err != nil {
		t.Fatal(err)
	}
	header, err := GenerateXPHeader()
	if err != nil {
		t.Fatal(err)
	}
	fixture, err := BootBlob(ZigFixtureLang)
	if err != nil {
		t.Fatal(err)
	}
	for path, want := range map[string][]byte{ZigTablePath: zig, XPHeaderPath: header, ZigFixturePath: fixture} {
		got, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(path)))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(bytes.ReplaceAll(got, []byte("\r\n"), []byte("\n")), want) && !bytes.Equal(got, want) {
			t.Errorf("%s is stale; run go run ./cmd/usos-i18n-gen -root ..", path)
		}
	}
}

func TestEnglishBootStringsFitTheBootFont(t *testing.T) {
	gaps, err := BootGlyphGaps(Fallback)
	if err != nil || len(gaps) != 0 {
		t.Fatalf("English boot strings need glyphs outside font5x7: %v %v", gaps, err)
	}
}
