package winmedia

import (
	"bytes"
	"encoding/binary"
	"errors"
	"strconv"
	"testing"
	"unicode/utf16"
)

// wimBlueprint opisuje syntetyczny plik WIM budowany w pamieci na potrzeby
// testow: zaden test nie wymaga prawdziwego ISO ani DISM.
type wimBlueprint struct {
	// badMagic psuje sygnature MSWIM.
	badMagic bool
	// truncateTo obcina gotowy bufor do podanej dlugosci (0 = bez obciecia).
	truncateTo int
	// noXML zeruje naglowek zasobu XML_DATA.
	noXML bool
	// imageCount to wartosc pola ImageCount w naglowku.
	imageCount uint32
	// xml to dokument <WIM> zapisywany jako UTF-16LE z BOM.
	xml string
}

// buildWIM sklada minimalny plik WIM: 208-bajtowy naglowek + nieskompresowany
// zasob XML_DATA bezposrednio za naglowkiem.
func buildWIM(b wimBlueprint) []byte {
	header := make([]byte, wimHeaderSize)
	copy(header, wimMagic[:])
	if b.badMagic {
		copy(header, []byte("NOTAWIM\x00"))
	}
	binary.LittleEndian.PutUint32(header[8:12], wimHeaderSize)
	binary.LittleEndian.PutUint32(header[0x2C:0x30], b.imageCount)

	payload := encodeUTF16LE(b.xml)
	if !b.noXML {
		// size_in_wim (dolne 7 bajtow) + flagi (najstarszy bajt = 0).
		binary.LittleEndian.PutUint64(header[wimXMLResourceOffset:wimXMLResourceOffset+8], uint64(len(payload)))
		binary.LittleEndian.PutUint64(header[wimXMLResourceOffset+8:wimXMLResourceOffset+16], uint64(wimHeaderSize))
		binary.LittleEndian.PutUint64(header[wimXMLResourceOffset+16:wimXMLResourceOffset+24], uint64(len(payload)))
	}

	out := append(header, payload...)
	if b.truncateTo > 0 && b.truncateTo < len(out) {
		out = out[:b.truncateTo]
	}
	return out
}

func encodeUTF16LE(text string) []byte {
	var buf bytes.Buffer
	buf.Write([]byte{0xFF, 0xFE})
	for _, unit := range utf16.Encode([]rune(text)) {
		_ = binary.Write(&buf, binary.LittleEndian, unit)
	}
	return buf.Bytes()
}

// windowsImageXML buduje dokument <WIM> z jednym obrazem niosacym <WINDOWS>.
func windowsImageXML(index int, name string, arch int, major, minor, build, spbuild int, edition string) string {
	return `<WIM><TOTALBYTES>123</TOTALBYTES><IMAGE INDEX="` + strconv.Itoa(index) + `">` +
		`<NAME>` + name + `</NAME><DESCRIPTION>` + name + ` desc</DESCRIPTION>` +
		`<WINDOWS><ARCH>` + strconv.Itoa(arch) + `</ARCH><EDITIONID>` + edition + `</EDITIONID>` +
		`<VERSION><MAJOR>` + strconv.Itoa(major) + `</MAJOR><MINOR>` + strconv.Itoa(minor) + `</MINOR>` +
		`<BUILD>` + strconv.Itoa(build) + `</BUILD><SPBUILD>` + strconv.Itoa(spbuild) + `</SPBUILD></VERSION>` +
		`</WINDOWS></IMAGE></WIM>`
}

func TestReadWIMInfoFrom(t *testing.T) {
	tests := []struct {
		name       string
		blueprint  wimBlueprint
		wantErr    error
		wantImages int
		check      func(t *testing.T, info Info)
	}{
		{
			name: "windows 7 sp1 x64",
			blueprint: wimBlueprint{
				imageCount: 1,
				xml:        windowsImageXML(1, "Windows 7 PROFESSIONAL", ArchX64, 6, 1, 7601, 17514, "Professional"),
			},
			wantImages: 1,
			check: func(t *testing.T, info Info) {
				image, ok := info.PrimaryImage()
				if !ok {
					t.Fatal("brak obrazu z elementem WINDOWS")
				}
				if got, want := image.Version, (Version{6, 1, 7601, 17514}); got != want {
					t.Fatalf("version = %v, want %v", got, want)
				}
				if !image.Version.IsWindows7() {
					t.Fatal("6.1.7601 nie rozpoznane jako Windows 7")
				}
				if image.Arch != ArchX64 {
					t.Fatalf("arch = %d, want %d", image.Arch, ArchX64)
				}
				if image.EditionID != "Professional" {
					t.Fatalf("editionID = %q, want Professional", image.EditionID)
				}
				if image.Name != "Windows 7 PROFESSIONAL" {
					t.Fatalf("name = %q", image.Name)
				}
				if image.Description != "Windows 7 PROFESSIONAL desc" {
					t.Fatalf("description = %q", image.Description)
				}
			},
		},
		{
			name: "windows 10 22h2 x64",
			blueprint: wimBlueprint{
				imageCount: 1,
				xml:        windowsImageXML(1, "Windows 10 Pro", ArchX64, 10, 0, 19041, 3570, "Professional"),
			},
			wantImages: 1,
			check: func(t *testing.T, info Info) {
				image, _ := info.PrimaryImage()
				if !image.Version.IsWindows10() {
					t.Fatalf("10.0.19041 nie rozpoznane jako Windows 10: %v", image.Version)
				}
			},
		},
		{
			name:      "zla sygnatura",
			blueprint: wimBlueprint{badMagic: true, xml: windowsImageXML(1, "x", ArchX64, 6, 1, 7601, 17514, "Ultimate")},
			wantErr:   ErrNotWIM,
		},
		{
			name:      "obciety naglowek",
			blueprint: wimBlueprint{truncateTo: 32, xml: windowsImageXML(1, "x", ArchX64, 6, 1, 7601, 17514, "Ultimate")},
			wantErr:   ErrTruncatedWIM,
		},
		{
			name:      "obciety zasob XML",
			blueprint: wimBlueprint{truncateTo: wimHeaderSize + 4, xml: windowsImageXML(1, "x", ArchX64, 6, 1, 7601, 17514, "Ultimate")},
			wantErr:   ErrTruncatedWIM,
		},
		{
			name:      "brak zasobu XML",
			blueprint: wimBlueprint{noXML: true, xml: windowsImageXML(1, "x", ArchX64, 6, 1, 7601, 17514, "Ultimate")},
			wantErr:   ErrNoXMLData,
		},
		{
			name:      "pusty zasob XML",
			blueprint: wimBlueprint{imageCount: 0, xml: "   "},
			wantErr:   ErrNoXMLData,
		},
		{
			name:      "uszkodzony XML",
			blueprint: wimBlueprint{imageCount: 1, xml: `<WIM><IMAGE INDEX="1"><NAME>x`},
			wantErr:   ErrMalformedXML,
		},
		{
			name: "obraz bez elementu WINDOWS",
			blueprint: wimBlueprint{
				imageCount: 2,
				xml: `<WIM><IMAGE INDEX="1"><NAME>Microsoft Windows PE</NAME></IMAGE>` +
					`<IMAGE INDEX="2"><NAME>Microsoft Windows Setup</NAME>` +
					`<WINDOWS><ARCH>9</ARCH><VERSION><MAJOR>10</MAJOR><MINOR>0</MINOR><BUILD>19041</BUILD><SPBUILD>1</SPBUILD></VERSION></WINDOWS>` +
					`</IMAGE></WIM>`,
			},
			wantImages: 2,
			check: func(t *testing.T, info Info) {
				if info.Images[0].HasWindows {
					t.Fatal("obraz 1 nie ma <WINDOWS>, a HasWindows=true")
				}
				if !info.Images[0].Version.IsZero() {
					t.Fatalf("obraz bez <WINDOWS> ma wersje %v", info.Images[0].Version)
				}
				if info.Images[0].Arch != ArchUnknown {
					t.Fatalf("obraz bez <WINDOWS> ma arch %d", info.Images[0].Arch)
				}
				image, ok := info.PrimaryImage()
				if !ok || image.Index != 2 {
					t.Fatalf("PrimaryImage = %+v ok=%t, want index 2", image, ok)
				}
				if index, ok := info.LastImageIndexForArch(ArchX64); !ok || index != 2 {
					t.Fatalf("LastImageIndexForArch = %d ok=%t, want 2", index, ok)
				}
			},
		},
		{
			name:      "pusty plik",
			blueprint: wimBlueprint{truncateTo: 1, xml: "<WIM></WIM>"},
			wantErr:   ErrTruncatedWIM,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			info, err := readWIMInfoFrom(bytes.NewReader(buildWIM(tt.blueprint)))
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("err = %v, want %v", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("nieoczekiwany blad: %v", err)
			}
			if len(info.Images) != tt.wantImages {
				t.Fatalf("liczba obrazow = %d, want %d", len(info.Images), tt.wantImages)
			}
			if tt.check != nil {
				tt.check(t, info)
			}
		})
	}
}

func TestReadWIMInfoRejectsMissingFile(t *testing.T) {
	if _, err := ReadWIMInfo(t.TempDir() + "/nie-ma-takiego.wim"); err == nil {
		t.Fatal("oczekiwano bledu dla nieistniejacego pliku")
	}
}

func TestArchNameCoversKnownValues(t *testing.T) {
	tests := []struct {
		arch int
		want string
	}{
		{ArchX86, "x86"},
		{ArchX64, "x64"},
		{ArchARM64, "arm64"},
		{ArchUnknown, "unknown"},
		{123, "unknown"},
	}
	for _, tt := range tests {
		if got := ArchName(tt.arch); got != tt.want {
			t.Fatalf("ArchName(%d) = %q, want %q", tt.arch, got, tt.want)
		}
	}
}
