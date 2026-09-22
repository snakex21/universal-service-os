package install

// Most miedzy klasyfikacja NOSNIKA a klasyfikacja CELU instalacji Win7.
//
// Podzial odpowiedzialnosci (jedna implementacja kazdego pojecia):
//
//   - installer/internal/winmedia jest zrodlem prawdy o NOSNIKU: co to za
//     ISO/USB (WIN7_PE7 / WIN7_PE10 / WIN10 / UNKNOWN) i jaka ma <ARCH>.
//     winmedia nie wie nic o maszynie docelowej.
//   - ten pakiet (install) jest zrodlem prawdy o CELU: jakie firmware ma
//     maszyna, na ktora instalujemy, i czy wchodzi sciezka modern czy
//     vanilla (Win7TargetKind).
//
// ClassifyWin7Target dalej przyjmuje stringi (uzywaja tego wywolania
// wykonawcze i testy), ale caly rozbior architektury i cala decyzja
// siedza w classifyWin7Target/parseMediaArch ponizej, wiec nie ma dwoch
// rownoleglych tabel decyzyjnych.

import (
	"errors"
	"fmt"
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/winmedia"
)

// ErrMediaNotWindows7 oznacza odmowe stagingu Win7 dla nosnika, ktory nie
// jest nosnikiem Windows 7 (WIN10 albo UNKNOWN). Klasyfikacja nosnika
// pochodzi wylacznie z winmedia.ClassifyMedia.
var ErrMediaNotWindows7 = errors.New("nosnik nie jest nosnikiem Windows 7: staging win7 odmowiony")

// IsWin7Media mowi, czy klasa nosnika z winmedia to ktorys z wariantow
// Windows 7 (oryginalny WinPE 3.x albo przeszczepiony WinPE 10).
func IsWin7Media(class winmedia.Class) bool {
	return class == winmedia.ClassWin7PE7 || class == winmedia.ClassWin7PE10
}

// parseMediaArch to jedyna implementacja rozbioru nazwy architektury na
// stala winmedia.Arch*. Nieznana nazwa -> winmedia.ArchUnknown.
func parseMediaArch(arch string) int {
	switch strings.ToLower(strings.TrimSpace(arch)) {
	case "x64", "amd64", "x86_64", "x86-64":
		return winmedia.ArchX64
	case "x86", "i386", "ia32":
		return winmedia.ArchX86
	case "arm64", "aarch64":
		return winmedia.ArchARM64
	case "arm":
		return winmedia.ArchARM
	case "ia64":
		return winmedia.ArchIA64
	default:
		return winmedia.ArchUnknown
	}
}

// isUEFIFirmware to jedyna implementacja rozbioru nazwy firmware celu.
// Akceptuje warianty spotykane w konfiguracji i w logach.
func isUEFIFirmware(firmware string) bool {
	switch strings.ToLower(strings.TrimSpace(firmware)) {
	case "uefi", "gpt", "uefi-x64", "uefi_x64":
		return true
	default:
		return false
	}
}

// classifyWin7Target to jedyna tabela decyzyjna celu: x64 + UEFI = modern,
// wszystko inne = retro vanilla (bez zmian w WIM).
func classifyWin7Target(arch int, firmware string) Win7TargetKind {
	if arch == winmedia.ArchX64 && isUEFIFirmware(firmware) {
		return Win7UEFIX64Modern
	}
	return Win7BIOSVanilla
}

// ClassifyWin7TargetForMedia laczy obie klasyfikacje: klasa i <ARCH>
// pochodza z winmedia (nosnik), firmware od wywolujacego (cel). Zwraca
// ErrMediaNotWindows7, gdy nosnik nie jest Windows 7 — dzieki temu klasa
// wykryta z WIM zastepuje przekazywany recznie string "x64"/"x86".
func ClassifyWin7TargetForMedia(media winmedia.Media, targetFirmware string) (Win7TargetKind, error) {
	if !IsWin7Media(media.Class) {
		return Win7BIOSVanilla, fmt.Errorf("%w (class=%s, %s)", ErrMediaNotWindows7, media.Class, media.Describe())
	}
	return classifyWin7Target(media.Arch, targetFirmware), nil
}
