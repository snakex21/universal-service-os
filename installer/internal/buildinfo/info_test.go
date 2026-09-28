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

func TestParseVersionAndDisplay(t *testing.T) {
	info, err := Parse(strings.NewReader("[build]\nid=B260928-120000-ABCDEF12\nversion=1.0.0\nepoch=1788562800\nsource_sha256=" + strings.Repeat("c", 64) + "\n"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Version != "1.0.0" || info.Display() != "1.0.0 (B260928-120000-ABCDEF12)" {
		t.Fatalf("unexpected version display: %+v %q", info, info.Display())
	}
	legacy := Info{ID: "B260901-000000-00000000", Epoch: 1, SourceSHA256: strings.Repeat("d", 64)}
	if legacy.Display() != "B260901-000000-00000000" {
		t.Fatalf("media without a version must show the bare build ID, got %q", legacy.Display())
	}
}
