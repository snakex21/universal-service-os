//go:build windows

package main

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

// color mirrors src/gui/color.zig; the palette is src/gui/theme.zig.
type color struct{ R, G, B uint8 }

var theme = struct {
	Background, Panel, PanelAlt, Text, Muted, Accent, Selected, Border, Disabled color
}{
	Background: color{0x08, 0x0d, 0x14},
	Panel:      color{0x10, 0x19, 0x23},
	PanelAlt:   color{0x17, 0x25, 0x35},
	Text:       color{0xef, 0xfc, 0xff},
	Muted:      color{0x8f, 0xa8, 0xb8},
	Accent:     color{0x43, 0xd8, 0xe8},
	Selected:   color{0x14, 0x5b, 0x7a},
	Border:     color{0x29, 0x44, 0x57},
	Disabled:   color{0x3a, 0x42, 0x4c},
}

func (c color) pixel() uint32     { return uint32(c.B) | uint32(c.G)<<8 | uint32(c.R)<<16 }
func (c color) colorref() uintptr { return uintptr(c.R) | uintptr(c.G)<<8 | uintptr(c.B)<<16 }

// canvas is a top-down 32bpp DIB section: shapes are written directly into
// its pixels (like the boot UI Surface), text is drawn by GDI into the same
// bitmap (full Unicode, ClearType), and the result is blitted with
// StretchDIBits.
type canvas struct {
	dc     windows.Handle
	bitmap windows.Handle
	old    uintptr
	pixels []uint32
	width  int32
	height int32
	info   bitmapInfo
}

func newCanvas(width, height int32) *canvas {
	if width < 1 {
		width = 1
	}
	if height < 1 {
		height = 1
	}
	c := &canvas{width: width, height: height}
	c.info.Header = bitmapInfoHeader{Size: uint32(unsafe.Sizeof(bitmapInfoHeader{})), Width: width, Height: -height, Planes: 1, BitCount: 32, Compression: biRGB}
	dc, _, _ := procCreateCompatibleDC.Call(0)
	var bits unsafe.Pointer
	bitmap, _, _ := procCreateDIBSection.Call(dc, uintptr(unsafe.Pointer(&c.info)), dibRGBColors, uintptr(unsafe.Pointer(&bits)), 0, 0)
	c.dc, c.bitmap = windows.Handle(dc), windows.Handle(bitmap)
	c.old, _, _ = procSelectObject.Call(dc, bitmap)
	c.pixels = unsafe.Slice((*uint32)(bits), int(width)*int(height))
	procSetBkMode.Call(dc, transparent)
	return c
}

func (c *canvas) release() {
	if c == nil {
		return
	}
	procSelectObject.Call(uintptr(c.dc), c.old)
	procDeleteObject.Call(uintptr(c.bitmap))
	procDeleteDC.Call(uintptr(c.dc))
}

func (c *canvas) fill(r rect, col color) {
	procGdiFlush.Call() // GDI text must land before direct pixel writes
	x0, y0 := max(r.Left, 0), max(r.Top, 0)
	x1, y1 := min(r.Right, c.width), min(r.Bottom, c.height)
	p := col.pixel()
	for y := y0; y < y1; y++ {
		row := c.pixels[int(y)*int(c.width) : int(y+1)*int(c.width)]
		for x := x0; x < x1; x++ {
			row[x] = p
		}
	}
}

func (c *canvas) border(r rect, thickness int32, col color) {
	c.fill(rect{r.Left, r.Top, r.Right, r.Top + thickness}, col)
	c.fill(rect{r.Left, r.Bottom - thickness, r.Right, r.Bottom}, col)
	c.fill(rect{r.Left, r.Top, r.Left + thickness, r.Bottom}, col)
	c.fill(rect{r.Right - thickness, r.Top, r.Right, r.Bottom}, col)
}

func (c *canvas) text(font windows.Handle, s string, r rect, col color, flags uintptr) {
	procSelectObject.Call(uintptr(c.dc), uintptr(font))
	procSetTextColor.Call(uintptr(c.dc), col.colorref())
	u, _ := windows.UTF16FromString(s)
	procDrawTextW.Call(uintptr(c.dc), uintptr(unsafe.Pointer(&u[0])), uintptr(len(u)-1), uintptr(unsafe.Pointer(&r)), flags|dtNoPrefix)
}

// measure returns the height DrawTextW needs to wrap s into width.
func (c *canvas) measure(font windows.Handle, s string, width int32) int32 {
	procSelectObject.Call(uintptr(c.dc), uintptr(font))
	r := rect{0, 0, width, 0}
	u, _ := windows.UTF16FromString(s)
	procDrawTextW.Call(uintptr(c.dc), uintptr(unsafe.Pointer(&u[0])), uintptr(len(u)-1), uintptr(unsafe.Pointer(&r)), dtWordBreak|dtCalcRect|dtNoPrefix)
	return r.Bottom
}

func (c *canvas) blit(hdc windows.Handle) {
	procGdiFlush.Call()
	procStretchDIBits.Call(uintptr(hdc), 0, 0, uintptr(c.width), uintptr(c.height), 0, 0, uintptr(c.width), uintptr(c.height),
		uintptr(unsafe.Pointer(&c.pixels[0])), uintptr(unsafe.Pointer(&c.info)), dibRGBColors, srcCopy)
}

func createFont(pixelHeight int32, weight int32) windows.Handle {
	h, _, _ := procCreateFontW.Call(uintptr(-pixelHeight), 0, 0, 0, uintptr(weight), 0, 0, 0, defaultCharset, 0, 0, clearTypeQuality, 0, uintptr(unsafe.Pointer(utf16Ptr("Segoe UI"))))
	return windows.Handle(h)
}
