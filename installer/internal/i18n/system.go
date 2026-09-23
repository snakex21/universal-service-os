package i18n

// primaryLanguageTags maps Windows primary language IDs (LANGID & 0x3ff) to
// BCP 47 tags. Tags without an embedded catalog normalize (via Normalize and
// its aliases) to the closest catalog or to Fallback.
var primaryLanguageTags = map[uint16]string{
	0x02: "bg", 0x05: "cs", 0x06: "da", 0x07: "de", 0x08: "el", 0x09: "en",
	0x0a: "es", 0x0b: "fi", 0x0c: "fr", 0x0e: "hu", 0x10: "it", 0x11: "ja",
	0x12: "ko", 0x13: "nl", 0x14: "nb", 0x15: "pl", 0x16: "pt", 0x18: "ro",
	0x19: "ru", 0x1a: "hr", 0x1b: "sk", 0x1d: "sv", 0x1f: "tr", 0x22: "uk",
	0x24: "sl", 0x25: "et", 0x26: "lv", 0x27: "lt",
}

// Full LANGIDs whose primary language is shared by several catalogs.
var windowsLangIDTags = map[uint16]string{
	0x0416: "pt-BR", 0x0816: "pt-PT",
	0x0414: "nb-NO", 0x0814: "nn-NO",
	// LANG_CROATIAN / LANG_SERBIAN / LANG_BOSNIAN all use primary 0x1a.
	0x041a: "hr-HR", 0x101a: "hr-BA",
	0x081a: "sr-Latn-CS", 0x0c1a: "sr-Cyrl-CS",
	0x181a: "sr-Latn-BA", 0x1c1a: "sr-Cyrl-BA",
	0x241a: "sr-Latn-RS", 0x281a: "sr-Cyrl-RS",
	0x2c1a: "sr-Latn-ME", 0x301a: "sr-Cyrl-ME",
	0x7c1a: "sr", 0x6c1a: "sr-Cyrl", 0x701a: "sr-Latn",
	0x141a: "bs-Latn-BA", 0x201a: "bs-Cyrl-BA",
}

// WindowsLangIDTag returns the BCP 47 tag for a Windows LANGID ("" when the
// language is unknown).
func WindowsLangIDTag(langID uint16) string {
	if tag, ok := windowsLangIDTags[langID]; ok {
		return tag
	}
	return primaryLanguageTags[langID&0x3ff]
}

// FromWindowsLangID maps a Windows LANGID to an embedded catalog code.
func FromWindowsLangID(langID uint16) string {
	return Normalize(WindowsLangIDTag(langID))
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
