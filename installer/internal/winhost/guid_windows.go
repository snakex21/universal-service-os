//go:build windows

package winhost

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"

	"golang.org/x/sys/windows"
)

var (
	efiSystemPartitionType = windows.GUID{
		Data1: 0xC12A7328,
		Data2: 0xF81F,
		Data3: 0x11D2,
		Data4: [8]byte{0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B},
	}
	basicDataPartitionType = windows.GUID{
		Data1: 0xEBD0A0A2,
		Data2: 0xB9E5,
		Data3: 0x4433,
		Data4: [8]byte{0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7},
	}
)

func randomGUID() (windows.GUID, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return windows.GUID{}, fmt.Errorf("generate GUID: %w", err)
	}
	raw[6] = (raw[6] & 0x0f) | 0x40
	raw[8] = (raw[8] & 0x3f) | 0x80
	return windows.GUID{
		Data1: binary.BigEndian.Uint32(raw[0:4]),
		Data2: binary.BigEndian.Uint16(raw[4:6]),
		Data3: binary.BigEndian.Uint16(raw[6:8]),
		Data4: [8]byte(raw[8:16]),
	}, nil
}

func guidString(g windows.GUID) string {
	return fmt.Sprintf(
		"%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X",
		g.Data1,
		g.Data2,
		g.Data3,
		g.Data4[0], g.Data4[1],
		g.Data4[2], g.Data4[3], g.Data4[4], g.Data4[5], g.Data4[6], g.Data4[7],
	)
}

func putGUID(buffer []byte, offset int, g windows.GUID) error {
	if offset < 0 || offset+16 > len(buffer) {
		return fmt.Errorf("GUID write at offset %d exceeds buffer size %d", offset, len(buffer))
	}
	binary.LittleEndian.PutUint32(buffer[offset:offset+4], g.Data1)
	binary.LittleEndian.PutUint16(buffer[offset+4:offset+6], g.Data2)
	binary.LittleEndian.PutUint16(buffer[offset+6:offset+8], g.Data3)
	copy(buffer[offset+8:offset+16], g.Data4[:])
	return nil
}

func readGUID(buffer []byte, offset int) (windows.GUID, error) {
	if offset < 0 || offset+16 > len(buffer) {
		return windows.GUID{}, fmt.Errorf("GUID read at offset %d exceeds buffer size %d", offset, len(buffer))
	}
	var data4 [8]byte
	copy(data4[:], buffer[offset+8:offset+16])
	return windows.GUID{
		Data1: binary.LittleEndian.Uint32(buffer[offset : offset+4]),
		Data2: binary.LittleEndian.Uint16(buffer[offset+4 : offset+6]),
		Data3: binary.LittleEndian.Uint16(buffer[offset+6 : offset+8]),
		Data4: data4,
	}, nil
}
