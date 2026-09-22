package buildinfo

import (
	"strings"
	"testing"
)

func TestParseBuildInfo(t *testing.T) {
	info, err := Parse(strings.NewReader("[build]\nid=B260904-230000-ABCDEF12\nepoch=1788562800\nsource_sha256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"))
	if err != nil {
		t.Fatal(err)
	}
	if !info.Valid() || info.ID != "B260904-230000-ABCDEF12" || info.Epoch != 1788562800 {
		t.Fatalf("unexpected build info: %+v", info)
	}
}

func TestCompareUsesBuildEpoch(t *testing.T) {
	older := Info{ID: "older", Epoch: 10, SourceSHA256: strings.Repeat("a", 64)}
	newer := Info{ID: "newer", Epoch: 11, SourceSHA256: strings.Repeat("b", 64)}
	if Compare(older, newer) >= 0 || Compare(newer, older) <= 0 {
		t.Fatal("build ordering is not based on epoch")
	}
}
