package i18n

import "testing"

// Update and repair rewrite usos-settings.ini; hand-added boot menu keys
// (wheel_invert, touch_rotation) and other sections must survive.
func TestMergeSettingsKeepsOtherKeys(t *testing.T) {
	existing := "[ui]\r\nlanguage=de\r\nwheel_invert=1\r\n; note\r\ntouch_rotation=270\r\n[extra]\r\nkey=value\r\n"
	got := string(MergeSettingsINI([]byte(existing), "pl"))
	want := "[ui]\r\nlanguage=pl\r\nwheel_invert=1\r\n; note\r\ntouch_rotation=270\r\n[extra]\r\nkey=value\r\n"
	if got != want {
		t.Fatalf("merge:\n got %q\nwant %q", got, want)
	}
	if lang, ok := ParseSettingsLanguage([]byte(got)); !ok || lang != "pl" {
		t.Fatalf("language after merge = %q %v", lang, ok)
	}
}

func TestMergeSettingsAddsLanguage(t *testing.T) {
	cases := map[string]string{
		"":                                 "[ui]\r\nlanguage=pl\r\n",
		"wheel_invert=1\n":                 "[ui]\r\nlanguage=pl\r\nwheel_invert=1\r\n",
		"[ui]\nwheel_invert=1\n[x]\nk=v\n": "[ui]\r\nwheel_invert=1\r\nlanguage=pl\r\n[x]\r\nk=v\r\n",
		"[x]\nlanguage=en\n":               "[ui]\r\nlanguage=pl\r\n[x]\r\nlanguage=en\r\n",
	}
	for input, want := range cases {
		if got := string(MergeSettingsINI([]byte(input), "pl")); got != want {
			t.Errorf("merge(%q):\n got %q\nwant %q", input, got, want)
		}
	}
}
