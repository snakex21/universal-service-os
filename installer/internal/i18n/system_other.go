//go:build !windows

package i18n

func systemUILangID() (uint16, bool) { return 0, false }
