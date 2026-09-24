// Package efisign computes Authenticode hashes of PE/COFF (UEFI) images and
// signs them with a PKCS#7 SignedData blob, using only the Go standard
// library. It is the signer behind the USOS Secure Boot (shim + MOK) chain.
package efisign

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"sort"
)

const (
	peMagic32       = 0x10b
	peMagic64       = 0x20b
	sectionHeader   = 40
	securityDirSlot = 4
	certAlignment   = 8
	// WIN_CERTIFICATE revision 2.0, type PKCS_SIGNED_DATA.
	winCertRevision = 0x0200
	winCertTypePKCS = 0x0002
)

// Section is one entry of the PE section table.
type Section struct {
	Name            string
	VirtualSize     uint32
	VirtualAddress  uint32
	SizeOfRawData   uint32
	PointerToRaw    uint32
	Characteristics uint32
}

// Image is a parsed view of a PE/COFF file. It never aliases the caller's
// buffer after construction: Parse copies the bytes.
type Image struct {
	data             []byte
	numberOfSections int
	sectionTable     int
	optionalHeader   int
	checksumOffset   int
	securityDirEntry int
	sizeOfHeaders    uint32
	sectionAlignment uint32
	fileAlignment    uint32
	sizeOfImageField int
	Sections         []Section
}

// Parse validates the PE headers of data and returns an Image over a copy.
func Parse(data []byte) (*Image, error) {
	img := &Image{data: append([]byte(nil), data...)}
	if err := img.parse(); err != nil {
		return nil, err
	}
	return img, nil
}

func (img *Image) parse() error {
	d := img.data
	if len(d) < 0x40 || d[0] != 'M' || d[1] != 'Z' {
		return errors.New("not a PE image: missing MZ header")
	}
	pe := int(binary.LittleEndian.Uint32(d[0x3c:]))
	if pe < 0x40 || pe+24 > len(d) || !bytes.Equal(d[pe:pe+4], []byte("PE\x00\x00")) {
		return errors.New("not a PE image: missing PE signature")
	}
	img.numberOfSections = int(binary.LittleEndian.Uint16(d[pe+6:]))
	optionalSize := int(binary.LittleEndian.Uint16(d[pe+20:]))
	opt := pe + 24
	img.optionalHeader = opt
	if opt+optionalSize > len(d) || optionalSize < 96 {
		return errors.New("truncated optional header")
	}
	magic := binary.LittleEndian.Uint16(d[opt:])
	var dirCountOffset, dirOffset int
	switch magic {
	case peMagic32:
		dirCountOffset, dirOffset = opt+92, opt+96
	case peMagic64:
		dirCountOffset, dirOffset = opt+108, opt+112
	default:
		return fmt.Errorf("unsupported optional header magic %#x", magic)
	}
	if dirOffset > opt+optionalSize {
		return errors.New("optional header too small for data directories")
	}
	if binary.LittleEndian.Uint32(d[dirCountOffset:]) <= securityDirSlot {
		return errors.New("image has no certificate table directory entry")
	}
	img.checksumOffset = opt + 64
	img.securityDirEntry = dirOffset + securityDirSlot*8
	if img.securityDirEntry+8 > opt+optionalSize {
		return errors.New("certificate table directory entry outside the optional header")
	}
	img.sectionAlignment = binary.LittleEndian.Uint32(d[opt+32:])
	img.fileAlignment = binary.LittleEndian.Uint32(d[opt+36:])
	img.sizeOfImageField = opt + 56
	img.sizeOfHeaders = binary.LittleEndian.Uint32(d[opt+60:])
	if int(img.sizeOfHeaders) > len(d) || int(img.sizeOfHeaders) <= img.securityDirEntry+8 {
		return errors.New("invalid SizeOfHeaders")
	}
	img.sectionTable = opt + optionalSize
	if img.sectionTable+img.numberOfSections*sectionHeader > int(img.sizeOfHeaders) {
		return errors.New("section table extends past SizeOfHeaders")
	}
	img.Sections = img.Sections[:0]
	for i := 0; i < img.numberOfSections; i++ {
		h := d[img.sectionTable+i*sectionHeader:]
		s := Section{
			Name:            string(bytes.TrimRight(h[:8], "\x00")),
			VirtualSize:     binary.LittleEndian.Uint32(h[8:]),
			VirtualAddress:  binary.LittleEndian.Uint32(h[12:]),
			SizeOfRawData:   binary.LittleEndian.Uint32(h[16:]),
			PointerToRaw:    binary.LittleEndian.Uint32(h[20:]),
			Characteristics: binary.LittleEndian.Uint32(h[36:]),
		}
		if s.SizeOfRawData != 0 && uint64(s.PointerToRaw)+uint64(s.SizeOfRawData) > uint64(len(d)) {
			return fmt.Errorf("section %q raw data extends past end of file", s.Name)
		}
		img.Sections = append(img.Sections, s)
	}
	cert, size := img.certificateTable()
	if size != 0 {
		if uint64(cert)+uint64(size) > uint64(len(d)) || cert < img.sizeOfHeaders {
			return errors.New("certificate table outside the file")
		}
	}
	return nil
}

// Bytes returns a copy of the current image bytes.
func (img *Image) Bytes() []byte { return append([]byte(nil), img.data...) }

func (img *Image) certificateTable() (uint32, uint32) {
	return binary.LittleEndian.Uint32(img.data[img.securityDirEntry:]),
		binary.LittleEndian.Uint32(img.data[img.securityDirEntry+4:])
}

// Signed reports whether the image carries a certificate table.
func (img *Image) Signed() bool {
	_, size := img.certificateTable()
	return size != 0
}

// Section returns the named section, if present.
func (img *Image) Section(name string) (Section, bool) {
	for _, s := range img.Sections {
		if s.Name == name {
			return s, true
		}
	}
	return Section{}, false
}

// SectionData returns the raw file bytes of a section.
func (img *Image) SectionData(s Section) []byte {
	return append([]byte(nil), img.data[s.PointerToRaw:s.PointerToRaw+s.SizeOfRawData]...)
}

// AuthenticodeHash returns the SHA-256 Authenticode digest of the image as
// defined by the Windows Authenticode PE specification (and implemented by
// shim, EDK2 DxeImageVerificationLib and WinVerifyTrust): the headers minus
// the CheckSum field and the certificate table directory entry, the section
// data in file order, then any trailing data except the certificate table.
func (img *Image) AuthenticodeHash() ([]byte, error) {
	d := img.data
	h := sha256.New()
	h.Write(d[:img.checksumOffset])
	h.Write(d[img.checksumOffset+4 : img.securityDirEntry])
	h.Write(d[img.securityDirEntry+8 : img.sizeOfHeaders])
	sections := append([]Section(nil), img.Sections...)
	sort.SliceStable(sections, func(i, j int) bool { return sections[i].PointerToRaw < sections[j].PointerToRaw })
	hashed := uint64(img.sizeOfHeaders)
	for _, s := range sections {
		if s.SizeOfRawData == 0 {
			continue
		}
		h.Write(d[s.PointerToRaw : s.PointerToRaw+s.SizeOfRawData])
		hashed += uint64(s.SizeOfRawData)
	}
	certOffset, certSize := img.certificateTable()
	end := uint64(len(d))
	if certSize != 0 {
		if uint64(certOffset)+uint64(certSize) != end {
			return nil, errors.New("certificate table is not at the end of the file")
		}
		end = uint64(certOffset)
	}
	if end > hashed {
		h.Write(d[hashed:end])
	} else if end < hashed {
		return nil, errors.New("section data overlaps the certificate table")
	}
	return h.Sum(nil), nil
}

// Signatures returns the PKCS#7 blobs of every WIN_CERTIFICATE entry.
func (img *Image) Signatures() ([][]byte, error) {
	offset, size := img.certificateTable()
	if size == 0 {
		return nil, nil
	}
	table := img.data[offset : offset+size]
	var out [][]byte
	for pos := 0; pos+8 <= len(table); {
		length := int(binary.LittleEndian.Uint32(table[pos:]))
		revision := binary.LittleEndian.Uint16(table[pos+4:])
		kind := binary.LittleEndian.Uint16(table[pos+6:])
		if length < 8 || pos+length > len(table) {
			return nil, fmt.Errorf("malformed WIN_CERTIFICATE at %d", pos)
		}
		if revision == winCertRevision && kind == winCertTypePKCS {
			out = append(out, append([]byte(nil), table[pos+8:pos+length]...))
		}
		pos += alignUp(length, certAlignment)
	}
	return out, nil
}

// StripSignature removes the certificate table (which must be the last
// thing in the file) and clears its directory entry.
func (img *Image) StripSignature() error {
	offset, size := img.certificateTable()
	if size == 0 {
		return nil
	}
	if int(offset)+int(size) != len(img.data) {
		return errors.New("cannot strip a certificate table that is not at the end of the file")
	}
	img.data = img.data[:offset]
	binary.LittleEndian.PutUint32(img.data[img.securityDirEntry:], 0)
	binary.LittleEndian.PutUint32(img.data[img.securityDirEntry+4:], 0)
	return img.parse()
}

// AddSection appends a read-only initialized data section (such as .sbat).
// The image must be unsigned, have room for one more section header and no
// data after its last section.
func (img *Image) AddSection(name string, content []byte) error {
	if len(name) == 0 || len(name) > 8 {
		return fmt.Errorf("invalid section name %q", name)
	}
	if img.Signed() {
		return errors.New("strip the signature before adding a section")
	}
	if _, exists := img.Section(name); exists {
		return fmt.Errorf("section %s already exists", name)
	}
	if img.fileAlignment == 0 || img.sectionAlignment == 0 {
		return errors.New("image has zero file or section alignment")
	}
	headerEnd := img.sectionTable + (img.numberOfSections+1)*sectionHeader
	if headerEnd > int(img.sizeOfHeaders) {
		return errors.New("no room for another section header")
	}
	var rawEnd, virtualEnd uint32
	for _, s := range img.Sections {
		if s.SizeOfRawData != 0 {
			if s.PointerToRaw < uint32(headerEnd) {
				return errors.New("section data starts inside the header area")
			}
			rawEnd = max(rawEnd, s.PointerToRaw+s.SizeOfRawData)
		}
		virtualEnd = max(virtualEnd, s.VirtualAddress+max(s.VirtualSize, s.SizeOfRawData))
	}
	if int(rawEnd) != len(img.data) {
		return fmt.Errorf("image has %d bytes after its last section", len(img.data)-int(rawEnd))
	}
	pointer := uint32(alignUp(len(img.data), int(img.fileAlignment)))
	rawSize := uint32(alignUp(len(content), int(img.fileAlignment)))
	virtual := uint32(alignUp(int(virtualEnd), int(img.sectionAlignment)))

	grown := make([]byte, int(pointer+rawSize))
	copy(grown, img.data)
	copy(grown[pointer:], content)
	h := grown[img.sectionTable+img.numberOfSections*sectionHeader:]
	copy(h[:8], append([]byte(name), make([]byte, 8-len(name))...))
	binary.LittleEndian.PutUint32(h[8:], uint32(len(content)))
	binary.LittleEndian.PutUint32(h[12:], virtual)
	binary.LittleEndian.PutUint32(h[16:], rawSize)
	binary.LittleEndian.PutUint32(h[20:], pointer)
	// IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ
	binary.LittleEndian.PutUint32(h[36:], 0x40000040)
	pe := int(binary.LittleEndian.Uint32(grown[0x3c:]))
	binary.LittleEndian.PutUint16(grown[pe+6:], uint16(img.numberOfSections+1))
	sizeOfImage := uint32(alignUp(int(virtual)+len(content), int(img.sectionAlignment)))
	binary.LittleEndian.PutUint32(grown[img.sizeOfImageField:], sizeOfImage)
	initialized := img.optionalHeader + 8
	binary.LittleEndian.PutUint32(grown[initialized:], binary.LittleEndian.Uint32(grown[initialized:])+rawSize)
	img.data = grown
	return img.parse()
}

// padForCertificate zero-pads the file to the 8-byte boundary the
// certificate table needs. The padding is part of the Authenticode hash.
func (img *Image) padForCertificate() error {
	if img.Signed() {
		return errors.New("image already has a certificate table")
	}
	if pad := alignUp(len(img.data), certAlignment) - len(img.data); pad > 0 {
		img.data = append(img.data, make([]byte, pad)...)
	}
	return nil
}

// appendSignature appends one WIN_CERTIFICATE carrying pkcs7 and points the
// certificate table directory entry at it.
func (img *Image) appendSignature(pkcs7 []byte) error {
	if len(img.data)%certAlignment != 0 {
		return errors.New("image is not padded for the certificate table")
	}
	length := 8 + len(pkcs7)
	entry := make([]byte, alignUp(length, certAlignment))
	binary.LittleEndian.PutUint32(entry[0:], uint32(length))
	binary.LittleEndian.PutUint16(entry[4:], winCertRevision)
	binary.LittleEndian.PutUint16(entry[6:], winCertTypePKCS)
	copy(entry[8:], pkcs7)
	offset := len(img.data)
	img.data = append(img.data, entry...)
	binary.LittleEndian.PutUint32(img.data[img.securityDirEntry:], uint32(offset))
	binary.LittleEndian.PutUint32(img.data[img.securityDirEntry+4:], uint32(len(entry)))
	return img.parse()
}

func alignUp(value, alignment int) int {
	return (value + alignment - 1) / alignment * alignment
}
