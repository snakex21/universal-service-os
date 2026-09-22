//go:build windows

package main

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

// Minimal Win32/GDI bindings (no cgo). Every call goes through x/sys/windows
// lazy procs; optional Windows 10 DPI APIs are probed with Find().
var (
	user32   = windows.NewLazySystemDLL("user32.dll")
	gdi32    = windows.NewLazySystemDLL("gdi32.dll")
	kernel32 = windows.NewLazySystemDLL("kernel32.dll")

	procRegisterClassExW              = user32.NewProc("RegisterClassExW")
	procCreateWindowExW               = user32.NewProc("CreateWindowExW")
	procDefWindowProcW                = user32.NewProc("DefWindowProcW")
	procGetMessageW                   = user32.NewProc("GetMessageW")
	procTranslateMessage              = user32.NewProc("TranslateMessage")
	procDispatchMessageW              = user32.NewProc("DispatchMessageW")
	procPostQuitMessage               = user32.NewProc("PostQuitMessage")
	procBeginPaint                    = user32.NewProc("BeginPaint")
	procEndPaint                      = user32.NewProc("EndPaint")
	procGetClientRect                 = user32.NewProc("GetClientRect")
	procInvalidateRect                = user32.NewProc("InvalidateRect")
	procLoadCursorW                   = user32.NewProc("LoadCursorW")
	procSetCursor                     = user32.NewProc("SetCursor")
	procShowWindow                    = user32.NewProc("ShowWindow")
	procSetWindowPos                  = user32.NewProc("SetWindowPos")
	procSetWindowTextW                = user32.NewProc("SetWindowTextW")
	procDestroyWindow                 = user32.NewProc("DestroyWindow")
	procDrawTextW                     = user32.NewProc("DrawTextW")
	procTrackMouseEvent               = user32.NewProc("TrackMouseEvent")
	procAdjustWindowRectEx            = user32.NewProc("AdjustWindowRectEx")
	procSetProcessDPIAware            = user32.NewProc("SetProcessDPIAware")
	procSetProcessDpiAwarenessContext = user32.NewProc("SetProcessDpiAwarenessContext")
	procGetDpiForWindow               = user32.NewProc("GetDpiForWindow")
	procGetDpiForSystem               = user32.NewProc("GetDpiForSystem")

	procCreateCompatibleDC = gdi32.NewProc("CreateCompatibleDC")
	procCreateDIBSection   = gdi32.NewProc("CreateDIBSection")
	procSelectObject       = gdi32.NewProc("SelectObject")
	procDeleteObject       = gdi32.NewProc("DeleteObject")
	procDeleteDC           = gdi32.NewProc("DeleteDC")
	procCreateFontW        = gdi32.NewProc("CreateFontW")
	procSetBkMode          = gdi32.NewProc("SetBkMode")
	procSetTextColor       = gdi32.NewProc("SetTextColor")
	procStretchDIBits      = gdi32.NewProc("StretchDIBits")
	procGdiFlush           = gdi32.NewProc("GdiFlush")

	procGetModuleHandleW        = kernel32.NewProc("GetModuleHandleW")
	procK32GetProcessMemoryInfo = kernel32.NewProc("K32GetProcessMemoryInfo")
)

const (
	wmDestroy     = 0x0002
	wmSize        = 0x0005
	wmPaint       = 0x000F
	wmClose       = 0x0010
	wmEraseBkgnd  = 0x0014
	wmSetCursor   = 0x0020
	wmKeyDown     = 0x0100
	wmMouseMove   = 0x0200
	wmLButtonDown = 0x0201
	wmLButtonUp   = 0x0202
	wmMouseLeave  = 0x02A3
	wmDpiChanged  = 0x02E0

	vkTab    = 0x09
	vkReturn = 0x0D
	vkEscape = 0x1B
	vkSpace  = 0x20
	vkUp     = 0x26
	vkDown   = 0x28

	wsOverlappedWindow = 0x00CF0000
	cwUseDefault       = 0x80000000
	swShow             = 5
	swpNoZOrder        = 0x0004
	swpNoActivate      = 0x0010
	swpNoMove          = 0x0002
	idcArrow           = 32512
	idcHand            = 32649
	tmeLeave           = 0x00000002

	dtLeft       = 0x0000
	dtVCenter    = 0x0004
	dtRight      = 0x0002
	dtCenter     = 0x0001
	dtSingleLine = 0x0020
	dtWordBreak  = 0x0010
	dtCalcRect   = 0x0400
	dtNoPrefix   = 0x0800
	dtEndEllipse = 0x8000

	transparent       = 1
	clearTypeQuality  = 5
	fwNormal          = 400
	fwSemiBold        = 600
	fwBold            = 700
	defaultCharset    = 1
	dibRGBColors      = 0
	srcCopy           = 0x00CC0020
	biRGB             = 0
	perMonitorAwareV2 = ^uintptr(3) // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
)

type point struct{ X, Y int32 }

type rect struct{ Left, Top, Right, Bottom int32 }

func (r rect) contains(x, y int32) bool {
	return x >= r.Left && x < r.Right && y >= r.Top && y < r.Bottom
}

type wndClassEx struct {
	Size       uint32
	Style      uint32
	WndProc    uintptr
	ClsExtra   int32
	WndExtra   int32
	Instance   windows.Handle
	Icon       windows.Handle
	Cursor     windows.Handle
	Background windows.Handle
	MenuName   *uint16
	ClassName  *uint16
	IconSm     windows.Handle
}

type msg struct {
	Hwnd    windows.HWND
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Pt      point
	Private uint32
}

type paintStruct struct {
	Hdc       windows.Handle
	Erase     int32
	Paint     rect
	Restore   int32
	IncUpdate int32
	Reserved  [32]byte
}

type bitmapInfoHeader struct {
	Size          uint32
	Width         int32
	Height        int32
	Planes        uint16
	BitCount      uint16
	Compression   uint32
	SizeImage     uint32
	XPelsPerMeter int32
	YPelsPerMeter int32
	ClrUsed       uint32
	ClrImportant  uint32
}

type bitmapInfo struct {
	Header bitmapInfoHeader
	Colors [1]uint32
}

type processMemoryCounters struct {
	Size                       uint32
	PageFaultCount             uint32
	PeakWorkingSetSize         uintptr
	WorkingSetSize             uintptr
	QuotaPeakPagedPoolUsage    uintptr
	QuotaPagedPoolUsage        uintptr
	QuotaPeakNonPagedPoolUsage uintptr
	QuotaNonPagedPoolUsage     uintptr
	PagefileUsage              uintptr
	PeakPagefileUsage          uintptr
}

type trackMouseEvent struct {
	Size      uint32
	Flags     uint32
	Track     windows.HWND
	HoverTime uint32
}

func utf16Ptr(s string) *uint16 {
	p, _ := windows.UTF16PtrFromString(s)
	return p
}

func loWord(v uintptr) int32 { return int32(int16(v & 0xffff)) }
func hiWord(v uintptr) int32 { return int32(int16((v >> 16) & 0xffff)) }

func clientRect(hwnd windows.HWND) rect {
	var r rect
	procGetClientRect.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&r)))
	return r
}

func invalidate(hwnd windows.HWND) {
	procInvalidateRect.Call(uintptr(hwnd), 0, 0)
}

// enableDPIAwareness prefers per-monitor v2 (Windows 10 1703+) and falls back
// to system awareness so text is never bitmap-stretched by DWM.
func enableDPIAwareness() string {
	if procSetProcessDpiAwarenessContext.Find() == nil {
		if r, _, _ := procSetProcessDpiAwarenessContext.Call(perMonitorAwareV2); r != 0 {
			return "per-monitor-v2"
		}
	}
	if procSetProcessDPIAware.Find() == nil {
		procSetProcessDPIAware.Call()
		return "system"
	}
	return "unaware"
}

func windowDPI(hwnd windows.HWND) uint32 {
	if procGetDpiForWindow.Find() == nil {
		if r, _, _ := procGetDpiForWindow.Call(uintptr(hwnd)); r != 0 {
			return uint32(r)
		}
	}
	if procGetDpiForSystem.Find() == nil {
		if r, _, _ := procGetDpiForSystem.Call(); r != 0 {
			return uint32(r)
		}
	}
	return 96
}
