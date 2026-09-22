//go:build windows

package i18n

import "golang.org/x/sys/windows"

var procGetUserDefaultUILanguage = windows.NewLazySystemDLL("kernel32.dll").NewProc("GetUserDefaultUILanguage")

func systemUILangID() (uint16, bool) {
	if procGetUserDefaultUILanguage.Find() != nil {
		return 0, false
	}
	r, _, _ := procGetUserDefaultUILanguage.Call()
	return uint16(r), r != 0
}
