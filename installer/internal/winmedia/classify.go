package winmedia

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Class to rozpoznana generacja nosnika instalacyjnego Windows.
type Class string

const (
	// ClassWin7PE7 to oryginalny nosnik Windows 7 (install 6.1.760x,
	// boot.wim z WinPE 3.x = 6.1.760x).
	ClassWin7PE7 Class = "WIN7_PE7"
	// ClassWin7PE10 to Windows 7 z przeszczepionym WinPE 10
	// (install 6.1.760x, boot.wim 10.0.x).
	ClassWin7PE10 Class = "WIN7_PE10"
	// ClassWin10 to nosnik Windows 10/11 (install 10.0.x, boot 10.0.x).
	ClassWin10 Class = "WIN10"
	// ClassUnknown to kazda inna kombinacja; obserwowane wersje pozostaja
	// w wyniku, zeby wywolujacy mogl je zalogowac.
	ClassUnknown Class = "UNKNOWN"
)

// ErrNoInstallImage oznacza brak sources/install.{wim,esd,swm} na nosniku.
var ErrNoInstallImage = errors.New("nosnik nie zawiera sources/install.wim ani install.esd/install.swm")

// ErrNoBootImage oznacza brak sources/boot.wim na nosniku.
var ErrNoBootImage = errors.New("nosnik nie zawiera sources/boot.wim")

// Signals to sygnaly pomocnicze odczytane z ukladu plikow. Nie decyduja
// o klasyfikacji (ta wynika wylacznie z wersji WIM), sluza do logowania
// i do decyzji patchera UEFI.
type Signals struct {
	// EFIDir: katalog efi/ istnieje.
	EFIDir bool
	// EFIBootBootx64: efi/boot/bootx64.efi istnieje (removable-media path).
	EFIBootBootx64 bool
	// MicrosoftBootmgfw: efi/microsoft/boot/bootmgfw.efi istnieje.
	MicrosoftBootmgfw bool
	// MicrosoftBCD: efi/microsoft/boot/bcd istnieje.
	MicrosoftBCD bool
	// EfisysBin: boot/efisys.bin istnieje (El Torito UEFI, tylko optyczne).
	EfisysBin bool
	// EtfsbootCom: boot/etfsboot.com istnieje (El Torito BIOS).
	EtfsbootCom bool
}

// Media to wynik klasyfikacji zamontowanego ISO albo rozpakowanego USB.
type Media struct {
	// Root to katalog glowny nosnika przekazany przez wywolujacego.
	Root  string
	Class Class

	// InstallImagePath i BootImagePath to faktycznie znalezione sciezki
	// (zachowana oryginalna wielkosc liter).
	InstallImagePath string
	BootImagePath    string

	// InstallVersion/BootVersion sa zerowe, gdy obraz nie niesie <WINDOWS>.
	InstallVersion      Version
	InstallVersionKnown bool
	BootVersion         Version
	BootVersionKnown    bool

	// Arch pochodzi z <ARCH> obrazu install; ArchUnknown gdy brak danych.
	Arch int

	Signals Signals

	// UEFICapable jest false dla x86 oraz dla nieznanej architektury.
	UEFICapable bool
	// UEFIBootableAsIs mowi, czy firmware zobaczy nosnik bez patchowania:
	// x64 + efi/boot/bootx64.efi + efi/microsoft/boot/bcd.
	UEFIBootableAsIs bool
}

// Describe renderuje jednolinijkowy opis do logu.
func (m Media) Describe() string {
	install, boot := "brak", "brak"
	if m.InstallVersionKnown {
		install = m.InstallVersion.String()
	}
	if m.BootVersionKnown {
		boot = m.BootVersion.String()
	}
	return fmt.Sprintf("class=%s install=%s boot=%s arch=%s uefi_as_is=%t",
		m.Class, install, boot, ArchName(m.Arch), m.UEFIBootableAsIs)
}

// installImageNames to akceptowane nazwy obrazu instalacyjnego w kolejnosci
// preferencji. install.swm to pierwszy plik zestawu podzielonego pod FAT32.
var installImageNames = []string{"install.wim", "install.esd", "install.swm"}

// ClassifyMedia klasyfikuje zamontowany-albo-rozpakowany nosnik. root to
// katalog (np. litera zamontowanego ISO albo katalog glowny pendrive).
// Funkcja jest wylacznie odczytowa i niczego nie zapisuje.
func ClassifyMedia(root string) (Media, error) {
	media := Media{Root: root, Class: ClassUnknown, Arch: ArchUnknown}

	stat, err := os.Stat(root)
	if err != nil {
		return media, fmt.Errorf("odczyt roota nosnika %s: %w", root, err)
	}
	if !stat.IsDir() {
		return media, fmt.Errorf("root nosnika %s nie jest katalogiem", root)
	}

	media.Signals = readSignals(root)

	for _, name := range installImageNames {
		if path, ok := lookupPath(root, "sources", name); ok {
			media.InstallImagePath = path
			break
		}
	}
	if media.InstallImagePath == "" {
		return media, ErrNoInstallImage
	}
	if path, ok := lookupPath(root, "sources", "boot.wim"); ok {
		media.BootImagePath = path
	} else {
		return media, ErrNoBootImage
	}

	installInfo, err := ReadWIMInfo(media.InstallImagePath)
	if err != nil {
		return media, err
	}
	bootInfo, err := ReadWIMInfo(media.BootImagePath)
	if err != nil {
		return media, err
	}

	if image, ok := installInfo.PrimaryImage(); ok {
		media.InstallVersion = image.Version
		media.InstallVersionKnown = !image.Version.IsZero()
		media.Arch = image.Arch
	}
	if image, ok := bootInfo.PrimaryImage(); ok {
		media.BootVersion = image.Version
		media.BootVersionKnown = !image.Version.IsZero()
	}

	media.Class = classify(media.InstallVersion, media.InstallVersionKnown, media.BootVersion, media.BootVersionKnown)
	media.UEFICapable = media.Arch == ArchX64 || media.Arch == ArchARM64
	media.UEFIBootableAsIs = media.UEFICapable && media.Signals.EFIBootBootx64 && media.Signals.MicrosoftBCD
	return media, nil
}

// classify implementuje tabele decyzyjna opisana w MEDIA_LAYOUT.md.
func classify(install Version, installKnown bool, boot Version, bootKnown bool) Class {
	if !installKnown || !bootKnown {
		return ClassUnknown
	}
	switch {
	case install.IsWindows7() && boot.IsWindows7():
		return ClassWin7PE7
	case install.IsWindows7() && boot.IsWindows10():
		return ClassWin7PE10
	case install.IsWindows10() && boot.IsWindows10():
		return ClassWin10
	default:
		return ClassUnknown
	}
}

// readSignals zbiera sygnaly pomocnicze z ukladu plikow.
func readSignals(root string) Signals {
	var s Signals
	_, s.EFIDir = lookupPath(root, "efi")
	_, s.EFIBootBootx64 = lookupPath(root, "efi", "boot", "bootx64.efi")
	_, s.MicrosoftBootmgfw = lookupPath(root, "efi", "microsoft", "boot", "bootmgfw.efi")
	_, s.MicrosoftBCD = lookupPath(root, "efi", "microsoft", "boot", "bcd")
	_, s.EfisysBin = lookupPath(root, "boot", "efisys.bin")
	_, s.EtfsbootCom = lookupPath(root, "boot", "etfsboot.com")
	return s
}

// lookupPath rozwiazuje sciezke wzgledna bez rozrozniania wielkosci liter
// (ISO 9660/Joliet i FAT32 potrafia miec dowolna wielkosc liter) i zwraca
// faktyczna sciezke na dysku.
func lookupPath(root string, parts ...string) (string, bool) {
	current := root
	for _, want := range parts {
		match, ok := lookupChild(current, want)
		if !ok {
			return "", false
		}
		current = match
	}
	return current, true
}

func lookupChild(dir, want string) (string, bool) {
	direct := filepath.Join(dir, want)
	if _, err := os.Lstat(direct); err == nil {
		return direct, true
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", false
	}
	for _, entry := range entries {
		if strings.EqualFold(entry.Name(), want) {
			return filepath.Join(dir, entry.Name()), true
		}
	}
	return "", false
}
