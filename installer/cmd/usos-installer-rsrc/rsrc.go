package main

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/png"
	"sort"
	"unicode/utf16"

	"github.com/snakex21/universal-service-os/installer/internal/ui/logo"
)

const (
	rtIcon      = 3
	rtGroupIcon = 14
	rtVersion   = 16
	rtManifest  = 24
	langEnUS    = 0x0409
)

// iconSizes covers the shell's small/large icons at 100-250 % scaling.
var iconSizes = []int{16, 20, 24, 32, 40, 48, 64, 256}

const manifest = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0" xmlns:asmv3="urn:schemas-microsoft-com:asm.v3">
  <assemblyIdentity type="win32" name="USOS.Installer" version="1.0.0.0" processorArchitecture="*"/>
  <description>Universal Service OS Installer</description>
  <dependency>
    <dependentAssembly>
      <assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0" processorArchitecture="*" publicKeyToken="6595b64144ccf1df" language="*"/>
    </dependentAssembly>
  </dependency>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    </application>
  </compatibility>
  <asmv3:application>
    <asmv3:windowsSettings>
      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2, PerMonitor</dpiAwareness>
    </asmv3:windowsSettings>
  </asmv3:application>
</assembly>
`

type iconImage struct {
	size int
	data []byte
}

func iconImages() []iconImage {
	out := make([]iconImage, 0, len(iconSizes))
	for _, size := range iconSizes {
		img := logo.Render(size)
		var data []byte
		if size >= 256 {
			var buf bytes.Buffer
			if err := png.Encode(&buf, img); err != nil {
				panic(err)
			}
			data = buf.Bytes()
		} else {
			data = dibIcon(img)
		}
		out = append(out, iconImage{size: size, data: data})
	}
	return out
}

// dibIcon encodes a 32bpp icon image: BITMAPINFOHEADER (double height),
// bottom-up BGRA with straight alpha, then an all-zero AND mask.
func dibIcon(img *image.RGBA) []byte {
	s := img.Bounds().Dx()
	maskStride := (s + 31) / 32 * 4
	var buf bytes.Buffer
	header := []any{uint32(40), int32(s), int32(2 * s), uint16(1), uint16(32), uint32(0), uint32(s*s*4 + maskStride*s), int32(0), int32(0), uint32(0), uint32(0)}
	for _, v := range header {
		binary.Write(&buf, binary.LittleEndian, v)
	}
	for y := s - 1; y >= 0; y-- {
		for x := 0; x < s; x++ {
			o := img.PixOffset(x, y)
			r, g, b, a := img.Pix[o], img.Pix[o+1], img.Pix[o+2], img.Pix[o+3]
			if a > 0 && a < 255 {
				r = uint8(uint32(r) * 255 / uint32(a))
				g = uint8(uint32(g) * 255 / uint32(a))
				b = uint8(uint32(b) * 255 / uint32(a))
			}
			buf.Write([]byte{b, g, r, a})
		}
	}
	buf.Write(make([]byte, maskStride*s))
	return buf.Bytes()
}

func dirEntryDims(size int) (byte, byte) {
	if size >= 256 {
		return 0, 0
	}
	return byte(size), byte(size)
}

func buildICO() []byte {
	images := iconImages()
	var buf bytes.Buffer
	binary.Write(&buf, binary.LittleEndian, [3]uint16{0, 1, uint16(len(images))})
	offset := 6 + 16*len(images)
	for _, im := range images {
		w, h := dirEntryDims(im.size)
		buf.Write([]byte{w, h, 0, 0})
		binary.Write(&buf, binary.LittleEndian, [2]uint16{1, 32})
		binary.Write(&buf, binary.LittleEndian, [2]uint32{uint32(len(im.data)), uint32(offset)})
		offset += len(im.data)
	}
	for _, im := range images {
		buf.Write(im.data)
	}
	return buf.Bytes()
}

// ---- version information ---------------------------------------------------

func utf16z(s string) []byte {
	var buf bytes.Buffer
	for _, c := range utf16.Encode([]rune(s)) {
		binary.Write(&buf, binary.LittleEndian, c)
	}
	buf.Write([]byte{0, 0})
	return buf.Bytes()
}

func pad4(b []byte) []byte {
	for len(b)%4 != 0 {
		b = append(b, 0)
	}
	return b
}

// verNode builds one VS_VERSIONINFO-style block (wLength, wValueLength,
// wType, szKey, padding, value, padding, children).
func verNode(key string, textType bool, value []byte, valueLen int, children ...[]byte) []byte {
	b := make([]byte, 6)
	b = append(b, utf16z(key)...)
	b = pad4(b)
	b = append(b, value...)
	for _, child := range children {
		b = pad4(b)
		b = append(b, child...)
	}
	binary.LittleEndian.PutUint16(b[0:], uint16(len(b)))
	binary.LittleEndian.PutUint16(b[2:], uint16(valueLen))
	if textType {
		binary.LittleEndian.PutUint16(b[4:], 1)
	}
	return b
}

func verString(key, value string) []byte {
	v := utf16z(value)
	return verNode(key, true, v, len(v)/2)
}

func versionInfo() []byte {
	var fixed bytes.Buffer
	binary.Write(&fixed, binary.LittleEndian, []uint32{
		0xFEEF04BD, 0x00010000,
		0x00010000, 0x00000000, // file version 1.0.0.0
		0x00010000, 0x00000000, // product version 1.0.0.0
		0x3F, 0, // flags mask, flags
		0x00040004, // VOS_NT_WINDOWS32
		1, 0,       // VFT_APP
		0, 0,
	})
	table := verNode("040904b0", true, nil, 0,
		verString("CompanyName", "Universal Service OS"),
		verString("FileDescription", "Universal Service OS Installer"),
		verString("FileVersion", "1.0.0.0"),
		verString("InternalName", "usos-installer"),
		verString("OriginalFilename", "USOS Installer.exe"),
		verString("ProductName", "Universal Service OS"),
		verString("ProductVersion", "1.0.0.0"),
	)
	strings := verNode("StringFileInfo", true, nil, 0, table)
	translation := make([]byte, 4)
	binary.LittleEndian.PutUint16(translation[0:], langEnUS)
	binary.LittleEndian.PutUint16(translation[2:], 1200)
	vars := verNode("VarFileInfo", true, nil, 0, verNode("Translation", false, translation, 4))
	return verNode("VS_VERSION_INFO", false, fixed.Bytes(), fixed.Len(), strings, vars)
}

// ---- COFF object with a .rsrc section ---------------------------------------

type resource struct {
	typ, id uint16
	data    []byte
}

func resources() []resource {
	images := iconImages()
	var res []resource
	var group bytes.Buffer
	binary.Write(&group, binary.LittleEndian, [3]uint16{0, 1, uint16(len(images))})
	for i, im := range images {
		id := uint16(i + 1)
		res = append(res, resource{rtIcon, id, im.data})
		w, h := dirEntryDims(im.size)
		group.Write([]byte{w, h, 0, 0})
		binary.Write(&group, binary.LittleEndian, [2]uint16{1, 32})
		binary.Write(&group, binary.LittleEndian, uint32(len(im.data)))
		binary.Write(&group, binary.LittleEndian, id)
	}
	res = append(res,
		resource{rtGroupIcon, 1, group.Bytes()},
		resource{rtVersion, 1, versionInfo()},
		resource{rtManifest, 1, []byte(manifest)},
	)
	return res
}

func buildSyso() []byte {
	res := resources()
	sort.Slice(res, func(i, j int) bool {
		if res[i].typ != res[j].typ {
			return res[i].typ < res[j].typ
		}
		return res[i].id < res[j].id
	})
	var types []uint16
	byType := map[uint16][]int{}
	for i, r := range res {
		if len(byType[r.typ]) == 0 {
			types = append(types, r.typ)
		}
		byType[r.typ] = append(byType[r.typ], i)
	}

	// Layout: root dir, type dirs, name dirs, data entries, data.
	dirSize := func(entries int) int { return 16 + 8*entries }
	offset := dirSize(len(types))
	typeDirOff := map[uint16]int{}
	for _, t := range types {
		typeDirOff[t] = offset
		offset += dirSize(len(byType[t]))
	}
	nameDirOff := make([]int, len(res))
	for i := range res {
		nameDirOff[i] = offset
		offset += dirSize(1)
	}
	dataEntryOff := make([]int, len(res))
	for i := range res {
		dataEntryOff[i] = offset
		offset += 16
	}
	dataOff := make([]int, len(res))
	for i, r := range res {
		offset = (offset + 7) &^ 7
		dataOff[i] = offset
		offset += len(r.data)
	}
	section := make([]byte, (offset+7)&^7)
	putDir := func(at, ids int) {
		binary.LittleEndian.PutUint16(section[at+14:], uint16(ids))
	}
	putEntry := func(at int, id uint32, target int, subdir bool) {
		binary.LittleEndian.PutUint32(section[at:], id)
		v := uint32(target)
		if subdir {
			v |= 0x80000000
		}
		binary.LittleEndian.PutUint32(section[at+4:], v)
	}
	putDir(0, len(types))
	for i, t := range types {
		putEntry(16+8*i, uint32(t), typeDirOff[t], true)
		putDir(typeDirOff[t], len(byType[t]))
		for j, ri := range byType[t] {
			putEntry(typeDirOff[t]+16+8*j, uint32(res[ri].id), nameDirOff[ri], true)
		}
	}
	var relocs []int
	for i, r := range res {
		putDir(nameDirOff[i], 1)
		putEntry(nameDirOff[i]+16, langEnUS, dataEntryOff[i], false)
		// IMAGE_RESOURCE_DATA_ENTRY: OffsetToData is an RVA, fixed up by
		// the linker through an ADDR32NB relocation against .rsrc.
		binary.LittleEndian.PutUint32(section[dataEntryOff[i]:], uint32(dataOff[i]))
		binary.LittleEndian.PutUint32(section[dataEntryOff[i]+4:], uint32(len(r.data)))
		relocs = append(relocs, dataEntryOff[i])
		copy(section[dataOff[i]:], r.data)
	}

	const headerSize, sectionHeaderSize = 20, 40
	rawOff := headerSize + sectionHeaderSize
	relocOff := rawOff + len(section)
	symOff := relocOff + 10*len(relocs)
	var out bytes.Buffer
	le := binary.LittleEndian
	binary.Write(&out, le, uint16(0x8664)) // IMAGE_FILE_MACHINE_AMD64
	binary.Write(&out, le, uint16(1))      // sections
	binary.Write(&out, le, uint32(0))      // timestamp (deterministic)
	binary.Write(&out, le, uint32(symOff))
	binary.Write(&out, le, uint32(1)) // symbols
	binary.Write(&out, le, uint16(0)) // optional header size
	binary.Write(&out, le, uint16(0)) // characteristics
	out.WriteString(".rsrc\x00\x00\x00")
	binary.Write(&out, le, []uint32{0, 0, uint32(len(section)), uint32(rawOff), uint32(relocOff), 0})
	binary.Write(&out, le, uint16(len(relocs)))
	binary.Write(&out, le, uint16(0))
	binary.Write(&out, le, uint32(0x40000040)) // INITIALIZED_DATA | MEM_READ
	out.Write(section)
	for _, at := range relocs {
		binary.Write(&out, le, uint32(at))
		binary.Write(&out, le, uint32(0)) // symbol 0 = .rsrc
		binary.Write(&out, le, uint16(3)) // IMAGE_REL_AMD64_ADDR32NB
	}
	out.WriteString(".rsrc\x00\x00\x00")
	binary.Write(&out, le, uint32(0)) // value
	binary.Write(&out, le, int16(1))  // section number
	binary.Write(&out, le, uint16(0)) // type
	out.WriteByte(3)                  // IMAGE_SYM_CLASS_STATIC
	out.WriteByte(0)                  // aux symbols
	binary.Write(&out, le, uint32(4)) // empty string table
	return out.Bytes()
}
