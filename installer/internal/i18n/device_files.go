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
	LinuxLangPath  = "EFI/USOS/lang.cpio"
	XPHelperPath   = "EFI/USOS/lang-xp.ini"
	WinPEPath      = "EFI/USOS/lang-winpe.ini"
	BootKeyPrefix  = "boot."
	XPKeyPrefix    = "xp_pae."
	WinPEKeyPrefix = "winpe."
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
	winpe, err := WinPEINI(lang)
	if err != nil {
		return nil, err
	}
	return []DeviceFile{
		{Path: SettingsPath, Data: SettingsINI(lang)},
		{Path: BootBlobPath, Data: boot},
		{Path: LinuxLangPath, Data: LangCPIO(boot)},
		{Path: XPHelperPath, Data: xp},
		{Path: WinPEPath, Data: winpe},
	}, nil
}

// SettingsINI is the language record read by USOS components on the drive.
func SettingsINI(lang string) []byte {
	return []byte("[ui]\r\nlanguage=" + Normalize(lang) + "\r\n")
}

// MergeSettingsINI sets [ui] language= in an existing usos-settings.ini and
// keeps every other section, key, comment and line (e.g. the boot menu's
// wheel_invert= and touch_rotation=, which may be added by hand). An empty
// or missing file yields SettingsINI(lang).
func MergeSettingsINI(existing []byte, lang string) []byte {
	if len(strings.TrimSpace(string(existing))) == 0 {
		return SettingsINI(lang)
	}
	value := "language=" + Normalize(lang)
	lines := strings.Split(strings.ReplaceAll(string(existing), "\r\n", "\n"), "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	section, uiEnd, replaced := "", -1, false
	for i, raw := range lines {
		line := strings.TrimSpace(raw)
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.ToLower(line[1 : len(line)-1])
			continue
		}
		if section != "ui" {
			continue
		}
		uiEnd = i
		if key, _, ok := strings.Cut(line, "="); ok && strings.EqualFold(strings.TrimSpace(key), "language") {
			if !replaced {
				lines[i] = value
				replaced = true
			}
		}
	}
	if !replaced {
		header := -1
		for i, raw := range lines {
			if strings.EqualFold(strings.TrimSpace(raw), "[ui]") {
				header = i
				break
			}
		}
		if header < 0 {
			lines = append([]string{"[ui]", value}, lines...)
		} else {
			at := header + 1
			if uiEnd >= at {
				at = uiEnd + 1
			}
			lines = append(lines[:at], append([]string{value}, lines[at:]...)...)
		}
	}
	return []byte(strings.Join(lines, "\r\n") + "\r\n")
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

// WinPEINI encodes the chosen language's winpe.* strings (the USOS dialogs
// shown inside Windows PE: Setup cancelled or failed, the KMDF and Vista
// checks) as a UTF-16LE INI file with BOM. The WinPE helpers find it on the
// source ESP and parse it themselves, so a value may span lines: a newline
// is stored as the two characters \n and a backslash as \\.
func WinPEINI(lang string) ([]byte, error) {
	lang = Normalize(lang)
	keys, catalog, err := prefixedEntries(lang, WinPEKeyPrefix)
	if err != nil {
		return nil, err
	}
	escape := strings.NewReplacer(`\`, `\\`, "\n", `\n`, "\r", "")
	var text strings.Builder
	text.WriteString("[winpe]\r\nlanguage=" + lang + "\r\n")
	for _, key := range keys {
		text.WriteString(strings.TrimPrefix(key, WinPEKeyPrefix) + "=" + escape.Replace(catalog[key]) + "\r\n")
	}
	units := utf16.Encode([]rune(text.String()))
	out := make([]byte, 2+2*len(units))
	out[0], out[1] = 0xff, 0xfe
	for i, unit := range units {
		binary.LittleEndian.PutUint16(out[2+2*i:], unit)
	}
	return out, nil
}

// BootFontCoverage returns the codepoints of a USOS boot font pack
// (src/gui/fonts/usos-font.bin, written by tools/usos_font_gen.py).
func BootFontCoverage(pack []byte) (map[rune]bool, error) {
	const header = 32
	if len(pack) < header || string(pack[:8]) != "USOSFONT" {
		return nil, fmt.Errorf("not a USOS font pack")
	}
	if binary.LittleEndian.Uint16(pack[8:10]) != 1 {
		return nil, fmt.Errorf("unsupported font pack version")
	}
	payload := pack[header:]
	if binary.LittleEndian.Uint32(pack[12:16]) != uint32(len(payload)) || crc32.ChecksumIEEE(payload) != binary.LittleEndian.Uint32(pack[16:20]) {
		return nil, fmt.Errorf("font pack length/CRC mismatch")
	}
	count := int(binary.LittleEndian.Uint16(pack[20:22]))
	if len(payload) < 2*count {
		return nil, fmt.Errorf("font pack codepoint table truncated")
	}
	coverage := make(map[rune]bool, count)
	for i := 0; i < count; i++ {
		coverage[rune(binary.LittleEndian.Uint16(payload[2*i:]))] = true
	}
	return coverage, nil
}

// BootGlyphGaps lists, per boot.* key, the characters the boot font pack
// cannot draw. Newlines are layout, not glyphs.
func BootGlyphGaps(lang string, coverage map[rune]bool) (map[string][]rune, error) {
	keys, catalog, err := prefixedEntries(Normalize(lang), BootKeyPrefix)
	if err != nil {
		return nil, err
	}
	gaps := map[string][]rune{}
	for _, key := range keys {
		seen := map[rune]bool{}
		for _, r := range catalog[key] {
			if r != '\n' && !coverage[r] && !seen[r] {
				seen[r] = true
				gaps[key] = append(gaps[key], r)
			}
		}
	}
	return gaps, nil
}

// LangCPIO wraps lang.bin as etc/usos/lang.bin in an uncompressed newc
// archive. The micro-Linux loaders (systemd-boot, the XP EFI stub path and
// the BIOS Core) pass it as a second initrd, so usos-fb-ui has the chosen
// language from its first frame, before the ESP is mounted.
func LangCPIO(langBin []byte) []byte {
	var out bytes.Buffer
	ino := uint32(1)
	entry := func(name string, mode uint32, data []byte) {
		fmt.Fprintf(&out, "070701%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X",
			ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(name)+1, 0)
		ino++
		out.WriteString(name)
		out.WriteByte(0)
		for out.Len()%4 != 0 {
			out.WriteByte(0)
		}
		out.Write(data)
		for out.Len()%4 != 0 {
			out.WriteByte(0)
		}
	}
	entry("etc", 0o040755, nil)
	entry("etc/usos", 0o040755, nil)
	entry("etc/usos/lang.bin", 0o100644, langBin)
	entry("TRAILER!!!", 0, nil)
	for out.Len()%512 != 0 {
		out.WriteByte(0)
	}
	return out.Bytes()
}
