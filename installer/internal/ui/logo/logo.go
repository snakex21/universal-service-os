// Package logo draws the USOS application mark in pure Go, so the window
// icon, the header logo and the icon embedded in the EXE (see
// cmd/usos-installer-rsrc) come from one definition and no image assets are
// bundled.
package logo

import (
	"image"
	"image/color"
	"math"
)

// Palette endpoints (src/gui/theme.zig accent and selected colours).
var (
	top    = [3]float64{0x43, 0xd8, 0xe8}
	bottom = [3]float64{0x14, 0x5b, 0x7a}
	mark   = [3]float64{0xf4, 0xfd, 0xff}
	dot    = [3]float64{0xff, 0xff, 0xff}
)

// Render returns a size x size premultiplied RGBA image of the mark: a
// rounded tile with a diagonal accent gradient carrying a bold "U" whose
// right stem ends in a small status light.
func Render(size int) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, size, size))
	const samples = 4
	s := float64(size)
	radius := 0.22
	if size <= 20 {
		radius = 0.16 // keep the tile readable at 16 px
	}
	stroke := 0.135
	if size <= 20 {
		stroke = 0.17
	}
	for py := 0; py < size; py++ {
		for px := 0; px < size; px++ {
			var tileCov, markCov, dotCov float64
			for sy := 0; sy < samples; sy++ {
				for sx := 0; sx < samples; sx++ {
					x := (float64(px) + (float64(sx)+0.5)/samples) / s
					y := (float64(py) + (float64(sy)+0.5)/samples) / s
					if roundedBox(x-0.5, y-0.5, 0.5, 0.5, radius) <= 0 {
						tileCov++
						if uShape(x, y) <= stroke/2 {
							markCov++
						}
						if math.Hypot(x-0.70, y-0.25) <= 0.075 {
							dotCov++
						}
					}
				}
			}
			n := float64(samples * samples)
			tileCov /= n
			markCov /= n
			dotCov /= n
			if tileCov == 0 {
				continue
			}
			t := clamp((float64(px)/s*0.55 + float64(py)/s*0.45), 0, 1)
			var rgb [3]float64
			for i := range rgb {
				base := top[i]*(1-t) + bottom[i]*t
				v := base*(1-markCov/tileCov) + mark[i]*(markCov/tileCov)
				v = v*(1-dotCov/tileCov) + dot[i]*(dotCov/tileCov)
				rgb[i] = v
			}
			a := tileCov
			img.SetRGBA(px, py, color.RGBA{
				R: uint8(rgb[0]*a + 0.5),
				G: uint8(rgb[1]*a + 0.5),
				B: uint8(rgb[2]*a + 0.5),
				A: uint8(a*255 + 0.5),
			})
		}
	}
	return img
}

// roundedBox is the signed distance to a box of half size (hw, hh) with
// corner radius r, centred at the origin.
func roundedBox(x, y, hw, hh, r float64) float64 {
	qx := math.Abs(x) - hw + r
	qy := math.Abs(y) - hh + r
	outside := math.Hypot(math.Max(qx, 0), math.Max(qy, 0))
	return outside + math.Min(math.Max(qx, qy), 0) - r
}

// uShape is the distance to the centre line of the "U": two stems joined by
// a half circle. The right stem is shorter to leave room for the dot.
func uShape(x, y float64) float64 {
	const (
		left, right = 0.33, 0.67
		cx, cy, r   = 0.5, 0.56, 0.17
		leftTop     = 0.24
		rightTop    = 0.40
	)
	d := math.Inf(1)
	if y <= cy {
		if y >= leftTop {
			d = math.Min(d, math.Abs(x-left))
		} else {
			d = math.Min(d, math.Hypot(x-left, y-leftTop))
		}
		if y >= rightTop {
			d = math.Min(d, math.Abs(x-right))
		} else {
			d = math.Min(d, math.Hypot(x-right, y-rightTop))
		}
	} else {
		d = math.Min(d, math.Abs(math.Hypot(x-cx, y-cy)-r))
	}
	return d
}

func clamp(v, lo, hi float64) float64 { return math.Max(lo, math.Min(hi, v)) }
