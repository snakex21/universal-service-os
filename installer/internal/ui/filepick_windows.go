//go:build windows

package ui

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	comdlg32             = windows.NewLazySystemDLL("comdlg32.dll")
	procGetOpenFileNameW = comdlg32.NewProc("GetOpenFileNameW")
)

// openFileNameW is OPENFILENAMEW (commdlg.h).
type openFileNameW struct {
	structSize      uint32
	owner           windows.HWND
	instance        windows.Handle
	filter          *uint16
	customFilter    *uint16
	maxCustomFilter uint32
	filterIndex     uint32
	file            *uint16
	maxFile         uint32
	fileTitle       *uint16
	maxFileTitle    uint32
	initialDir      *uint16
	title           *uint16
	flags           uint32
	fileOffset      uint16
	fileExtension   uint16
	defExt          *uint16
	custData        uintptr
	hook            uintptr
	templateName    *uint16
	reserved        uintptr
	reserved2       uint32
	flagsEx         uint32
}

// pickZipFile shows the Windows "Open" dialog for a .zip file; ok is false
// when the user cancelled.
func pickZipFile(owner windows.HWND, title, filterName string) (string, bool) {
	filter, _ := windows.UTF16FromString(filterName + " (*.zip)")
	pattern, _ := windows.UTF16FromString("*.zip")
	filter = append(filter, pattern...)
	filter = append(filter, 0) // double NUL ends the list
	buffer := make([]uint16, 32768)
	const (
		ofnHideReadOnly  = 0x00000004
		ofnNoChangeDir   = 0x00000008
		ofnPathMustExist = 0x00000800
		ofnFileMustExist = 0x00001000
		ofnExplorer      = 0x00080000
	)
	ofn := openFileNameW{
		owner:       owner,
		filter:      &filter[0],
		filterIndex: 1,
		file:        &buffer[0],
		maxFile:     uint32(len(buffer)),
		title:       utf16Ptr(title),
		flags:       ofnHideReadOnly | ofnNoChangeDir | ofnPathMustExist | ofnFileMustExist | ofnExplorer,
	}
	ofn.structSize = uint32(unsafe.Sizeof(ofn))
	r, _, _ := procGetOpenFileNameW.Call(uintptr(unsafe.Pointer(&ofn)))
	if r == 0 {
		return "", false
	}
	return windows.UTF16ToString(buffer), true
}
