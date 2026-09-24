package winhost

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestDataGuidesCoverTopLevelUserAreas(t *testing.T) {
	want := map[string]bool{
		filepath.Join("Systems", "README.txt"):   false,
		filepath.Join("Utilities", "README.txt"): false,
		filepath.Join("Programs", "README.txt"):  false,
		filepath.Join("Drivers", "README.txt"):   false,
	}
	for _, guide := range dataGuides {
		if len(guide.contents) == 0 {
			t.Fatalf("DATA guide %q is empty", guide.relativePath)
		}
		if _, ok := want[guide.relativePath]; ok {
			want[guide.relativePath] = true
		}
	}
	for path, found := range want {
		if !found {
			t.Fatalf("missing DATA guide %q", path)
		}
	}
}

func TestDataGuidesTotalBytesMatchesContents(t *testing.T) {
	var want uint64
	for _, guide := range dataGuides {
		want += uint64(len(guide.contents))
	}
	if got := dataGuidesTotalBytes(); got != want {
		t.Fatalf("guide bytes=%d, want %d", got, want)
	}
}

func TestDriversGuideIsBilingualCRLF(t *testing.T) {
	text := driversGuide.contents
	if !utf8.Valid(text) {
		t.Fatal("Drivers README is not valid UTF-8")
	}
	if bytes.Count(text, []byte("\n")) != bytes.Count(text, []byte("\r\n")) || bytes.Contains(text, []byte("\r\r")) {
		t.Fatal("Drivers README line endings are not CRLF")
	}
	if !containsDataDirectory(filepath.Dir(driversGuide.relativePath)) {
		t.Fatal("Drivers README is outside the required DATA directories")
	}
	s := string(text)
	pl, en := strings.Index(s, "=== POLSKI ==="), strings.Index(s, "=== ENGLISH ===")
	if pl < 0 || en < pl {
		t.Fatal("Drivers README must have the Polish part first, then English")
	}
	for _, part := range []string{s[pl:en], s[en:]} {
		for _, want := range []string{`Drivers\UEFI\`, "driver.ini", "[match]", "Secure Boot", "drivers.txt", `Storage\`, `USB\`, `Other\`, "$WinPEDriver$", "txtsetup.oem", ".cat"} {
			if !strings.Contains(part, want) {
				t.Errorf("Drivers README part %.20q lacks %q", part, want)
			}
		}
	}
}
