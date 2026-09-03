package winhost

import (
	"path/filepath"
	"testing"
)

func TestDataGuidesCoverTopLevelUserAreas(t *testing.T) {
	want := map[string]bool{
		filepath.Join("Systems", "README.txt"):   false,
		filepath.Join("Utilities", "README.txt"): false,
		filepath.Join("Programs", "README.txt"):  false,
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
