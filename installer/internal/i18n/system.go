package i18n

// primaryLanguageCodes maps Windows primary language IDs (LANGID & 0x3ff) to
// ISO 639-1 codes. Codes without an embedded catalog normalize to Fallback.
var primaryLanguageCodes = map[uint16]string{
	0x05: "cs", 0x06: "da", 0x07: "de", 0x08: "el", 0x09: "en", 0x0a: "es",
	0x0b: "fi", 0x0c: "fr", 0x0e: "hu", 0x10: "it", 0x11: "ja", 0x12: "ko",
	0x13: "nl", 0x14: "nb", 0x15: "pl", 0x16: "pt", 0x18: "ro", 0x19: "ru",
	0x1a: "hr", 0x1b: "sk", 0x1d: "sv", 0x1f: "tr", 0x22: "uk", 0x24: "sl",
	0x25: "et", 0x26: "lv", 0x27: "lt",
}

// FromWindowsLangID maps a Windows LANGID to an embedded catalog code.
func FromWindowsLangID(langID uint16) string {
	return Normalize(primaryLanguageCodes[langID&0x3ff])
}

// SystemLanguage returns the catalog matching the host UI language, or
// Fallback when the host language has no catalog or cannot be read.
func SystemLanguage() string {
	langID, ok := systemUILangID()
	if !ok {
		return Fallback
	}
	return FromWindowsLangID(langID)
}
