// Package i18n is the single source of truth for user-visible USOS strings.
//
// Catalogs live in locales/<code>.json (flat, stable keys). The installer
// embeds every catalog; the USOS drive receives only the chosen language (see
// device_files.go). Key namespaces: installer.* (this program), boot.* (Zig
// boot UI, English built into the EFI), xp_pae.* (Windows XP PAE helper,
// English built into pae.exe).
package i18n

import (
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"path"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// Fallback is the language used for missing keys and unknown languages. It is
// also the language compiled into the boot EFI and the XP helper.
const Fallback = "en"

//go:embed locales/*.json
var localeFiles embed.FS

// MetaKey is the per-catalog metadata object (not a translatable string).
const MetaKey = "_meta"

// Meta is a catalog's "_meta" entry.
type Meta struct {
	NativeName        string `json:"native_name"`
	EnglishName       string `json:"english_name"`
	MachineTranslated bool   `json:"machine_translated"`
}

// Language describes one embedded catalog. Name is the native name shown in
// the language menu.
type Language struct {
	Code              string
	Name              string
	EnglishName       string
	MachineTranslated bool
}

var (
	loadOnce sync.Once
	catalogs map[string]map[string]string
	metas    map[string]Meta
	loadErr  error

	currentMu sync.RWMutex
	current   = Fallback
)

func load() {
	catalogs = map[string]map[string]string{}
	metas = map[string]Meta{}
	entries, err := localeFiles.ReadDir("locales")
	if err != nil {
		loadErr = err
		return
	}
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasSuffix(name, ".json") {
			continue
		}
		data, err := localeFiles.ReadFile(path.Join("locales", name))
		if err != nil {
			loadErr = err
			return
		}
		catalog, meta, err := ParseCatalogWithMeta(data)
		if err != nil {
			loadErr = fmt.Errorf("locale %s: %w", name, err)
			return
		}
		if meta.NativeName == "" || meta.EnglishName == "" {
			loadErr = fmt.Errorf("locale %s: %s needs native_name and english_name", name, MetaKey)
			return
		}
		code := strings.TrimSuffix(name, ".json")
		catalogs[code] = catalog
		metas[code] = meta
	}
	if _, ok := catalogs[Fallback]; !ok && loadErr == nil {
		loadErr = fmt.Errorf("fallback locale %s.json missing", Fallback)
	}
}

// ParseCatalog decodes a flat JSON object of string values and rejects
// duplicate keys, which encoding/json would otherwise silently merge. The
// optional "_meta" object is validated and left out of the result.
func ParseCatalog(data []byte) (map[string]string, error) {
	catalog, _, err := ParseCatalogWithMeta(data)
	return catalog, err
}

// ParseCatalogWithMeta is ParseCatalog that also returns the "_meta" entry.
func ParseCatalogWithMeta(data []byte) (map[string]string, Meta, error) {
	var meta Meta
	catalog, err := parseCatalog(data, &meta)
	return catalog, meta, err
}

func parseCatalog(data []byte, meta *Meta) (map[string]string, error) {
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	token, err := decoder.Token()
	if err != nil {
		return nil, err
	}
	if delim, ok := token.(json.Delim); !ok || delim != '{' {
		return nil, fmt.Errorf("catalog must be a JSON object")
	}
	result := map[string]string{}
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return nil, err
		}
		key, ok := token.(string)
		if !ok || strings.TrimSpace(key) == "" {
			return nil, fmt.Errorf("invalid key %v", token)
		}
		if key == MetaKey {
			var raw json.RawMessage
			if err := decoder.Decode(&raw); err != nil {
				return nil, fmt.Errorf("%s: %w", MetaKey, err)
			}
			strict := json.NewDecoder(strings.NewReader(string(raw)))
			strict.DisallowUnknownFields()
			if err := strict.Decode(meta); err != nil {
				return nil, fmt.Errorf("%s: %w", MetaKey, err)
			}
			continue
		}
		var value string
		if err := decoder.Decode(&value); err != nil {
			return nil, fmt.Errorf("key %q: %w", key, err)
		}
		if _, dup := result[key]; dup {
			return nil, fmt.Errorf("duplicate key %q", key)
		}
		result[key] = value
	}
	if _, err := decoder.Token(); err != nil {
		return nil, err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return nil, fmt.Errorf("trailing data after catalog object")
	}
	return result, nil
}

func ensureLoaded() error {
	loadOnce.Do(load)
	return loadErr
}

// LoadError reports a broken embedded catalog (checked by tests).
func LoadError() error { return ensureLoaded() }

// Catalog returns a copy of one embedded catalog.
func Catalog(code string) (map[string]string, bool) {
	if ensureLoaded() != nil {
		return nil, false
	}
	catalog, ok := catalogs[code]
	if !ok {
		return nil, false
	}
	copied := make(map[string]string, len(catalog))
	for k, v := range catalog {
		copied[k] = v
	}
	return copied, true
}

// Languages lists embedded catalogs in language-menu order: by native name
// (see nameSortKey).
func Languages() []Language {
	if ensureLoaded() != nil {
		return []Language{{Code: Fallback, Name: "English", EnglishName: "English"}}
	}
	result := make([]Language, 0, len(catalogs))
	for code := range catalogs {
		meta := metas[code]
		result = append(result, Language{Code: code, Name: meta.NativeName, EnglishName: meta.EnglishName, MachineTranslated: meta.MachineTranslated})
	}
	sort.Slice(result, func(i, j int) bool {
		ki, kj := nameSortKey(result[i].Name), nameSortKey(result[j].Name)
		if ki != kj {
			return ki < kj
		}
		return result[i].Code < result[j].Code
	})
	return result
}

// nameSortKey orders native names alphabetically with diacritics folded
// ("Čeština" next to "Dansk"), Latin script first, then Greek, then Cyrillic
// (their code points already sort in that order).
func nameSortKey(name string) string { return FoldName(name) }

// FoldName lower-cases s and folds Latin letters with diacritics to their
// base letter, for sorting and type-to-jump in the language menu.
func FoldName(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if base, ok := latinBase[r]; ok {
			r = base
		}
		b.WriteRune(r)
	}
	return b.String()
}

var latinBase = map[rune]rune{
	'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'ă': 'a', 'ą': 'a', 'ā': 'a', 'æ': 'a',
	'č': 'c', 'ć': 'c', 'ç': 'c', 'ď': 'd', 'đ': 'd', 'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'ě': 'e', 'ę': 'e', 'ē': 'e',
	'ģ': 'g', 'ğ': 'g', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i', 'ı': 'i', 'ķ': 'k', 'ľ': 'l', 'ĺ': 'l', 'ł': 'l', 'ļ': 'l',
	'ň': 'n', 'ń': 'n', 'ñ': 'n', 'ņ': 'n', 'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ő': 'o', 'ø': 'o',
	'ř': 'r', 'š': 's', 'ś': 's', 'ș': 's', 'ş': 's', 'ť': 't', 'ț': 't',
	'ú': 'u', 'ů': 'u', 'ü': 'u', 'ű': 'u', 'ū': 'u', 'ý': 'y', 'ž': 'z', 'ź': 'z', 'ż': 'z',
}

// languageAliases maps BCP 47 tags (lower case) that have no catalog of their
// own to the closest embedded one.
var languageAliases = map[string]string{
	"pt":      "pt-BR",
	"pt-pt":   "pt-BR",
	"sr":      "sr-Latn",
	"sr-cyrl": "sr-Latn",
	"no":      "nb",
	"nn":      "nb",
}

// Normalize maps a BCP 47 / POSIX style tag ("pl", "pl-PL", "PL_pl",
// "sr-Cyrl-RS", "pt-PT", "nn-NO") to an embedded catalog code, or to Fallback
// when no catalog matches. Subtags are dropped from the right until a
// catalog or an alias matches.
func Normalize(code string) string {
	tag := strings.ToLower(strings.ReplaceAll(strings.TrimSpace(code), "_", "-"))
	if ensureLoaded() != nil {
		return Fallback
	}
	for tag != "" {
		for c := range catalogs {
			if strings.ToLower(c) == tag {
				return c
			}
		}
		if alias, ok := languageAliases[tag]; ok {
			if _, ok := catalogs[alias]; ok {
				return alias
			}
		}
		i := strings.LastIndex(tag, "-")
		if i < 0 {
			break
		}
		tag = tag[:i]
	}
	return Fallback
}

// SetLanguage selects the UI language and returns the effective code.
func SetLanguage(code string) string {
	code = Normalize(code)
	currentMu.Lock()
	current = code
	currentMu.Unlock()
	return code
}

// Current returns the selected language code.
func Current() string {
	currentMu.RLock()
	defer currentMu.RUnlock()
	return current
}

// Lookup resolves key in lang, falling back to English.
func Lookup(lang, key string) (string, bool) {
	if ensureLoaded() != nil {
		return "", false
	}
	if value, ok := catalogs[lang][key]; ok {
		return value, true
	}
	value, ok := catalogs[Fallback][key]
	return value, ok
}

// T formats key in the current language. A key missing from every catalog
// renders as the key itself so the gap is visible instead of blank.
func T(key string, args ...any) string {
	return TIn(Current(), key, args...)
}

// TIn is T for an explicit language.
func TIn(lang, key string, args ...any) string {
	value, ok := Lookup(lang, key)
	if !ok {
		return key
	}
	if len(args) == 0 {
		return value
	}
	return fmt.Sprintf(value, args...)
}

// N formats a counted message. Forms are stored as key.one / key.few /
// key.many / key.other; {count} inside a form is replaced by n.
func N(key string, n int, args ...any) string {
	if ensureLoaded() != nil {
		return key
	}
	lang := Current()
	form := PluralForm(lang, n)
	value, ok := catalogs[lang][key+"."+form]
	if !ok {
		value, ok = catalogs[lang][key+".other"]
	}
	if !ok {
		value, ok = catalogs[Fallback][key+"."+PluralForm(Fallback, n)]
	}
	if !ok {
		value, ok = catalogs[Fallback][key+".other"]
	}
	if !ok {
		return key
	}
	value = strings.ReplaceAll(value, "{count}", strconv.Itoa(n))
	if len(args) == 0 {
		return value
	}
	return fmt.Sprintf(value, args...)
}

// baseLanguage strips region/script subtags ("sr-Latn" -> "sr").
func baseLanguage(lang string) string {
	if i := strings.IndexAny(lang, "-_"); i >= 0 {
		lang = lang[:i]
	}
	return strings.ToLower(lang)
}

// PluralForm returns the CLDR cardinal category (integers only) used by the
// catalogs.
func PluralForm(lang string, n int) string {
	if n < 0 {
		n = -n
	}
	n10, n100 := n%10, n%100
	switch baseLanguage(lang) {
	case "pl":
		if n == 1 {
			return "one"
		}
		if n10 >= 2 && n10 <= 4 && (n100 < 12 || n100 > 14) {
			return "few"
		}
		return "many"
	case "ru", "uk":
		if n10 == 1 && n100 != 11 {
			return "one"
		}
		if n10 >= 2 && n10 <= 4 && (n100 < 12 || n100 > 14) {
			return "few"
		}
		return "many"
	case "hr", "sr", "bs":
		if n10 == 1 && n100 != 11 {
			return "one"
		}
		if n10 >= 2 && n10 <= 4 && (n100 < 12 || n100 > 14) {
			return "few"
		}
		return "other"
	case "cs", "sk":
		if n == 1 {
			return "one"
		}
		if n >= 2 && n <= 4 {
			return "few"
		}
		return "other"
	case "sl":
		switch n100 {
		case 1:
			return "one"
		case 2:
			return "two"
		case 3, 4:
			return "few"
		}
		return "other"
	case "ro":
		if n == 1 {
			return "one"
		}
		if n == 0 || (n100 >= 1 && n100 <= 19) {
			return "few"
		}
		return "other"
	case "lt":
		if n100 >= 11 && n100 <= 19 {
			return "other"
		}
		if n10 == 1 {
			return "one"
		}
		if n10 >= 2 {
			return "few"
		}
		return "other"
	case "lv":
		if n10 == 0 || (n100 >= 11 && n100 <= 19) {
			return "zero"
		}
		if n10 == 1 {
			return "one"
		}
		return "other"
	case "fr", "pt":
		if n <= 1 {
			return "one"
		}
		return "other"
	default:
		if n == 1 {
			return "one"
		}
		return "other"
	}
}

// RequiredPluralForms lists the forms every counted key must define in lang.
func RequiredPluralForms(lang string) []string {
	switch baseLanguage(lang) {
	case "pl", "ru", "uk":
		return []string{"one", "few", "many"}
	case "cs", "sk", "hr", "sr", "bs", "ro", "lt":
		return []string{"one", "few", "other"}
	case "sl":
		return []string{"one", "two", "few", "other"}
	case "lv":
		return []string{"zero", "one", "other"}
	default:
		return []string{"one", "other"}
	}
}

// OneMeansExactlyOne reports whether lang's "one" category contains only
// n == 1, so its .one form may omit {count} (e.g. "this drive").
func OneMeansExactlyOne(lang string) bool {
	for n := 0; n <= 1000; n++ {
		if n != 1 && PluralForm(lang, n) == "one" {
			return false
		}
	}
	return true
}
