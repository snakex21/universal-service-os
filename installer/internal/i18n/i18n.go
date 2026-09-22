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

// Language describes one embedded catalog.
type Language struct {
	Code string
	Name string
}

var (
	loadOnce sync.Once
	catalogs map[string]map[string]string
	loadErr  error

	currentMu sync.RWMutex
	current   = Fallback
)

func load() {
	catalogs = map[string]map[string]string{}
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
		catalog, err := ParseCatalog(data)
		if err != nil {
			loadErr = fmt.Errorf("locale %s: %w", name, err)
			return
		}
		catalogs[strings.TrimSuffix(name, ".json")] = catalog
	}
	if _, ok := catalogs[Fallback]; !ok && loadErr == nil {
		loadErr = fmt.Errorf("fallback locale %s.json missing", Fallback)
	}
}

// ParseCatalog decodes a flat JSON object of string values and rejects
// duplicate keys, which encoding/json would otherwise silently merge.
func ParseCatalog(data []byte) (map[string]string, error) {
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

// Languages lists embedded catalogs, fallback first, then by code.
func Languages() []Language {
	if ensureLoaded() != nil {
		return []Language{{Code: Fallback, Name: "English"}}
	}
	result := make([]Language, 0, len(catalogs))
	for code, catalog := range catalogs {
		name := catalog["language.name"]
		if name == "" {
			name = code
		}
		result = append(result, Language{Code: code, Name: name})
	}
	sort.Slice(result, func(i, j int) bool {
		if (result[i].Code == Fallback) != (result[j].Code == Fallback) {
			return result[i].Code == Fallback
		}
		return result[i].Code < result[j].Code
	})
	return result
}

// Normalize maps "pl", "pl-PL", "PL_pl" to an embedded catalog code, or to
// Fallback when no catalog matches.
func Normalize(code string) string {
	code = strings.ToLower(strings.TrimSpace(code))
	if i := strings.IndexAny(code, "-_"); i >= 0 {
		code = code[:i]
	}
	if ensureLoaded() == nil {
		if _, ok := catalogs[code]; ok {
			return code
		}
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

// PluralForm returns the CLDR cardinal category used by the catalogs.
func PluralForm(lang string, n int) string {
	if n < 0 {
		n = -n
	}
	switch lang {
	case "pl":
		if n == 1 {
			return "one"
		}
		if n%10 >= 2 && n%10 <= 4 && (n%100 < 12 || n%100 > 14) {
			return "few"
		}
		return "many"
	case "cs", "sk":
		if n == 1 {
			return "one"
		}
		if n >= 2 && n <= 4 {
			return "few"
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
	switch lang {
	case "pl":
		return []string{"one", "few", "many"}
	case "cs", "sk":
		return []string{"one", "few", "other"}
	default:
		return []string{"one", "other"}
	}
}
