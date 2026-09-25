package winhost

import (
	"bytes"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestXPSettingsExampleIsInactiveCRLF(t *testing.T) {
	text := xpSettingsExample.contents
	if !utf8.Valid(text) || bytes.HasPrefix(text, []byte{0xef, 0xbb, 0xbf}) {
		t.Fatal("usos-xp.example.ini must be UTF-8 without BOM")
	}
	if bytes.Count(text, []byte("\n")) != bytes.Count(text, []byte("\r\n")) {
		t.Fatal("usos-xp.example.ini line endings are not CRLF")
	}
	if !containsDataDirectory(xpSettingsDirectory) {
		t.Fatal("usos-xp.example.ini is outside the required DATA directories")
	}
	var keys []string
	for _, line := range strings.Split(strings.TrimRight(string(text), "\r\n"), "\r\n") {
		if line == "" || strings.HasPrefix(line, ";") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok || value != "" {
			t.Fatalf("setting line %q must be key= with an empty value (inactive template)", line)
		}
		keys = append(keys, key)
	}
	// tools/xp_user_settings.sh accepts exactly these keys.
	if got := strings.Join(keys, ","); got != "user,user2,computer,org,key,timezone,password" {
		t.Fatalf("keys = %s", got)
	}
}
