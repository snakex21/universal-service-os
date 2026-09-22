package winmedia

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeExtractor zastepuje DISM w testach: zapisuje deterministyczna
// zawartosc i liczy wywolania, zeby dalo sie sprawdzic idempotencje.
type fakeExtractor struct {
	unavailable error
	extractErr  error
	empty       bool
	calls       []extractCall
}

type extractCall struct {
	wim       string
	index     int
	pathInWIM string
	dst       string
}

func (f *fakeExtractor) Available() error {
	return f.unavailable
}

func (f *fakeExtractor) ExtractFile(wimPath string, imageIndex int, pathInWIM, dst string) error {
	f.calls = append(f.calls, extractCall{wimPath, imageIndex, pathInWIM, dst})
	if f.extractErr != nil {
		return f.extractErr
	}
	data := []byte("MZ fake bootmgfw.efi")
	if f.empty {
		data = nil
	}
	return os.WriteFile(dst, data, 0o644)
}

func classifiedMedia(t *testing.T, b mediaBlueprint) Media {
	t.Helper()
	media, err := ClassifyMedia(writeMedia(t, b))
	if err != nil {
		t.Fatalf("ClassifyMedia: %v", err)
	}
	return media
}

func TestPatchUEFIExtractsBootloader(t *testing.T) {
	tests := []struct {
		name      string
		blueprint mediaBlueprint
		wantClass Class
		// wantSource to nazwa pliku, z ktorego ma pochodzic bootmgfw.efi.
		wantSource string
		wantIndex  int
	}{
		{
			name:       "win7 PE7 bierze bootloader z install.wim",
			blueprint:  mediaBlueprint{installXML: win7InstallXML, bootXML: winPE7XML, files: win7MediaFiles},
			wantClass:  ClassWin7PE7,
			wantSource: "install.wim",
			wantIndex:  1,
		},
		{
			name:       "win7 PE10 bierze podpisany bootloader z boot.wim",
			blueprint:  mediaBlueprint{installXML: win7InstallXML, bootXML: winPE10XML, files: win7MediaFiles},
			wantClass:  ClassWin7PE10,
			wantSource: "boot.wim",
			wantIndex:  2,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			media := classifiedMedia(t, tt.blueprint)
			if media.Class != tt.wantClass {
				t.Fatalf("class = %s, want %s", media.Class, tt.wantClass)
			}
			extractor := &fakeExtractor{}
			result, err := PatchUEFI(media, extractor)
			if err != nil {
				t.Fatalf("PatchUEFI: %v", err)
			}
			if !result.Changed {
				t.Fatal("pierwszy przebieg nie zglosil zmiany")
			}
			if len(extractor.calls) != 1 {
				t.Fatalf("liczba wywolan ekstraktora = %d, want 1", len(extractor.calls))
			}
			call := extractor.calls[0]
			if filepath.Base(call.wim) != tt.wantSource {
				t.Fatalf("zrodlo = %s, want %s", filepath.Base(call.wim), tt.wantSource)
			}
			if call.index != tt.wantIndex {
				t.Fatalf("index = %d, want %d", call.index, tt.wantIndex)
			}
			if call.pathInWIM != BootmgfwPathInWIM {
				t.Fatalf("sciezka w WIM = %q, want %q", call.pathInWIM, BootmgfwPathInWIM)
			}
			if _, err := os.Stat(filepath.Join(media.Root, "efi", "boot", "bootx64.efi")); err != nil {
				t.Fatalf("brak efi/boot/bootx64.efi po patchu: %v", err)
			}

			// Idempotencja: drugi przebieg nie rusza ekstraktora ani plikow.
			reclassified := reclassify(t, media.Root)
			if !reclassified.UEFIBootableAsIs {
				t.Fatal("po patchu nosnik nadal nie jest UEFI-bootable")
			}
			second, err := PatchUEFI(reclassified, extractor)
			if err != nil {
				t.Fatalf("drugi PatchUEFI: %v", err)
			}
			if second.Changed {
				t.Fatal("drugi przebieg zglosil zmiane, patch nie jest idempotentny")
			}
			if len(extractor.calls) != 1 {
				t.Fatalf("drugi przebieg wywolal ekstraktor (%d wywolan)", len(extractor.calls))
			}
		})
	}
}

func reclassify(t *testing.T, root string) Media {
	t.Helper()
	media, err := ClassifyMedia(root)
	if err != nil {
		t.Fatalf("ClassifyMedia ponownie: %v", err)
	}
	return media
}

func TestPatchUEFIRefusals(t *testing.T) {
	tests := []struct {
		name      string
		blueprint mediaBlueprint
		extractor WIMExtractor
		wantErr   error
	}{
		{
			name:      "nierozpoznana generacja",
			blueprint: mediaBlueprint{installXML: vistaXML, bootXML: vistaXML, files: win7MediaFiles},
			extractor: &fakeExtractor{},
			wantErr:   ErrUnknownClass,
		},
		{
			name:      "x86 nie wstanie na czystym UEFI",
			blueprint: mediaBlueprint{installXML: win7x86XML, bootXML: winPE7XML, files: win7MediaFiles},
			extractor: &fakeExtractor{},
			wantErr:   ErrArchNotUEFICapable,
		},
		{
			name:      "brak BCD nie jest fabrykowany",
			blueprint: mediaBlueprint{installXML: win7InstallXML, bootXML: winPE7XML, files: []string{"efi/microsoft/boot/bootmgfw.efi"}},
			extractor: &fakeExtractor{},
			wantErr:   ErrMissingBCD,
		},
		{
			name:      "brak ekstraktora",
			blueprint: mediaBlueprint{installXML: win7InstallXML, bootXML: winPE7XML, files: win7MediaFiles},
			extractor: nil,
			wantErr:   ErrExtractorUnavailable,
		},
		{
			name:      "ekstraktor niedostepny w systemie",
			blueprint: mediaBlueprint{installXML: win7InstallXML, bootXML: winPE7XML, files: win7MediaFiles},
			extractor: &fakeExtractor{unavailable: errors.New("brak dism.exe w PATH")},
			wantErr:   ErrExtractorUnavailable,
		},
		{
			name: "brak obrazu x64 w zrodle",
			blueprint: mediaBlueprint{
				installXML: windowsImageXML(1, "Windows 7", ArchX64, 6, 1, 7601, 17514, "Ultimate"),
				bootXML:    `<WIM><IMAGE INDEX="1"><NAME>PE</NAME></IMAGE></WIM>`,
				files:      win7MediaFiles,
			},
			extractor: &fakeExtractor{},
			// boot.wim bez <WINDOWS> daje UNKNOWN juz na etapie klasyfikacji.
			wantErr: ErrUnknownClass,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			media := classifiedMedia(t, tt.blueprint)
			result, err := PatchUEFI(media, tt.extractor)
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("err = %v, want %v", err, tt.wantErr)
			}
			if result.Changed {
				t.Fatal("odmowa nie moze zglaszac zmiany")
			}
			if _, ok := lookupPath(media.Root, "efi", "boot", "bootx64.efi"); ok {
				t.Fatal("odmowa zostawila czesciowo zapatchowany nosnik")
			}
		})
	}
}

func TestPatchUEFIRefusesOversizeFileForFAT32(t *testing.T) {
	media := classifiedMedia(t, mediaBlueprint{installXML: win7InstallXML, bootXML: winPE7XML, files: win7MediaFiles})
	extractor := &fakeExtractor{}
	// Limit zanizony, zeby nie tworzyc pliku 4 GiB w tescie: logika walk
	// i typ bledu sa te same co dla FAT32MaxFileBytes.
	_, err := Patcher{MaxFileBytes: 16}.Patch(media, extractor)
	var oversize *OversizeFileError
	if !errors.As(err, &oversize) {
		t.Fatalf("err = %v, want *OversizeFileError", err)
	}
	if oversize.Path == "" {
		t.Fatal("blad nie nazywa pliku")
	}
	if len(extractor.calls) != 0 {
		t.Fatal("ekstraktor wywolany mimo odmowy FAT32")
	}
}

func TestCheckFAT32CompatibleAcceptsSmallLayout(t *testing.T) {
	root := writeMedia(t, mediaBlueprint{installXML: win7InstallXML, bootXML: winPE7XML, files: win7MediaFiles})
	if err := CheckFAT32Compatible(root); err != nil {
		t.Fatalf("CheckFAT32Compatible: %v", err)
	}
}

func TestOversizeFileErrorNamesFileAndSuggestsSplit(t *testing.T) {
	err := &OversizeFileError{Path: "sources/install.wim", Size: 5 << 30, Limit: FAT32MaxFileBytes}
	message := err.Error()
	for _, want := range []string{"sources/install.wim", "FAT32", "Split-Image"} {
		if !strings.Contains(message, want) {
			t.Fatalf("komunikat %q nie zawiera %q", message, want)
		}
	}
}

func TestPatchUEFIRejectsEmptyExtraction(t *testing.T) {
	media := classifiedMedia(t, mediaBlueprint{installXML: win7InstallXML, bootXML: winPE7XML, files: win7MediaFiles})
	if _, err := PatchUEFI(media, &fakeExtractor{empty: true}); err == nil {
		t.Fatal("oczekiwano bledu dla pustego bootx64.efi")
	}
}

func TestDismExtractorAvailabilityIsActionable(t *testing.T) {
	// Na nie-Windows DISM nie istnieje i blad musi to powiedziec wprost.
	err := DismExtractor{Exe: "dism.exe"}.Available()
	if err != nil && !strings.Contains(err.Error(), "DISM") {
		t.Fatalf("komunikat niedostepnosci nie wspomina DISM: %v", err)
	}
}
