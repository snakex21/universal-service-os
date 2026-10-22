package components

import "testing"

func TestParseComponentSelection(t *testing.T) {
	cases := []struct {
		text, language string
		want           []ID
	}{
		{"", "pl", nil},
		{"xp", "pl", []ID{XPPL}},
		{"xp", "en", []ID{XPEN}},
		{"xp-pl", "en", []ID{XPPL}},
		{"xp-en", "pl", []ID{XPEN}},
		{"winpe", "pl", []ID{WinPE}},
		{"winpe-x64", "pl", []ID{WinPE}},
		{"winpe-x86", "pl", []ID{WinPEX86}},
		{"xp,winpe,winpe-x86", "pl", []ID{XPPL, WinPE, WinPEX86}},
		{" xp , XP ", "pl", []ID{XPPL}},
	}
	for _, c := range cases {
		got, err := ParseComponentSelection(c.text, c.language)
		if err != nil {
			t.Fatalf("%q/%s: %v", c.text, c.language, err)
		}
		if len(got) != len(c.want) {
			t.Fatalf("%q/%s: got %v want %v", c.text, c.language, got, c.want)
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Fatalf("%q/%s: got %v want %v", c.text, c.language, got, c.want)
			}
		}
	}
}

func TestParseComponentSelectionUnknown(t *testing.T) {
	if _, err := ParseComponentSelection("xp,bogus", "pl"); err == nil {
		t.Fatal("unknown component accepted")
	}
	if _, err := ParseComponentSelection("legacy-ms", "pl"); err == nil {
		t.Fatal("a component the physical update does not support was accepted")
	}
}
