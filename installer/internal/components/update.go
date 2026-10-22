package components

import (
	"fmt"
	"strings"
)

// ParseComponentSelection decodes the -components list of
// usos-physical-update ("xp,winpe,winpe-x86"): every token names one
// component of the installer's Components step, in the order given.
// "xp" is the XP package for the UI language, exactly the package the
// Components step preselects (PreferredXP); "xp-pl"/"xp-en" pin the language.
// An empty list (no -components) is the report-only default and is not an
// error.
func ParseComponentSelection(text, uiLanguage string) ([]ID, error) {
	var ids []ID
	seen := map[ID]bool{}
	for _, token := range strings.Split(text, ",") {
		token = strings.ToLower(strings.TrimSpace(token))
		if token == "" {
			continue
		}
		var id ID
		switch token {
		case "xp":
			id = PreferredXP(uiLanguage)
		case "xp-pl":
			id = XPPL
		case "xp-en":
			id = XPEN
		case "winpe", "winpe-x64":
			id = WinPE
		case "winpe-x86":
			id = WinPEX86
		case "win7-net-intel", "net-intel":
			id = Win7NetIntel
		default:
			return nil, fmt.Errorf("unknown component %q (known: xp, xp-pl, xp-en, winpe, winpe-x86, win7-net-intel)", token)
		}
		if !seen[id] {
			seen[id] = true
			ids = append(ids, id)
		}
	}
	return ids, nil
}
