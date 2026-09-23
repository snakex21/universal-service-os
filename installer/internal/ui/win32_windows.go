//go:build windows

package ui

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

// Minimal Win32/GDI/shell bindings (no cgo). Optional APIs are probed with
// Find() so the program degrades instead of failing to start.
var (
	user32   = windows.NewLazySystemDLL("user32.dll")
	gdi32    = windows.NewLazySystemDLL("gdi32.dll")
	kernel32 = windows.NewLazySystemDLL("kernel32.dll")
	shell32  = windows.NewLazySystemDLL("shell32.dll")
	dwmapi   = windows.NewLazySystemDLL("dwmapi.dll")
	uxtheme  = windows.NewLazySystemDLL("uxtheme.dll")
	comctl32 = windows.NewLazySystemDLL("comctl32.dll")

	procRegisterClassExW              = user32.NewProc("RegisterClassExW")
	procCreateWindowExW               = user32.NewProc("CreateWindowExW")
	procDefWindowProcW                = user32.NewProc("DefWindowProcW")
	procGetMessageW                   = user32.NewProc("GetMessageW")
	procTranslateMessage              = user32.NewProc("TranslateMessage")
	procDispatchMessageW              = user32.NewProc("DispatchMessageW")
	procPostQuitMessage               = user32.NewProc("PostQuitMessage")
	procPostMessageW                  = user32.NewProc("PostMessageW")
	procSendMessageW                  = user32.NewProc("SendMessageW")
	procBeginPaint                    = user32.NewProc("BeginPaint")
	procEndPaint                      = user32.NewProc("EndPaint")
	procGetClientRect                 = user32.NewProc("GetClientRect")
	procGetWindowRect                 = user32.NewProc("GetWindowRect")
	procInvalidateRect                = user32.NewProc("InvalidateRect")
	procUpdateWindow                  = user32.NewProc("UpdateWindow")
	procLoadCursorW                   = user32.NewProc("LoadCursorW")
	procSetCursor                     = user32.NewProc("SetCursor")
	procShowWindow                    = user32.NewProc("ShowWindow")
	procSetWindowPos                  = user32.NewProc("SetWindowPos")
	procSetWindowTextW                = user32.NewProc("SetWindowTextW")
	procGetWindowTextW                = user32.NewProc("GetWindowTextW")
	procGetWindowTextLengthW          = user32.NewProc("GetWindowTextLengthW")
	procDestroyWindow                 = user32.NewProc("DestroyWindow")
	procDrawTextW                     = user32.NewProc("DrawTextW")
	procTrackMouseEvent               = user32.NewProc("TrackMouseEvent")
	procAdjustWindowRectEx            = user32.NewProc("AdjustWindowRectEx")
	procAdjustWindowRectExForDpi      = user32.NewProc("AdjustWindowRectExForDpi")
	procSetProcessDPIAware            = user32.NewProc("SetProcessDPIAware")
	procSetProcessDpiAwarenessContext = user32.NewProc("SetProcessDpiAwarenessContext")
	procGetDpiForWindow               = user32.NewProc("GetDpiForWindow")
	procGetDpiForSystem               = user32.NewProc("GetDpiForSystem")
	procGetSystemMetricsForDpi        = user32.NewProc("GetSystemMetricsForDpi")
	procGetSystemMetrics              = user32.NewProc("GetSystemMetrics")
	procSetFocus                      = user32.NewProc("SetFocus")
	procGetFocus                      = user32.NewProc("GetFocus")
	procSetTimer                      = user32.NewProc("SetTimer")
	procKillTimer                     = user32.NewProc("KillTimer")
	procSetCapture                    = user32.NewProc("SetCapture")
	procReleaseCapture                = user32.NewProc("ReleaseCapture")
	procScreenToClient                = user32.NewProc("ScreenToClient")
	procMonitorFromWindow             = user32.NewProc("MonitorFromWindow")
	procGetMonitorInfoW               = user32.NewProc("GetMonitorInfoW")
	procGetKeyState                   = user32.NewProc("GetKeyState")
	procDrawIconEx                    = user32.NewProc("DrawIconEx")
	procDestroyIcon                   = user32.NewProc("DestroyIcon")
	procCreateIconIndirect            = user32.NewProc("CreateIconIndirect")
	procPrintWindow                   = user32.NewProc("PrintWindow")
	procGetDC                         = user32.NewProc("GetDC")
	procReleaseDC                     = user32.NewProc("ReleaseDC")
	procMessageBeep                   = user32.NewProc("MessageBeep")
	procSetForegroundWindow           = user32.NewProc("SetForegroundWindow")
	procIsWindowVisible               = user32.NewProc("IsWindowVisible")

	procCreateCompatibleDC     = gdi32.NewProc("CreateCompatibleDC")
	procCreateCompatibleBitmap = gdi32.NewProc("CreateCompatibleBitmap")
	procCreateDIBSection       = gdi32.NewProc("CreateDIBSection")
	procCreateBitmap           = gdi32.NewProc("CreateBitmap")
	procSelectObject           = gdi32.NewProc("SelectObject")
	procDeleteObject           = gdi32.NewProc("DeleteObject")
	procDeleteDC               = gdi32.NewProc("DeleteDC")
	procCreateFontW            = gdi32.NewProc("CreateFontW")
	procSetBkMode              = gdi32.NewProc("SetBkMode")
	procSetBkColor             = gdi32.NewProc("SetBkColor")
	procSetTextColor           = gdi32.NewProc("SetTextColor")
	procStretchDIBits          = gdi32.NewProc("StretchDIBits")
	procGdiFlush               = gdi32.NewProc("GdiFlush")
	procCreateSolidBrush       = gdi32.NewProc("CreateSolidBrush")
	procCreateRectRgn          = gdi32.NewProc("CreateRectRgn")
	procSelectClipRgn          = gdi32.NewProc("SelectClipRgn")
	procGetTextExtentPoint32W  = gdi32.NewProc("GetTextExtentPoint32W")
	procGetTextMetricsW        = gdi32.NewProc("GetTextMetricsW")
	procGetDIBits              = gdi32.NewProc("GetDIBits")

	procGetModuleHandleW        = kernel32.NewProc("GetModuleHandleW")
	procK32GetProcessMemoryInfo = kernel32.NewProc("K32GetProcessMemoryInfo")

	procSHGetStockIconInfo = shell32.NewProc("SHGetStockIconInfo")
	procSHDefExtractIconW  = shell32.NewProc("SHDefExtractIconW")

	procDwmSetWindowAttribute = dwmapi.NewProc("DwmSetWindowAttribute")
	procSetWindowTheme        = uxtheme.NewProc("SetWindowTheme")
	procInitCommonControlsEx  = comctl32.NewProc("InitCommonControlsEx")
)

const (
	wmCreate           = 0x0001
	wmDestroy          = 0x0002
	wmSize             = 0x0005
	wmSetFocus         = 0x0007
	wmKillFocus        = 0x0008
	wmSetText          = 0x000C
	wmPaint            = 0x000F
	wmClose            = 0x0010
	wmQueryEndSession  = 0x0011
	wmEraseBkgnd       = 0x0014
	wmActivateApp      = 0x001C
	wmSetCursor        = 0x0020
	wmGetMinMaxInfo    = 0x0024
	wmSetFont          = 0x0030
	wmSetIcon          = 0x0080
	wmKeyDown          = 0x0100
	wmKeyUp            = 0x0101
	wmChar             = 0x0102
	wmSysKeyDown       = 0x0104
	wmSysChar          = 0x0106
	wmCommand          = 0x0111
	wmTimer            = 0x0113
	wmCtlColorEdit     = 0x0133
	wmCtlColorStatic   = 0x0138
	wmMouseMove        = 0x0200
	wmLButtonDown      = 0x0201
	wmLButtonUp        = 0x0202
	wmLButtonDblClk    = 0x0203
	wmMouseWheel       = 0x020A
	wmCaptureChanged   = 0x0215
	wmMouseLeave       = 0x02A3
	wmDpiChanged       = 0x02E0
	wmApp              = 0x8000
	wmAppRun           = wmApp + 1
	enChange           = 0x0300
	enSetFocus         = 0x0100
	enKillFocus        = 0x0200
	emSetSel           = 0x00B1
	emScrollCaret      = 0x00B7
	emLineScroll       = 0x00B6
	emGetLineCount     = 0x00BA
	emReplaceSel       = 0x00C2
	emSetLimitText     = 0x00C5
	emSetMargins       = 0x00D3
	emSetCueBanner     = 0x1501
	ecLeftMargin       = 0x0001
	ecRightMargin      = 0x0002
	esMultiline        = 0x0004
	esAutoVScroll      = 0x0040
	esAutoHScroll      = 0x0080
	esNoHideSel        = 0x0100
	esReadOnly         = 0x0800
	wsChild            = 0x40000000
	wsVisible          = 0x10000000
	wsClipChildren     = 0x02000000
	wsVScroll          = 0x00200000
	wsTabStop          = 0x00010000
	wsOverlappedWindow = 0x00CF0000
	cwUseDefault       = 0x80000000
	csHRedraw          = 0x0002
	csVRedraw          = 0x0001
	swHide             = 0
	swShow             = 5
	swShowNA           = 8
	swpNoSize          = 0x0001
	swpNoMove          = 0x0002
	swpNoZOrder        = 0x0004
	swpNoActivate      = 0x0010
	swpShowWindow      = 0x0040
	swpHideWindow      = 0x0080
	idcArrow           = 32512
	idcHand            = 32649
	idcIBeam           = 32513
	tmeLeave           = 0x00000002
	htClient           = 1
	iconSmall          = 0
	iconBig            = 1
	smCxIcon           = 11
	smCxSmIcon         = 49
	monitorNearest     = 2
	pwRenderFull       = 2
	diNormal           = 0x0003
	iccStandardClasses = 0x00004000
	wheelDelta         = 120

	dwmaUseImmersiveDarkModeOld = 19
	dwmaUseImmersiveDarkMode    = 20
	dwmaBorderColor             = 34
	dwmaCaptionColor            = 35
	dwmaTextColor               = 36

	vkBack    = 0x08
	vkTab     = 0x09
	vkReturn  = 0x0D
	vkShift   = 0x10
	vkControl = 0x11
	vkMenu    = 0x12
	vkEscape  = 0x1B
	vkSpace   = 0x20
	vkPrior   = 0x21
	vkNext    = 0x22
	vkEnd     = 0x23
	vkHome    = 0x24
	vkLeft    = 0x25
	vkUp      = 0x26
	vkRight   = 0x27
	vkDown    = 0x28
	vkF5      = 0x74

	dtLeft        = 0x0000
	dtCenter      = 0x0001
	dtRight       = 0x0002
	dtVCenter     = 0x0004
	dtWordBreak   = 0x0010
	dtSingleLine  = 0x0020
	dtCalcRect    = 0x0400
	dtNoPrefix    = 0x0800
	dtEndEllipsis = 0x8000
	dtEditControl = 0x2000

	bkTransparent     = 1
	clearTypeQuality  = 5
	antialiasQuality  = 4
	fwNormal          = 400
	fwSemiBold        = 600
	fwBold            = 700
	defaultCharset    = 1
	dibRGBColors      = 0
	srcCopy           = 0x00CC0020
	biRGB             = 0
	perMonitorAwareV2 = ^uintptr(3) // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 (-4)

	siidDriveRemove   = 7
	siidDriveFixed    = 8
	shgsiIconLocation = 0
)

type point struct{ X, Y int32 }

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

type trackMouseEvent struct {
	Size      uint32
	Flags     uint32
	Track     windows.HWND
	HoverTime uint32
}

type minMaxInfo struct {
	Reserved     point
	MaxSize      point
	MaxPosition  point
	MinTrackSize point
	MaxTrackSize point
}

type monitorInfo struct {
	Size    uint32
	Monitor rect
	Work    rect
	Flags   uint32
}

type iconInfo struct {
	IsIcon   int32
	XHotspot uint32
	YHotspot uint32
	Mask     windows.Handle
	Color    windows.Handle
}

type stockIconInfo struct {
	Size      uint32
	Icon      windows.Handle
	SysIndex  int32
	IconIndex int32
	Path      [260]uint16
}

type initCommonControlsEx struct {
	Size uint32
	ICC  uint32
}

type textMetric struct {
	Height           int32
	Ascent           int32
	Descent          int32
	InternalLeading  int32
	ExternalLeading  int32
	AveCharWidth     int32
	MaxCharWidth     int32
	Weight           int32
	Overhang         int32
	DigitizedAspectX int32
	DigitizedAspectY int32
	FirstChar        uint16
	LastChar         uint16
	DefaultChar      uint16
	BreakChar        uint16
	Italic           byte
	Underlined       byte
	StruckOut        byte
	PitchAndFamily   byte
	CharSet          byte
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

func utf16Ptr(s string) *uint16 {
	p, err := windows.UTF16PtrFromString(s)
	if err != nil {
		p, _ = windows.UTF16PtrFromString("")
	}
	return p
}

func loWord(v uintptr) int32 { return int32(int16(v & 0xffff)) }
func hiWord(v uintptr) int32 { return int32(int16((v >> 16) & 0xffff)) }

func clientRect(hwnd windows.HWND) rect {
	var r rect
	procGetClientRect.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&r)))
	return r
}

func windowRect(hwnd windows.HWND) rect {
	var r rect
	procGetWindowRect.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&r)))
	return r
}

func invalidate(hwnd windows.HWND) {
	procInvalidateRect.Call(uintptr(hwnd), 0, 0)
}

func sendMessage(hwnd windows.HWND, message uint32, wParam, lParam uintptr) uintptr {
	r, _, _ := procSendMessageW.Call(uintptr(hwnd), uintptr(message), wParam, lParam)
	return r
}

func keyDown(vk uintptr) bool {
	r, _, _ := procGetKeyState.Call(vk)
	return int16(r) < 0
}

func getFocus() windows.HWND {
	r, _, _ := procGetFocus.Call()
	return windows.HWND(r)
}

func setFocus(hwnd windows.HWND) {
	procSetFocus.Call(uintptr(hwnd))
}

// enableDPIAwareness prefers per-monitor v2 (also declared in the manifest)
// and falls back to system awareness so text is never bitmap-stretched.
func enableDPIAwareness() {
	if procSetProcessDpiAwarenessContext.Find() == nil {
		if r, _, _ := procSetProcessDpiAwarenessContext.Call(perMonitorAwareV2); r != 0 {
			return
		}
	}
	if procSetProcessDPIAware.Find() == nil {
		procSetProcessDPIAware.Call()
	}
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

func systemMetric(index int, dpi uint32) int32 {
	if procGetSystemMetricsForDpi.Find() == nil {
		r, _, _ := procGetSystemMetricsForDpi.Call(uintptr(index), uintptr(dpi))
		return int32(r)
	}
	r, _, _ := procGetSystemMetrics.Call(uintptr(index))
	return int32(r)
}

func adjustWindowRect(r *rect, style uint32, dpi uint32) {
	if procAdjustWindowRectExForDpi.Find() == nil {
		procAdjustWindowRectExForDpi.Call(uintptr(unsafe.Pointer(r)), uintptr(style), 0, 0, uintptr(dpi))
		return
	}
	procAdjustWindowRectEx.Call(uintptr(unsafe.Pointer(r)), uintptr(style), 0, 0)
}

func monitorWorkArea(hwnd windows.HWND) (rect, bool) {
	monitor, _, _ := procMonitorFromWindow.Call(uintptr(hwnd), monitorNearest)
	if monitor == 0 {
		return rect{}, false
	}
	info := monitorInfo{Size: uint32(unsafe.Sizeof(monitorInfo{}))}
	if r, _, _ := procGetMonitorInfoW.Call(monitor, uintptr(unsafe.Pointer(&info))); r == 0 {
		return rect{}, false
	}
	return info.Work, true
}

// useDarkTitleBar asks DWM for the dark caption (Windows 10 20H1+ attribute
// 20, 1809-1909 attribute 19) and, on Windows 11, tints caption and border.
func useDarkTitleBar(hwnd windows.HWND) {
	if procDwmSetWindowAttribute.Find() != nil {
		return
	}
	on := int32(1)
	if r, _, _ := procDwmSetWindowAttribute.Call(uintptr(hwnd), dwmaUseImmersiveDarkMode, uintptr(unsafe.Pointer(&on)), 4); r != 0 {
		procDwmSetWindowAttribute.Call(uintptr(hwnd), dwmaUseImmersiveDarkModeOld, uintptr(unsafe.Pointer(&on)), 4)
	}
	caption := uint32(theme.Header.colorref())
	procDwmSetWindowAttribute.Call(uintptr(hwnd), dwmaCaptionColor, uintptr(unsafe.Pointer(&caption)), 4)
	border := uint32(theme.Border.colorref())
	procDwmSetWindowAttribute.Call(uintptr(hwnd), dwmaBorderColor, uintptr(unsafe.Pointer(&border)), 4)
}

func setDarkControlTheme(hwnd windows.HWND) {
	if procSetWindowTheme.Find() == nil {
		procSetWindowTheme.Call(uintptr(hwnd), uintptr(unsafe.Pointer(utf16Ptr("DarkMode_Explorer"))), 0)
	}
}

func initCommonControls() {
	if procInitCommonControlsEx.Find() != nil {
		return
	}
	icc := initCommonControlsEx{Size: uint32(unsafe.Sizeof(initCommonControlsEx{})), ICC: iccStandardClasses}
	procInitCommonControlsEx.Call(uintptr(unsafe.Pointer(&icc)))
}

func windowText(hwnd windows.HWND) string {
	n, _, _ := procGetWindowTextLengthW.Call(uintptr(hwnd))
	buf := make([]uint16, n+1)
	procGetWindowTextW.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&buf[0])), n+1)
	return windows.UTF16ToString(buf)
}

// processMemory returns the working set and private bytes in KiB.
func processMemory() (workingSetKiB, privateKiB uint64) {
	var counters processMemoryCounters
	counters.Size = uint32(unsafe.Sizeof(counters))
	procK32GetProcessMemoryInfo.Call(uintptr(windows.CurrentProcess()), uintptr(unsafe.Pointer(&counters)), uintptr(counters.Size))
	return uint64(counters.WorkingSetSize) / 1024, uint64(counters.PagefileUsage) / 1024
}
