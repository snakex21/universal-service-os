package install

import (
	"errors"
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/winmedia"
)

func TestClassifyWin7TargetForMedia(t *testing.T) {
	tests := []struct {
		name     string
		media    winmedia.Media
		firmware string
		want     Win7TargetKind
		wantErr  error
	}{
		{
			name:     "win7 pe7 x64 na uefi = modern",
			media:    winmedia.Media{Class: winmedia.ClassWin7PE7, Arch: winmedia.ArchX64},
			firmware: "uefi",
			want:     Win7UEFIX64Modern,
		},
		{
			name:     "win7 pe10 x64 na uefi = modern",
			media:    winmedia.Media{Class: winmedia.ClassWin7PE10, Arch: winmedia.ArchX64},
			firmware: "UEFI",
			want:     Win7UEFIX64Modern,
		},
		{
			name:     "win7 x64 na bios = vanilla",
			media:    winmedia.Media{Class: winmedia.ClassWin7PE7, Arch: winmedia.ArchX64},
			firmware: "bios",
			want:     Win7BIOSVanilla,
		},
		{
			name:     "win7 x86 na uefi = vanilla",
			media:    winmedia.Media{Class: winmedia.ClassWin7PE7, Arch: winmedia.ArchX86},
			firmware: "uefi",
			want:     Win7BIOSVanilla,
		},
		{
			name:     "nosnik win10 odrzucony",
			media:    winmedia.Media{Class: winmedia.ClassWin10, Arch: winmedia.ArchX64},
			firmware: "uefi",
			wantErr:  ErrMediaNotWindows7,
		},
		{
			name:     "nosnik nierozpoznany odrzucony",
			media:    winmedia.Media{Class: winmedia.ClassUnknown, Arch: winmedia.ArchUnknown},
			firmware: "uefi",
			wantErr:  ErrMediaNotWindows7,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ClassifyWin7TargetForMedia(tc.media, tc.firmware)
			if tc.wantErr != nil {
				if !errors.Is(err, tc.wantErr) {
					t.Fatalf("err=%v, want %v", err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("err=%v, want nil", err)
			}
			if got != tc.want {
				t.Fatalf("kind=%d, want %d", got, tc.want)
			}
		})
	}
}

// ClassifyWin7Target (stringi) i ClassifyWin7TargetForMedia (winmedia)
// musza dawac ten sam wynik: jedna tabela decyzyjna, dwa wejscia.
func TestStringAndMediaClassifiersAgree(t *testing.T) {
	tests := []struct {
		arch  string
		mArch int
	}{
		{"x64", winmedia.ArchX64},
		{"amd64", winmedia.ArchX64},
		{"x86", winmedia.ArchX86},
		{"arm64", winmedia.ArchARM64},
		{"dziwne", winmedia.ArchUnknown},
	}
	for _, tc := range tests {
		for _, firmware := range []string{"uefi", "gpt", "bios", "csm", ""} {
			t.Run(tc.arch+"/"+firmware, func(t *testing.T) {
				fromString := ClassifyWin7Target(tc.arch, firmware)
				fromMedia, err := ClassifyWin7TargetForMedia(
					winmedia.Media{Class: winmedia.ClassWin7PE7, Arch: tc.mArch}, firmware)
				if err != nil {
					t.Fatalf("err=%v", err)
				}
				if fromString != fromMedia {
					t.Fatalf("string=%d media=%d: dwie rozne tabele decyzyjne", fromString, fromMedia)
				}
			})
		}
	}
}

func TestIsWin7Media(t *testing.T) {
	tests := []struct {
		class winmedia.Class
		want  bool
	}{
		{winmedia.ClassWin7PE7, true},
		{winmedia.ClassWin7PE10, true},
		{winmedia.ClassWin10, false},
		{winmedia.ClassUnknown, false},
	}
	for _, tc := range tests {
		t.Run(string(tc.class), func(t *testing.T) {
			if got := IsWin7Media(tc.class); got != tc.want {
				t.Fatalf("IsWin7Media(%s)=%t, want %t", tc.class, got, tc.want)
			}
		})
	}
}
