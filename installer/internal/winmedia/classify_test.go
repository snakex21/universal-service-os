package winmedia

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// mediaBlueprint opisuje syntetyczny nosnik budowany w tempdir.
type mediaBlueprint struct {
	// installXML/bootXML puste = plik nie jest tworzony.
	installXML string
	bootXML    string
	// installName pozwala testowac install.esd / install.swm i wielkosc liter.
	installName string
	// files to dodatkowe puste pliki (sygnaly ukladu), sciezki ze slashami.
	files []string
}

func writeMedia(t *testing.T, b mediaBlueprint) string {
	t.Helper()
	root := t.TempDir()
	if b.installXML != "" {
		name := b.installName
		if name == "" {
			name = "install.wim"
		}
		writeMediaFile(t, root, "sources/"+name, buildWIM(wimBlueprint{imageCount: 1, xml: b.installXML}))
	}
	if b.bootXML != "" {
		writeMediaFile(t, root, "sources/boot.wim", buildWIM(wimBlueprint{imageCount: 2, xml: b.bootXML}))
	}
	for _, path := range b.files {
		writeMediaFile(t, root, path, []byte("x"))
	}
	return root
}

func writeMediaFile(t *testing.T, root, rel string, data []byte) {
	t.Helper()
	path := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// Skroty do typowych dokumentow XML nosnikow.
var (
	win7InstallXML = windowsImageXML(1, "Windows 7 ULTIMATE", ArchX64, 6, 1, 7601, 17514, "Ultimate")
	win7x86XML     = windowsImageXML(1, "Windows 7 ULTIMATE", ArchX86, 6, 1, 7601, 17514, "Ultimate")
	winPE7XML      = windowsImageXML(1, "Microsoft Windows Setup", ArchX64, 6, 1, 7601, 17514, "WindowsPE")
	winPE10XML     = windowsImageXML(2, "Microsoft Windows Setup", ArchX64, 10, 0, 19041, 1, "WindowsPE")
	win10Install   = windowsImageXML(1, "Windows 10 Pro", ArchX64, 10, 0, 19045, 6396, "Professional")
	vistaXML       = windowsImageXML(1, "Windows Vista", ArchX64, 6, 0, 6002, 18005, "Ultimate")
)

// win7MediaFiles to uklad plikow oryginalnego ISO Windows 7 x64: jest
// efi/microsoft/boot, nie ma efi/boot/bootx64.efi.
var win7MediaFiles = []string{
	"efi/microsoft/boot/bootmgfw.efi",
	"efi/microsoft/boot/bcd",
	"boot/efisys.bin",
	"boot/etfsboot.com",
}

func TestClassifyMedia(t *testing.T) {
	tests := []struct {
		name        string
		blueprint   mediaBlueprint
		wantClass   Class
		wantArch    int
		wantInstall Version
		wantBoot    Version
	}{
		{
			name:        "win7 z oryginalnym WinPE 3.x",
			blueprint:   mediaBlueprint{installXML: win7InstallXML, bootXML: winPE7XML, files: win7MediaFiles},
			wantClass:   ClassWin7PE7,
			wantArch:    ArchX64,
			wantInstall: Version{6, 1, 7601, 17514},
			wantBoot:    Version{6, 1, 7601, 17514},
		},
		{
			name:        "win7 z przeszczepionym WinPE 10",
			blueprint:   mediaBlueprint{installXML: win7InstallXML, bootXML: winPE10XML, files: win7MediaFiles},
			wantClass:   ClassWin7PE10,
			wantArch:    ArchX64,
			wantInstall: Version{6, 1, 7601, 17514},
			wantBoot:    Version{10, 0, 19041, 1},
		},
		{
			name:        "windows 10",
			blueprint:   mediaBlueprint{installXML: win10Install, bootXML: winPE10XML, files: append([]string{"efi/boot/bootx64.efi"}, win7MediaFiles...)},
			wantClass:   ClassWin10,
			wantArch:    ArchX64,
			wantInstall: Version{10, 0, 19045, 6396},
			wantBoot:    Version{10, 0, 19041, 1},
		},
		{
			name:        "vista to nie jest zadna z obslugiwanych generacji",
			blueprint:   mediaBlueprint{installXML: vistaXML, bootXML: vistaXML},
			wantClass:   ClassUnknown,
			wantArch:    ArchX64,
			wantInstall: Version{6, 0, 6002, 18005},
			wantBoot:    Version{6, 0, 6002, 18005},
		},
		{
			name:        "install.esd jest akceptowany",
			blueprint:   mediaBlueprint{installXML: win10Install, installName: "install.esd", bootXML: winPE10XML},
			wantClass:   ClassWin10,
			wantArch:    ArchX64,
			wantInstall: Version{10, 0, 19045, 6396},
			wantBoot:    Version{10, 0, 19041, 1},
		},
		{
			name:        "install.swm jest akceptowany",
			blueprint:   mediaBlueprint{installXML: win7InstallXML, installName: "install.swm", bootXML: winPE10XML},
			wantClass:   ClassWin7PE10,
			wantArch:    ArchX64,
			wantInstall: Version{6, 1, 7601, 17514},
			wantBoot:    Version{10, 0, 19041, 1},
		},
		{
			name:        "wielkosc liter nie ma znaczenia",
			blueprint:   mediaBlueprint{installXML: win7InstallXML, installName: "INSTALL.WIM", bootXML: winPE7XML},
			wantClass:   ClassWin7PE7,
			wantArch:    ArchX64,
			wantInstall: Version{6, 1, 7601, 17514},
			wantBoot:    Version{6, 1, 7601, 17514},
		},
		{
			name:        "boot.wim bez elementu WINDOWS daje UNKNOWN",
			blueprint:   mediaBlueprint{installXML: win7InstallXML, bootXML: `<WIM><IMAGE INDEX="1"><NAME>PE</NAME></IMAGE></WIM>`},
			wantClass:   ClassUnknown,
			wantArch:    ArchX64,
			wantInstall: Version{6, 1, 7601, 17514},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			media, err := ClassifyMedia(writeMedia(t, tt.blueprint))
			if err != nil {
				t.Fatalf("ClassifyMedia: %v", err)
			}
			if media.Class != tt.wantClass {
				t.Fatalf("class = %s, want %s (%s)", media.Class, tt.wantClass, media.Describe())
			}
			if media.Arch != tt.wantArch {
				t.Fatalf("arch = %d, want %d", media.Arch, tt.wantArch)
			}
			if media.InstallVersion != tt.wantInstall {
				t.Fatalf("install version = %v, want %v", media.InstallVersion, tt.wantInstall)
			}
			if media.BootVersion != tt.wantBoot {
				t.Fatalf("boot version = %v, want %v", media.BootVersion, tt.wantBoot)
			}
		})
	}
}

func TestClassifyMediaRetainsSignals(t *testing.T) {
	root := writeMedia(t, mediaBlueprint{installXML: win7InstallXML, bootXML: winPE7XML, files: win7MediaFiles})
	media, err := ClassifyMedia(root)
	if err != nil {
		t.Fatalf("ClassifyMedia: %v", err)
	}
	want := Signals{
		EFIDir:            true,
		EFIBootBootx64:    false,
		MicrosoftBootmgfw: true,
		MicrosoftBCD:      true,
		EfisysBin:         true,
		EtfsbootCom:       true,
	}
	if media.Signals != want {
		t.Fatalf("signals = %+v, want %+v", media.Signals, want)
	}
	// Oryginalne ISO Win7 x64 nie ma efi/boot/bootx64.efi: z USB nie wstanie
	// na czystym UEFI, dopoki patcher go nie dolozy.
	if media.UEFIBootableAsIs {
		t.Fatal("ISO Win7 bez efi/boot/bootx64.efi zgloszone jako UEFI-bootable")
	}
	if !media.UEFICapable {
		t.Fatal("x64 powinno byc UEFICapable")
	}
}

func TestClassifyMediaFlagsX86AsNotUEFICapable(t *testing.T) {
	root := writeMedia(t, mediaBlueprint{installXML: win7x86XML, bootXML: winPE7XML, files: win7MediaFiles})
	media, err := ClassifyMedia(root)
	if err != nil {
		t.Fatalf("ClassifyMedia: %v", err)
	}
	if media.Arch != ArchX86 {
		t.Fatalf("arch = %d, want %d", media.Arch, ArchX86)
	}
	if media.UEFICapable || media.UEFIBootableAsIs {
		t.Fatal("x86 nie moze byc zgloszone jako zdolne do UEFI")
	}
}

func TestClassifyMediaReportsMissingImages(t *testing.T) {
	tests := []struct {
		name      string
		blueprint mediaBlueprint
		wantErr   error
	}{
		{"brak install", mediaBlueprint{bootXML: winPE7XML}, ErrNoInstallImage},
		{"brak boot", mediaBlueprint{installXML: win7InstallXML}, ErrNoBootImage},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			media, err := ClassifyMedia(writeMedia(t, tt.blueprint))
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("err = %v, want %v", err, tt.wantErr)
			}
			if media.Class != ClassUnknown {
				t.Fatalf("class = %s, want %s", media.Class, ClassUnknown)
			}
		})
	}
}

func TestClassifyMediaRejectsNonDirectory(t *testing.T) {
	root := t.TempDir()
	file := filepath.Join(root, "plik.iso")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, err := ClassifyMedia(file); err == nil {
		t.Fatal("oczekiwano bledu dla sciezki, ktora nie jest katalogiem")
	}
}
