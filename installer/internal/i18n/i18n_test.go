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

var pluralSuffix = regexp.MustCompile(`\.(zero|one|two|few|many|other)$`)

// shippedLanguages is the full set of embedded catalogs.
var shippedLanguages = []string{
	"bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it", "lt",
	"lv", "nb", "nl", "pl", "pt-BR", "ro", "ru", "sk", "sl", "sr-Latn", "sv", "tr", "uk",
}
var formatVerb = regexp.MustCompile(`%[-+# 0]*[0-9]*(\.[0-9]+)?[a-zA-Z%]|\{[0-9]\}`)

func TestCatalogsLoad(t *testing.T) {
	if err := LoadError(); err != nil {
		t.Fatal(err)
	}
	got := Languages()
	codes := make([]string, 0, len(got))
	for i, language := range got {
		codes = append(codes, language.Code)
		if language.Name == "" || language.EnglishName == "" {
			t.Errorf("%s: _meta lacks names", language.Code)
		}
		// Only the hand-written catalogs may claim a human translation.
		if human := language.Code == "en" || language.Code == "pl"; language.MachineTranslated == human {
			t.Errorf("%s: machine_translated=%v", language.Code, language.MachineTranslated)
		}
		if i > 0 && FoldName(got[i-1].Name) > FoldName(language.Name) {
			t.Errorf("Languages() not sorted by native name at %s", language.Code)
		}
		if len(language.Code) > 8 {
			t.Errorf("%s: code does not fit lang.bin", language.Code)
		}
	}
	sort.Strings(codes)
	if strings.Join(codes, " ") != strings.Join(shippedLanguages, " ") {
		t.Fatalf("languages %v, want %v", codes, shippedLanguages)
	}
}

func TestLanguageMenuOrder(t *testing.T) {
	var names []string
	for _, language := range Languages() {
		names = append(names, language.Name)
	}
	got := strings.Join(names, ", ")
	// Latin script alphabetically (diacritics folded), then Greek, then Cyrillic.
	for _, pair := range [][2]string{{"Čeština", "Dansk"}, {"Dansk", "Deutsch"}, {"Suomi", "Svenska"}, {"Türkçe", "Ελληνικά"}, {"Ελληνικά", "Български"}} {
		if strings.Index(got, pair[0]) > strings.Index(got, pair[1]) {
			t.Errorf("%s should come before %s: %s", pair[0], pair[1], got)
		}
	}
}

func TestParseCatalogMeta(t *testing.T) {
	catalog, meta, err := ParseCatalogWithMeta([]byte(`{"_meta": {"native_name": "Deutsch", "english_name": "German", "machine_translated": true}, "a": "b"}`))
	if err != nil || meta.NativeName != "Deutsch" || !meta.MachineTranslated || len(catalog) != 1 {
		t.Fatalf("got %v %+v %v", catalog, meta, err)
	}
	for _, input := range []string{`{"_meta": "x"}`, `{"_meta": {"native": "x"}}`} {
		if _, err := ParseCatalog([]byte(input)); err == nil {
			t.Errorf("ParseCatalog(%s) accepted a bad _meta", input)
		}
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
		required := RequiredPluralForms(language.Code)
		for base := range enPlural {
			for _, form := range required {
				if !plural[base][form] {
					t.Errorf("%s: plural %s lacks form %s", language.Code, base, form)
				}
				value := catalog[base+"."+form]
				if verbs(value) != verbs(english[base+".other"]) {
					t.Errorf("%s: %s.%s format verbs %q", language.Code, base, form, verbs(value))
				}
				// A form used for more than one number must print it.
				if !strings.Contains(value, "{count}") && !(form == "one" && OneMeansExactlyOne(language.Code)) {
					t.Errorf("%s: %s.%s lacks {count}", language.Code, base, form)
				}
			}
			for form := range plural[base] {
				if !contains(required, form) {
					t.Errorf("%s: plural %s has form %s the language does not use", language.Code, base, form)
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

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// Every counted message renders without a raw {count} or a fallback to the
// key for every number class of every language.
func TestPluralMessagesRender(t *testing.T) {
	previous := Current()
	defer SetLanguage(previous)
	for _, language := range Languages() {
		SetLanguage(language.Code)
		for _, n := range []int{0, 1, 2, 3, 4, 5, 11, 12, 21, 22, 25, 101, 102, 111} {
			for _, key := range []string{"installer.device.hidden", "installer.installed.found", "installer.mode.detected_hidden"} {
				got := N(key, n)
				if got == key || strings.Contains(got, "{count}") {
					t.Errorf("%s N(%s,%d)=%q", language.Code, key, n, got)
				}
			}
		}
	}
}

// Every language can produce its drive files; lang.bin keeps the code.
func TestDeviceFilesForEveryLanguage(t *testing.T) {
	for _, language := range Languages() {
		files, err := DeviceFiles(language.Code)
		if err != nil {
			t.Errorf("%s: %v", language.Code, err)
			continue
		}
		for _, file := range files {
			if file.Path == BootBlobPath && string(bytes.TrimRight(file.Data[12:20], "\x00")) != language.Code {
				t.Errorf("%s: lang.bin language %q", language.Code, file.Data[12:20])
			}
			if file.Path == SettingsPath {
				if got, ok := ParseSettingsLanguage(file.Data); !ok || Normalize(got) != language.Code {
					t.Errorf("%s: settings language %q", language.Code, got)
				}
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
	cases := map[string]string{"pl": "pl", "pl-PL": "pl", "PL_pl": "pl", "en-US": "en", "": "en", "xx": "en",
		"de-AT": "de", "de-CH": "de", "fr-CA": "fr", "es-MX": "es", "nl-BE": "nl", "sv-FI": "sv", "ro-MD": "ro",
		"pt": "pt-BR", "pt-BR": "pt-BR", "pt_br": "pt-BR", "pt-PT": "pt-BR", "sr": "sr-Latn", "sr-Latn-RS": "sr-Latn",
		"sr-Cyrl": "sr-Latn", "sr-Cyrl-RS": "sr-Latn", "SR-LATN": "sr-Latn", "nb-NO": "nb", "nn": "nb", "nn-NO": "nb",
		"no": "nb", "ja-JP": "en", "zh-Hans-CN": "en"}
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
	windows := map[uint16]string{
		0x0402: "bg", 0x0405: "cs", 0x0406: "da", 0x0407: "de", 0x0c07: "de", 0x0807: "de", 0x0408: "el",
		0x0809: "en", 0x0c0a: "es", 0x080a: "es", 0x0425: "et", 0x040b: "fi", 0x040c: "fr", 0x0c0c: "fr",
		0x041a: "hr", 0x101a: "hr", 0x040e: "hu", 0x0410: "it", 0x0427: "lt", 0x0426: "lv", 0x0414: "nb",
		0x0814: "nb", 0x0413: "nl", 0x0813: "nl", 0x0416: "pt-BR", 0x0816: "pt-BR", 0x0418: "ro", 0x0818: "ro",
		0x0419: "ru", 0x041b: "sk", 0x0424: "sl", 0x241a: "sr-Latn", 0x281a: "sr-Latn", 0x081a: "sr-Latn",
		0x0c1a: "sr-Latn", 0x2c1a: "sr-Latn", 0x301a: "sr-Latn", 0x041d: "sv", 0x081d: "sv", 0x041f: "tr",
		0x0422: "uk", 0x0411: "en", 0x0804: "en", 0x141a: "en", 0: "en",
	}
	for id, want := range windows {
		if got := FromWindowsLangID(id); got != want {
			t.Errorf("0x%04x -> %q want %q", id, got, want)
		}
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
		{"en", 1, "one"}, {"en", 2, "other"}, {"en", 0, "other"}, {"de", 1, "one"}, {"de", 0, "other"}, {"cs", 3, "few"}, {"cs", 5, "other"},
		{"fr", 0, "one"}, {"fr", 1, "one"}, {"fr", 2, "other"}, {"pt-BR", 0, "one"}, {"pt-BR", 2, "other"},
		{"ru", 1, "one"}, {"ru", 21, "one"}, {"ru", 11, "many"}, {"ru", 3, "few"}, {"ru", 13, "many"}, {"ru", 24, "few"}, {"ru", 25, "many"}, {"uk", 0, "many"},
		{"hr", 21, "one"}, {"hr", 11, "other"}, {"hr", 22, "few"}, {"sr-Latn", 5, "other"}, {"sr-Latn", 101, "one"},
		{"sl", 1, "one"}, {"sl", 101, "one"}, {"sl", 2, "two"}, {"sl", 102, "two"}, {"sl", 3, "few"}, {"sl", 104, "few"}, {"sl", 5, "other"}, {"sl", 11, "other"},
		{"ro", 1, "one"}, {"ro", 0, "few"}, {"ro", 2, "few"}, {"ro", 19, "few"}, {"ro", 20, "other"}, {"ro", 101, "few"}, {"ro", 120, "other"},
		{"lt", 1, "one"}, {"lt", 21, "one"}, {"lt", 11, "other"}, {"lt", 2, "few"}, {"lt", 9, "few"}, {"lt", 10, "other"}, {"lt", 12, "other"}, {"lt", 22, "few"},
		{"lv", 0, "zero"}, {"lv", 10, "zero"}, {"lv", 11, "zero"}, {"lv", 1, "one"}, {"lv", 21, "one"}, {"lv", 2, "other"}, {"lv", 22, "other"},
		{"fi", 1, "one"}, {"hu", 2, "other"}}
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
	var polishText strings.Builder
	for key, value := range polish {
		if strings.HasPrefix(key, BootKeyPrefix) {
			polishText.WriteString(value + "\n")
		}
	}
	for key, value := range english {
		// Short English words may legitimately occur inside Polish text
		// ("Utilities/<tool name>/Images"); only whole translated-away
		// strings count.
		if strings.HasPrefix(key, BootKeyPrefix) && value != polish[key] && !strings.Contains(polishText.String(), value) && bytes.Contains(blob, []byte(value)) {
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

// The Zig tables, the XP header and the Zig lang.bin fixture are derived
// from the catalogs; regenerate with `go run ./cmd/usos-i18n-gen -root ..`.
func TestGeneratedFilesAreCurrent(t *testing.T) {
	root := filepath.Join("..", "..", "..")
	zig, err := GenerateZigTable()
	if err != nil {
		t.Fatal(err)
	}
	linux, err := GenerateZigLinuxTable()
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
	for path, want := range map[string][]byte{ZigTablePath: zig, ZigLinuxTablePath: linux, XPHeaderPath: header, ZigFixturePath: fixture} {
		got, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(path)))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(bytes.ReplaceAll(got, []byte("\r\n"), []byte("\n")), want) && !bytes.Equal(got, want) {
			t.Errorf("%s is stale; run go run ./cmd/usos-i18n-gen -root ..", path)
		}
	}
}

// Every boot.* string of every language must be drawable by the boot font
// pack, which tools/usos_font_gen.py derives from these catalogs.
func TestEveryBootStringFitsTheBootFont(t *testing.T) {
	pack, err := os.ReadFile(filepath.Join("..", "..", "..", filepath.FromSlash(BootFontPath)))
	if err != nil {
		t.Fatal(err)
	}
	coverage, err := BootFontCoverage(pack)
	if err != nil {
		t.Fatal(err)
	}
	for _, language := range Languages() {
		gaps, err := BootGlyphGaps(language.Code, coverage)
		if err != nil || len(gaps) != 0 {
			t.Errorf("%s: boot strings need glyphs outside the font pack: %v %v", language.Code, gaps, err)
		}
		for _, r := range language.Name {
			if !coverage[r] {
				t.Errorf("%s: native name %q needs %q", language.Code, language.Name, r)
			}
		}
	}
}

func TestLangCPIOCarriesLangBin(t *testing.T) {
	blob, err := BootBlob("pl")
	if err != nil {
		t.Fatal(err)
	}
	archive := LangCPIO(blob)
	if len(archive)%512 != 0 || !bytes.HasPrefix(archive, []byte("070701")) {
		t.Fatalf("bad newc archive header %q", archive[:6])
	}
	name := []byte("etc/usos/lang.bin\x00")
	at := bytes.Index(archive, name)
	if at < 110 {
		t.Fatal("lang.bin entry missing")
	}
	data := at + len(name)
	for data%4 != 0 {
		data++
	}
	if !bytes.Equal(archive[data:data+len(blob)], blob) || !bytes.Contains(archive, []byte("TRAILER!!!")) {
		t.Fatal("lang.bin payload or trailer missing")
	}
}

func TestMachineTranslatedMarks(t *testing.T) {
	if !MachineTranslatedKey("pl", "boot.menu.title") || MachineTranslatedKey("pl", "installer.common.back") {
		t.Fatal("pl: boot.* must be marked machine-translated, installer.* not")
	}
	if !MachineTranslatedKey("de", "installer.common.back") || MachineTranslatedKey("en", "boot.menu.title") {
		t.Fatal("de must be machine-translated, en not")
	}
}

// The boot header shows boot.language.name; it must be the native name the
// installer's language menu shows.
func TestBootLanguageNameMatchesMeta(t *testing.T) {
	for _, language := range Languages() {
		catalog, _ := Catalog(language.Code)
		if catalog["boot.language.name"] != language.Name {
			t.Errorf("%s: boot.language.name=%q, _meta native_name=%q", language.Code, catalog["boot.language.name"], language.Name)
		}
	}
}
