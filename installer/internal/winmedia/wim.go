// Package winmedia czyta metadane nosnikow instalacyjnych Windows
// (ISO zamontowane jako katalog albo rozpakowany USB) i przygotowuje je
// do startu na czystym UEFI x64 z wylaczonym CSM.
//
// Pakiet jest przenosny (kompiluje sie na kazdym GOOS) i nigdy nie montuje
// obrazu WIM w celu odczytu wersji: parser czyta wylacznie nieskompresowany
// zasob XML_DATA z naglowka WIM w trybie read-only.
package winmedia

import (
	"encoding/binary"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"unicode/utf16"
)

// Typowane bledy parsera WIM. Wywolujacy rozroznia je przez errors.Is.
var (
	// ErrNotWIM oznacza brak sygnatury "MSWIM\0\0\0" na offsecie 0.
	ErrNotWIM = errors.New("plik nie jest obrazem WIM (brak sygnatury MSWIM)")
	// ErrTruncatedWIM oznacza plik krotszy niz naglowek albo zasob XML
	// wykraczajacy poza koniec pliku.
	ErrTruncatedWIM = errors.New("obraz WIM jest obciety")
	// ErrNoXMLData oznacza brak zasobu XML_DATA (zerowy rozmiar/offset).
	ErrNoXMLData = errors.New("obraz WIM nie zawiera zasobu XML_DATA")
	// ErrMalformedXML oznacza, ze zasob XML_DATA istnieje, ale nie da sie
	// go sparsowac jako dokumentu <WIM>.
	ErrMalformedXML = errors.New("zasob XML_DATA obrazu WIM jest uszkodzony")
)

const (
	// wimHeaderSize to staly rozmiar naglowka WIM.
	wimHeaderSize = 208
	// wimXMLResourceOffset to offset naglowka zasobu XML_DATA w naglowku WIM.
	wimXMLResourceOffset = 0x48
	// wimMaxXMLBytes ogranicza odczyt XML (realnie kilkadziesiat KiB).
	wimMaxXMLBytes = 64 << 20
)

// wimMagic to sygnatura obrazu WIM.
var wimMagic = [8]byte{'M', 'S', 'W', 'I', 'M', 0, 0, 0}

// ArchUnknown oznacza brak informacji o architekturze w metadanych obrazu.
const ArchUnknown = -1

// Wartosci <ARCH> uzywane przez Microsoft w XML obrazow WIM.
const (
	ArchX86   = 0
	ArchARM   = 5
	ArchIA64  = 6
	ArchX64   = 9
	ArchARM64 = 12
)

// ArchName zwraca czytelna nazwe architektury obrazu.
func ArchName(arch int) string {
	switch arch {
	case ArchX86:
		return "x86"
	case ArchARM:
		return "arm"
	case ArchIA64:
		return "ia64"
	case ArchX64:
		return "x64"
	case ArchARM64:
		return "arm64"
	default:
		return "unknown"
	}
}

// Version to czworka <MAJOR>.<MINOR>.<BUILD>.<SPBUILD> z <WINDOWS><VERSION>.
type Version struct {
	Major   int
	Minor   int
	Build   int
	SPBuild int
}

// String renderuje wersje w postaci 6.1.7601.17514.
func (v Version) String() string {
	return fmt.Sprintf("%d.%d.%d.%d", v.Major, v.Minor, v.Build, v.SPBuild)
}

// IsZero informuje, czy wersja jest pusta (brak <WINDOWS> w obrazie).
func (v Version) IsZero() bool {
	return v == Version{}
}

// IsWindows7 rozpoznaje rodzine 6.1.760x (Windows 7 / WinPE 3.x).
func (v Version) IsWindows7() bool {
	return v.Major == 6 && v.Minor == 1
}

// IsWindows10 rozpoznaje rodzine 10.0.x (Windows 10/11, WinPE 10).
func (v Version) IsWindows10() bool {
	return v.Major == 10 && v.Minor == 0
}

// Image to jeden wpis <IMAGE> z zasobu XML_DATA.
type Image struct {
	Index       int
	Name        string
	Description string
	// HasWindows jest false dla obrazow bez elementu <WINDOWS>
	// (czeste w boot.wim starszych nosnikow).
	HasWindows bool
	Version    Version
	// Arch to wartosc <ARCH>; ArchUnknown gdy nieobecna.
	Arch      int
	EditionID string
}

// Info to metadane calego pliku WIM/ESD/SWM.
type Info struct {
	// Path to sciezka pliku, z ktorego odczytano metadane.
	Path string
	// ImageCount to licznik obrazow z naglowka WIM.
	ImageCount int
	Images     []Image
}

// PrimaryImage zwraca pierwszy obraz z elementem <WINDOWS>. Drugi wynik
// jest false, gdy zaden obraz nie niesie metadanych Windows.
func (i Info) PrimaryImage() (Image, bool) {
	for _, img := range i.Images {
		if img.HasWindows {
			return img, true
		}
	}
	return Image{}, false
}

// FirstImageIndexForArch zwraca indeks pierwszego obrazu o zadanej
// architekturze. Drugi wynik jest false, gdy takiego obrazu nie ma.
func (i Info) FirstImageIndexForArch(arch int) (int, bool) {
	for _, img := range i.Images {
		if img.HasWindows && img.Arch == arch {
			return img.Index, true
		}
	}
	return 0, false
}

// LastImageIndexForArch zwraca indeks ostatniego obrazu o zadanej
// architekturze. Dla boot.wim jest to zwykle obraz Setup (index 2),
// ktory niesie kompletny katalog \Windows\Boot\EFI.
func (i Info) LastImageIndexForArch(arch int) (int, bool) {
	index, ok := 0, false
	for _, img := range i.Images {
		if img.HasWindows && img.Arch == arch {
			index, ok = img.Index, true
		}
	}
	return index, ok
}

// ReadWIMInfo otwiera plik WIM/ESD/SWM w trybie read-only i zwraca metadane
// z zasobu XML_DATA. Plik nie jest montowany ani modyfikowany.
func ReadWIMInfo(path string) (Info, error) {
	file, err := os.Open(path)
	if err != nil {
		return Info{}, fmt.Errorf("otwarcie WIM %s: %w", path, err)
	}
	defer file.Close()

	info, err := readWIMInfoFrom(file)
	if err != nil {
		return Info{}, fmt.Errorf("odczyt metadanych WIM %s: %w", path, err)
	}
	info.Path = path
	return info, nil
}

// readWIMInfoFrom czyta metadane z dowolnego czytnika z losowym dostepem
// (ulatwia testy na bufory w pamieci).
func readWIMInfoFrom(r io.ReaderAt) (Info, error) {
	header := make([]byte, wimHeaderSize)
	if _, err := io.ReadFull(io.NewSectionReader(r, 0, wimHeaderSize), header); err != nil {
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			return Info{}, ErrTruncatedWIM
		}
		return Info{}, err
	}
	if string(header[:8]) != string(wimMagic[:]) {
		return Info{}, ErrNotWIM
	}

	info := Info{ImageCount: int(binary.LittleEndian.Uint32(header[0x2C:0x30]))}

	sizeInWIM, offsetInWIM, originalSize := decodeResourceHeader(header[wimXMLResourceOffset : wimXMLResourceOffset+24])
	if sizeInWIM == 0 || offsetInWIM <= 0 {
		return info, ErrNoXMLData
	}
	if sizeInWIM > wimMaxXMLBytes {
		return info, fmt.Errorf("%w: zasob XML_DATA ma %d bajtow", ErrMalformedXML, sizeInWIM)
	}
	// XML_DATA jest zawsze skladowany nieskompresowany, wiec size_in_wim
	// i original_size musza sie zgadzac; rozbieznosc traktujemy jako
	// uszkodzone metadane zamiast probowac dekompresji.
	if originalSize != 0 && originalSize != sizeInWIM {
		return info, fmt.Errorf("%w: XML_DATA size_in_wim=%d original_size=%d", ErrMalformedXML, sizeInWIM, originalSize)
	}

	raw := make([]byte, sizeInWIM)
	if _, err := r.ReadAt(raw, offsetInWIM); err != nil {
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			return info, ErrTruncatedWIM
		}
		return info, err
	}

	text := decodeUTF16LE(raw)
	if strings.TrimSpace(text) == "" {
		return info, ErrNoXMLData
	}

	images, err := parseWIMXML(text)
	if err != nil {
		return info, err
	}
	info.Images = images
	if info.ImageCount == 0 {
		info.ImageCount = len(images)
	}
	return info, nil
}

// decodeResourceHeader rozpakowuje naglowek zasobu WIM: 8 bajtow, w ktorych
// dolne 7 bajtow to size_in_wim a najstarszy bajt to flagi, potem 8 bajtow
// offset_in_wim i 8 bajtow original_size.
func decodeResourceHeader(b []byte) (sizeInWIM, offsetInWIM, originalSize int64) {
	packed := binary.LittleEndian.Uint64(b[0:8])
	sizeInWIM = int64(packed & 0x00FF_FFFF_FFFF_FFFF)
	offsetInWIM = int64(binary.LittleEndian.Uint64(b[8:16]))
	originalSize = int64(binary.LittleEndian.Uint64(b[16:24]))
	return sizeInWIM, offsetInWIM, originalSize
}

// decodeUTF16LE zamienia bufor UTF-16LE (z opcjonalnym BOM) na UTF-8.
// Nieparzysty ogon i koncowe znaki NUL sa odrzucane.
func decodeUTF16LE(raw []byte) string {
	if len(raw) >= 2 && raw[0] == 0xFF && raw[1] == 0xFE {
		raw = raw[2:]
	}
	units := make([]uint16, 0, len(raw)/2)
	for i := 0; i+1 < len(raw); i += 2 {
		units = append(units, binary.LittleEndian.Uint16(raw[i:i+2]))
	}
	return strings.TrimRight(string(utf16.Decode(units)), "\x00")
}

// xmlWIM odwzorowuje dokument <WIM> z zasobu XML_DATA.
type xmlWIM struct {
	XMLName xml.Name   `xml:"WIM"`
	Images  []xmlImage `xml:"IMAGE"`
}

type xmlImage struct {
	Index       string      `xml:"INDEX,attr"`
	Name        string      `xml:"NAME"`
	Description string      `xml:"DESCRIPTION"`
	Windows     *xmlWindows `xml:"WINDOWS"`
}

type xmlWindows struct {
	Arch      *int        `xml:"ARCH"`
	EditionID string      `xml:"EDITIONID"`
	Version   *xmlVersion `xml:"VERSION"`
}

type xmlVersion struct {
	Major   int `xml:"MAJOR"`
	Minor   int `xml:"MINOR"`
	Build   int `xml:"BUILD"`
	SPBuild int `xml:"SPBUILD"`
}

// parseWIMXML parsuje dokument <WIM> i zwraca liste obrazow. Obrazy bez
// elementu <WINDOWS> sa zwracane z HasWindows=false zamiast bledu.
func parseWIMXML(text string) ([]Image, error) {
	trimmed := strings.TrimSpace(text)
	var doc xmlWIM
	if err := xml.Unmarshal([]byte(trimmed), &doc); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrMalformedXML, err)
	}
	images := make([]Image, 0, len(doc.Images))
	for position, entry := range doc.Images {
		image := Image{
			Index:       position + 1,
			Name:        strings.TrimSpace(entry.Name),
			Description: strings.TrimSpace(entry.Description),
			Arch:        ArchUnknown,
		}
		if parsed, err := strconv.Atoi(strings.TrimSpace(entry.Index)); err == nil && parsed > 0 {
			image.Index = parsed
		}
		if entry.Windows != nil {
			image.HasWindows = true
			image.EditionID = strings.TrimSpace(entry.Windows.EditionID)
			if entry.Windows.Arch != nil {
				image.Arch = *entry.Windows.Arch
			}
			if v := entry.Windows.Version; v != nil {
				image.Version = Version{Major: v.Major, Minor: v.Minor, Build: v.Build, SPBuild: v.SPBuild}
			}
		}
		images = append(images, image)
	}
	return images, nil
}
