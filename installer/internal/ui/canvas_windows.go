//go:build windows

package ui

import (
	"image"
	"math"
	"unsafe"

	"golang.org/x/sys/windows"
)

// canvas is a top-down 32bpp DIB section. Shapes are rasterised directly into
// its pixels with analytic anti-aliasing (signed distance coverage), text and
// icons are drawn by GDI into the same bitmap, and the frame is blitted to the
// window in one StretchDIBits call, so nothing flickers.
type canvas struct {
	dc     windows.Handle
	bitmap windows.Handle
	old    uintptr
	pixels []uint32
	width  int32
	height int32
	info   bitmapInfo
	clip   rect
	clips  []rect
	dirty  bool // GDI has drawn since the last flush
}

func newCanvas(width, height int32) *canvas {
	width, height = max(width, 1), max(height, 1)
	c := &canvas{width: width, height: height}
	c.info.Header = bitmapInfoHeader{Size: uint32(unsafe.Sizeof(bitmapInfoHeader{})), Width: width, Height: -height, Planes: 1, BitCount: 32, Compression: biRGB}
	dc, _, _ := procCreateCompatibleDC.Call(0)
	var bits unsafe.Pointer
	bitmap, _, _ := procCreateDIBSection.Call(dc, uintptr(unsafe.Pointer(&c.info)), dibRGBColors, uintptr(unsafe.Pointer(&bits)), 0, 0)
	c.dc, c.bitmap = windows.Handle(dc), windows.Handle(bitmap)
	c.old, _, _ = procSelectObject.Call(dc, bitmap)
	c.pixels = unsafe.Slice((*uint32)(bits), int(width)*int(height))
	procSetBkMode.Call(dc, bkTransparent)
	c.clip = rect{0, 0, width, height}
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

// flush makes pending GDI output visible before direct pixel access.
func (c *canvas) flush() {
	if c.dirty {
		procGdiFlush.Call()
		c.dirty = false
	}
}

func (c *canvas) pushClip(r rect) {
	c.clips = append(c.clips, c.clip)
	c.setClip(c.clip.intersect(r))
}

func (c *canvas) popClip() {
	if n := len(c.clips); n > 0 {
		c.setClip(c.clips[n-1])
		c.clips = c.clips[:n-1]
	}
}

func (c *canvas) setClip(r rect) {
	c.clip = r
	region, _, _ := procCreateRectRgn.Call(uintptr(r.Left), uintptr(r.Top), uintptr(r.Right), uintptr(r.Bottom))
	procSelectClipRgn.Call(uintptr(c.dc), region)
	procDeleteObject.Call(region)
}

func (c *canvas) resetClip() {
	c.clips = c.clips[:0]
	c.clip = rect{0, 0, c.width, c.height}
	procSelectClipRgn.Call(uintptr(c.dc), 0)
}

func (c *canvas) fill(r rect, col color) {
	c.flush()
	r = r.intersect(c.clip)
	if r.empty() {
		return
	}
	p := col.pixel()
	for y := r.Top; y < r.Bottom; y++ {
		row := c.pixels[int(y)*int(c.width) : int(y+1)*int(c.width)]
		for x := r.Left; x < r.Right; x++ {
			row[x] = p
		}
	}
}

func (c *canvas) blend(x, y int32, col color, a float64) {
	if a <= 0 {
		return
	}
	i := int(y)*int(c.width) + int(x)
	if a >= 1 {
		c.pixels[i] = col.pixel()
		return
	}
	d := c.pixels[i]
	db, dg, dr := float64(d&0xff), float64((d>>8)&0xff), float64((d>>16)&0xff)
	nb := uint32(db + (float64(col.B)-db)*a + 0.5)
	ng := uint32(dg + (float64(col.G)-dg)*a + 0.5)
	nr := uint32(dr + (float64(col.R)-dr)*a + 0.5)
	c.pixels[i] = nb | ng<<8 | nr<<16
}

func coverage(d float64) float64 {
	return math.Max(0, math.Min(1, 0.5-d))
}

// roundRectSDF is the signed distance from (x, y) to a rounded rectangle.
func roundRectSDF(x, y float64, r rect, radius float64) float64 {
	cx := (float64(r.Left) + float64(r.Right)) / 2
	cy := (float64(r.Top) + float64(r.Bottom)) / 2
	hw := float64(r.w())/2 - radius
	hh := float64(r.h())/2 - radius
	qx := math.Abs(x-cx) - hw
	qy := math.Abs(y-cy) - hh
	return math.Hypot(math.Max(qx, 0), math.Max(qy, 0)) + math.Min(math.Max(qx, qy), 0) - radius
}

// roundRect fills r with anti-aliased corners of the given radius.
func (c *canvas) roundRect(r rect, radius int32, col color) {
	c.roundRectAlpha(r, radius, col, 1)
}

func (c *canvas) roundRectAlpha(r rect, radius int32, col color, alpha float64) {
	if r.empty() {
		return
	}
	radius = min(radius, r.w()/2, r.h()/2)
	if radius <= 0 && alpha >= 1 {
		c.fill(r, col)
		return
	}
	c.flush()
	area := r.intersect(c.clip)
	rad := float64(radius)
	for y := area.Top; y < area.Bottom; y++ {
		inBandY := y < r.Top+radius || y >= r.Bottom-radius
		for x := area.Left; x < area.Right; x++ {
			if !inBandY && alpha >= 1 && x >= r.Left+radius && x < r.Right-radius {
				c.pixels[int(y)*int(c.width)+int(x)] = col.pixel()
				continue
			}
			if !inBandY && x >= r.Left+radius && x < r.Right-radius {
				c.blend(x, y, col, alpha)
				continue
			}
			d := roundRectSDF(float64(x)+0.5, float64(y)+0.5, r, rad)
			c.blend(x, y, col, coverage(d)*alpha)
		}
	}
}

// roundBorder strokes the inside edge of a rounded rectangle.
func (c *canvas) roundBorder(r rect, radius, thickness int32, col color) {
	if r.empty() || thickness <= 0 {
		return
	}
	radius = min(radius, r.w()/2, r.h()/2)
	c.flush()
	area := r.intersect(c.clip)
	rad := float64(radius)
	t := float64(thickness)
	for y := area.Top; y < area.Bottom; y++ {
		for x := area.Left; x < area.Right; x++ {
			// Interior pixels far from every edge are skipped quickly.
			if x >= r.Left+max(radius, thickness)+1 && x < r.Right-max(radius, thickness)-1 &&
				y >= r.Top+thickness+1 && y < r.Bottom-thickness-1 {
				x = r.Right - max(radius, thickness) - 2
				continue
			}
			d := roundRectSDF(float64(x)+0.5, float64(y)+0.5, r, rad)
			a := coverage(d) - coverage(d+t)
			c.blend(x, y, col, a)
		}
	}
}

// circle fills a disc centred at (cx, cy).
func (c *canvas) circle(cx, cy, radius float64, col color) {
	c.flush()
	area := rect{int32(cx - radius - 1), int32(cy - radius - 1), int32(cx+radius) + 2, int32(cy+radius) + 2}.intersect(c.clip)
	for y := area.Top; y < area.Bottom; y++ {
		for x := area.Left; x < area.Right; x++ {
			d := math.Hypot(float64(x)+0.5-cx, float64(y)+0.5-cy) - radius
			c.blend(x, y, col, coverage(d))
		}
	}
}

// arc strokes part of a ring: start and sweep in radians, clockwise from 12
// o'clock. Used for the activity spinner.
func (c *canvas) arc(cx, cy, radius, thickness, start, sweep float64, col color) {
	c.flush()
	outer := radius + thickness/2 + 1
	area := rect{int32(cx - outer), int32(cy - outer), int32(cx+outer) + 1, int32(cy+outer) + 1}.intersect(c.clip)
	half := thickness / 2
	// End caps are round: distance to the cap centres is also accepted.
	capA := [2]float64{cx + radius*math.Sin(start), cy - radius*math.Cos(start)}
	capB := [2]float64{cx + radius*math.Sin(start+sweep), cy - radius*math.Cos(start+sweep)}
	for y := area.Top; y < area.Bottom; y++ {
		for x := area.Left; x < area.Right; x++ {
			px, py := float64(x)+0.5, float64(y)+0.5
			angle := math.Atan2(px-cx, cy-py) // 0 at 12 o'clock, clockwise
			rel := math.Mod(angle-start+4*math.Pi, 2*math.Pi)
			d := math.Inf(1)
			if rel <= sweep {
				d = math.Abs(math.Hypot(px-cx, py-cy)-radius) - half
			}
			d = math.Min(d, math.Hypot(px-capA[0], py-capA[1])-half)
			d = math.Min(d, math.Hypot(px-capB[0], py-capB[1])-half)
			c.blend(x, y, col, coverage(d))
		}
	}
}

// image draws a premultiplied RGBA image with its top-left at (x, y).
func (c *canvas) image(img *image.RGBA, x, y int32) {
	c.flush()
	b := img.Bounds()
	for iy := 0; iy < b.Dy(); iy++ {
		py := y + int32(iy)
		if py < c.clip.Top || py >= c.clip.Bottom {
			continue
		}
		for ix := 0; ix < b.Dx(); ix++ {
			px := x + int32(ix)
			if px < c.clip.Left || px >= c.clip.Right {
				continue
			}
			o := img.PixOffset(ix, iy)
			a := uint32(img.Pix[o+3])
			if a == 0 {
				continue
			}
			i := int(py)*int(c.width) + int(px)
			d := c.pixels[i]
			inv := 255 - a
			r := uint32(img.Pix[o]) + ((d>>16)&0xff)*inv/255
			g := uint32(img.Pix[o+1]) + ((d>>8)&0xff)*inv/255
			bl := uint32(img.Pix[o+2]) + (d&0xff)*inv/255
			c.pixels[i] = bl | g<<8 | r<<16
		}
	}
}

// text draws s with DrawTextW into r.
func (c *canvas) text(font windows.Handle, s string, r rect, col color, flags uintptr) {
	if s == "" || r.empty() {
		return
	}
	procSelectObject.Call(uintptr(c.dc), uintptr(font))
	procSetTextColor.Call(uintptr(c.dc), col.colorref())
	u, err := windows.UTF16FromString(s)
	if err != nil || len(u) < 2 {
		return
	}
	procDrawTextW.Call(uintptr(c.dc), uintptr(unsafe.Pointer(&u[0])), uintptr(len(u)-1), uintptr(unsafe.Pointer(&r)), flags|dtNoPrefix)
	c.dirty = true
	if textOverflowHook != nil {
		if flags&dtSingleLine != 0 {
			if need := c.textWidth(font, s); need > r.w() {
				textOverflowHook(s, need, r.w(), false)
			}
		} else if need := c.measure(font, s, r.w()); need > r.h() {
			textOverflowHook(s, need, r.h(), true)
		}
	}
}

// textOverflowHook, when set (screenshot harness only), is told about every
// string that did not fit its rectangle: need/have are widths for single-line
// text and heights for wrapped text.
var textOverflowHook func(text string, need, have int32, wrapped bool)

// measure returns the height DrawTextW needs to wrap s into width.
func (c *canvas) measure(font windows.Handle, s string, width int32) int32 {
	if s == "" {
		return 0
	}
	procSelectObject.Call(uintptr(c.dc), uintptr(font))
	r := rect{0, 0, max(width, 1), 0}
	u, err := windows.UTF16FromString(s)
	if err != nil || len(u) < 2 {
		return 0
	}
	procDrawTextW.Call(uintptr(c.dc), uintptr(unsafe.Pointer(&u[0])), uintptr(len(u)-1), uintptr(unsafe.Pointer(&r)), dtWordBreak|dtCalcRect|dtNoPrefix|dtEditControl)
	return r.Bottom
}

// textWidth returns the single-line advance width of s.
func (c *canvas) textWidth(font windows.Handle, s string) int32 {
	if s == "" {
		return 0
	}
	procSelectObject.Call(uintptr(c.dc), uintptr(font))
	u, err := windows.UTF16FromString(s)
	if err != nil || len(u) < 2 {
		return 0
	}
	var size struct{ CX, CY int32 }
	procGetTextExtentPoint32W.Call(uintptr(c.dc), uintptr(unsafe.Pointer(&u[0])), uintptr(len(u)-1), uintptr(unsafe.Pointer(&size)))
	return size.CX
}

func (c *canvas) lineHeight(font windows.Handle) int32 {
	procSelectObject.Call(uintptr(c.dc), uintptr(font))
	var tm textMetric
	procGetTextMetricsW.Call(uintptr(c.dc), uintptr(unsafe.Pointer(&tm)))
	return tm.Height
}

// icon draws an HICON (alpha-blended by DrawIconEx) at the given size.
func (c *canvas) icon(icon windows.Handle, x, y, size int32) {
	if icon == 0 {
		return
	}
	c.flush()
	procDrawIconEx.Call(uintptr(c.dc), uintptr(x), uintptr(y), uintptr(icon), uintptr(size), uintptr(size), 0, 0, diNormal)
	c.dirty = true
}

func (c *canvas) blit(hdc windows.Handle) {
	c.flush()
	procStretchDIBits.Call(uintptr(hdc), 0, 0, uintptr(c.width), uintptr(c.height), 0, 0, uintptr(c.width), uintptr(c.height),
		uintptr(unsafe.Pointer(&c.pixels[0])), uintptr(unsafe.Pointer(&c.info)), dibRGBColors, srcCopy)
}

// createFont creates a GDI font with a pixel character height.
func createFont(face string, pixelHeight int32, weight int32, quality uintptr) windows.Handle {
	h, _, _ := procCreateFontW.Call(uintptr(-pixelHeight), 0, 0, 0, uintptr(weight), 0, 0, 0, defaultCharset, 0, 0, quality, 0, uintptr(unsafe.Pointer(utf16Ptr(face))))
	return windows.Handle(h)
}

// iconFromImage builds an alpha HICON from a premultiplied RGBA image.
func iconFromImage(img *image.RGBA) windows.Handle {
	size := int32(img.Bounds().Dx())
	info := bitmapInfo{Header: bitmapInfoHeader{Size: uint32(unsafe.Sizeof(bitmapInfoHeader{})), Width: size, Height: -size, Planes: 1, BitCount: 32, Compression: biRGB}}
	var bits unsafe.Pointer
	color, _, _ := procCreateDIBSection.Call(0, uintptr(unsafe.Pointer(&info)), dibRGBColors, uintptr(unsafe.Pointer(&bits)), 0, 0)
	if color == 0 {
		return 0
	}
	defer procDeleteObject.Call(color)
	pixels := unsafe.Slice((*uint32)(bits), int(size*size))
	for i := range pixels {
		o := i * 4
		pixels[i] = uint32(img.Pix[o+2]) | uint32(img.Pix[o+1])<<8 | uint32(img.Pix[o])<<16 | uint32(img.Pix[o+3])<<24
	}
	maskBits := make([]byte, int(size*((size+15)/16*2)))
	mask, _, _ := procCreateBitmap.Call(uintptr(size), uintptr(size), 1, 1, uintptr(unsafe.Pointer(&maskBits[0])))
	if mask == 0 {
		return 0
	}
	defer procDeleteObject.Call(mask)
	ii := iconInfo{IsIcon: 1, Mask: windows.Handle(mask), Color: windows.Handle(color)}
	h, _, _ := procCreateIconIndirect.Call(uintptr(unsafe.Pointer(&ii)))
	return windows.Handle(h)
}
