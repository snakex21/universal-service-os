package i18n

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"sort"
	"strings"
	"unicode/utf16"
)

// Files written to the USOS ESP for the chosen language. Only that language
// is stored on the drive; the boot EFI and pae.exe carry English built in and
// use it for every string missing from (or when they cannot validate) these
// files. Changing the language means running install or update again.
const (
	SettingsPath   = "EFI/USOS/usos-settings.ini"
	BootBlobPath   = "EFI/USOS/lang.bin"
	XPHelperPath   = "EFI/USOS/lang-xp.ini"
	BootKeyPrefix  = "boot."
	XPKeyPrefix    = "xp_pae."
	bootBlobMagic  = "USOSLANG"
	bootBlobFormat = 1
	bootHeaderSize = 28
)

// DeviceFile is one language file destined for the ESP (slash-separated path).
type DeviceFile struct {
	Path string
	Data []byte
}

// DeviceFiles returns every per-language ESP file for lang.
func DeviceFiles(lang string) ([]DeviceFile, error) {
	lang = Normalize(lang)
	boot, err := BootBlob(lang)
	if err != nil {
		return nil, err
	}
	xp, err := XPHelperINI(lang)
	if err != nil {
		return nil, err
	}
	return []DeviceFile{
		{Path: SettingsPath, Data: SettingsINI(lang)},
		{Path: BootBlobPath, Data: boot},
		{Path: XPHelperPath, Data: xp},
	}, nil
}

// SettingsINI is the language record read by USOS components on the drive.
func SettingsINI(lang string) []byte {
	return []byte("[ui]\r\nlanguage=" + Normalize(lang) + "\r\n")
}

// ParseSettingsLanguage extracts language= from a usos-settings.ini body.
func ParseSettingsLanguage(data []byte) (string, bool) {
	section := ""
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.ToLower(line[1 : len(line)-1])
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if ok && section == "ui" && strings.EqualFold(strings.TrimSpace(key), "language") {
			return strings.TrimSpace(value), true
		}
	}
	return "", false
}

func prefixedEntries(lang, prefix string) ([]string, map[string]string, error) {
	if err := ensureLoaded(); err != nil {
		return nil, nil, err
	}
	catalog, ok := catalogs[lang]
	if !ok {
		return nil, nil, fmt.Errorf("unknown language %q", lang)
	}
	keys := make([]string, 0)
	for key := range catalog {
		if strings.HasPrefix(key, prefix) {
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)
	return keys, catalog, nil
}

// BootBlob encodes the chosen language's boot.* strings for the Zig boot UI.
//
// Layout (little endian): "USOSLANG", u16 format=1, u16 entry count,
// [8]u8 zero-padded language code, u32 payload length, u32 CRC-32 (IEEE) of
// the payload, then per entry: u8 key length, key (without "boot."), u16 value
// length, UTF-8 value. Entries are sorted by key.
func BootBlob(lang string) ([]byte, error) {
	lang = Normalize(lang)
	if len(lang) > 8 {
		return nil, fmt.Errorf("language code too long: %q", lang)
	}
	keys, catalog, err := prefixedEntries(lang, BootKeyPrefix)
	if err != nil {
		return nil, err
	}
	var payload bytes.Buffer
	for _, key := range keys {
		short := strings.TrimPrefix(key, BootKeyPrefix)
		value := catalog[key]
		if len(short) == 0 || len(short) > 255 || len(value) > 65535 {
			return nil, fmt.Errorf("boot string %s does not fit the blob format", key)
		}
		payload.WriteByte(byte(len(short)))
		payload.WriteString(short)
		_ = binary.Write(&payload, binary.LittleEndian, uint16(len(value)))
		payload.WriteString(value)
	}
	header := make([]byte, bootHeaderSize)
	copy(header[0:8], bootBlobMagic)
	binary.LittleEndian.PutUint16(header[8:10], bootBlobFormat)
	binary.LittleEndian.PutUint16(header[10:12], uint16(len(keys)))
	copy(header[12:20], lang)
	binary.LittleEndian.PutUint32(header[20:24], uint32(payload.Len()))
	binary.LittleEndian.PutUint32(header[24:28], crc32.ChecksumIEEE(payload.Bytes()))
	return append(header, payload.Bytes()...), nil
}

// XPHelperINI encodes the chosen language's xp_pae.* strings as a UTF-16LE
// INI file with BOM, which GetPrivateProfileStringW reads on Windows XP.
func XPHelperINI(lang string) ([]byte, error) {
	lang = Normalize(lang)
	keys, catalog, err := prefixedEntries(lang, XPKeyPrefix)
	if err != nil {
		return nil, err
	}
	var text strings.Builder
	text.WriteString("[xp_pae]\r\nlanguage=" + lang + "\r\n")
	for _, key := range keys {
		value := catalog[key]
		if strings.ContainsAny(value, "\r\n") {
			return nil, fmt.Errorf("%s must be a single line", key)
		}
		text.WriteString(strings.TrimPrefix(key, XPKeyPrefix) + "=" + value + "\r\n")
	}
	units := utf16.Encode([]rune(text.String()))
	out := make([]byte, 2+2*len(units))
	out[0], out[1] = 0xff, 0xfe
	for i, unit := range units {
		binary.LittleEndian.PutUint16(out[2+2*i:], unit)
	}
	return out, nil
}

// BootGlyphGaps lists, per boot.* key, the characters the boot font
// (src/gui/font5x7.zig: printable ASCII 32..126 only) cannot draw.
func BootGlyphGaps(lang string) (map[string][]rune, error) {
	keys, catalog, err := prefixedEntries(Normalize(lang), BootKeyPrefix)
	if err != nil {
		return nil, err
	}
	gaps := map[string][]rune{}
	for _, key := range keys {
		seen := map[rune]bool{}
		for _, r := range catalog[key] {
			if (r < 32 || r > 126) && !seen[r] {
				seen[r] = true
				gaps[key] = append(gaps[key], r)
			}
		}
	}
	return gaps, nil
}
