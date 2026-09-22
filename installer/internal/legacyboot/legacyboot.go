package legacyboot

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"hash/crc32"
	"strings"
)

const (
	SupportedSectorBytes uint32 = 512
	Stage1CodeBytes             = 440
	MBRPartitionOffset          = 446
	MBRPartitionBytes           = 64
	MBRSignatureOffset          = 510

	CoreLBA              uint64 = 64
	CoreBootstrapSectors uint64 = 32
	CoreBootstrapBytes   uint64 = CoreBootstrapSectors * uint64(SupportedSectorBytes)
	CoreSlotSectors      uint64 = 512
	CoreSlotBytes        uint64 = CoreSlotSectors * uint64(SupportedSectorBytes)
	CoreHeaderBytes             = 64
	CoreFormatVersion    uint16 = 1
	CoreLoadAddress      uint32 = 0x00020000
	CoreEntryOffset      uint32 = 0
)

const (
	coreHeaderMagicOffset        = 0
	coreHeaderVersionOffset      = 8
	coreHeaderSizeOffset         = 10
	coreHeaderSlotBytesOffset    = 12
	coreHeaderBootstrapOffset    = 16
	coreHeaderImageSizeOffset    = 20
	coreHeaderPayloadOffset      = 24
	coreHeaderPayloadSizeOffset  = 28
	coreHeaderLoadAddressOffset  = 32
	coreHeaderEntryOffset        = 36
	coreHeaderContentCRCOffset   = 40
	coreHeaderHeaderCRCOffset    = 44
	coreHeaderReservedOffset     = 48
	coreHeaderCRCInputBytes      = 44
	coreHeaderExpectedPayloadOff = uint32(CoreBootstrapBytes)
)

var coreHeaderMagic = [8]byte{'U', 'S', 'O', 'S', 'C', 'O', 'R', 'E'}

type Payload struct {
	Stage1 []byte
	Core   []byte
}

type Region struct {
	CoreStartBytes uint64
	CoreSizeBytes  uint64
	CoreEndBytes   uint64
}

type ComponentAudit struct {
	BeforeSHA256   string
	AfterSHA256    string
	ExpectedSHA256 string
	Changed        bool
}

type Audit struct {
	Stage1                 ComponentAudit
	Core                   ComponentAudit
	CoreSlotZeroReadbackOK bool
}

func (p Payload) Validate() error {
	if len(p.Stage1) != Stage1CodeBytes {
		return fmt.Errorf("legacy Stage 1 size=%d, want exactly %d bytes", len(p.Stage1), Stage1CodeBytes)
	}
	if bytes.Contains(p.Core, []byte("[LEGACY_MENU_TEST]")) {
		return fmt.Errorf("refusing to install XP menu autotest Core on a USOS device")
	}
	if err := ValidateCoreSlot(p.Core); err != nil {
		return err
	}
	return nil
}

func ValidateCoreSlot(slot []byte) error {
	if uint64(len(slot)) != CoreSlotBytes {
		return fmt.Errorf("legacy Core slot size=%d, want exactly %d bytes", len(slot), CoreSlotBytes)
	}
	if !equalBytes(slot[coreHeaderMagicOffset:coreHeaderMagicOffset+len(coreHeaderMagic)], coreHeaderMagic[:]) {
		return fmt.Errorf("legacy Core header magic mismatch")
	}
	if got := binary.LittleEndian.Uint16(slot[coreHeaderVersionOffset:]); got != CoreFormatVersion {
		return fmt.Errorf("legacy Core format version=%d, want %d", got, CoreFormatVersion)
	}
	if got := binary.LittleEndian.Uint16(slot[coreHeaderSizeOffset:]); got != CoreHeaderBytes {
		return fmt.Errorf("legacy Core header size=%d, want %d", got, CoreHeaderBytes)
	}
	if got := binary.LittleEndian.Uint32(slot[coreHeaderSlotBytesOffset:]); got != uint32(CoreSlotBytes) {
		return fmt.Errorf("legacy Core header slot_bytes=%d, want %d", got, CoreSlotBytes)
	}
	if got := binary.LittleEndian.Uint32(slot[coreHeaderBootstrapOffset:]); got != uint32(CoreBootstrapBytes) {
		return fmt.Errorf("legacy Core header bootstrap_bytes=%d, want %d", got, CoreBootstrapBytes)
	}
	imageSize := binary.LittleEndian.Uint32(slot[coreHeaderImageSizeOffset:])
	payloadOffset := binary.LittleEndian.Uint32(slot[coreHeaderPayloadOffset:])
	payloadSize := binary.LittleEndian.Uint32(slot[coreHeaderPayloadSizeOffset:])
	if payloadOffset != coreHeaderExpectedPayloadOff {
		return fmt.Errorf("legacy Core payload offset=%d, want %d", payloadOffset, coreHeaderExpectedPayloadOff)
	}
	if payloadSize == 0 || uint64(payloadSize) > CoreSlotBytes-CoreBootstrapBytes {
		return fmt.Errorf("legacy Core payload size=%d is outside slot bounds", payloadSize)
	}
	expectedImageSize := uint64(payloadOffset) + uint64(payloadSize)
	if expectedImageSize != uint64(imageSize) || expectedImageSize > CoreSlotBytes {
		return fmt.Errorf("legacy Core image size=%d inconsistent with payload offset=%d size=%d", imageSize, payloadOffset, payloadSize)
	}
	if got := binary.LittleEndian.Uint32(slot[coreHeaderLoadAddressOffset:]); got != CoreLoadAddress {
		return fmt.Errorf("legacy Core load address=0x%08X, want 0x%08X", got, CoreLoadAddress)
	}
	if got := binary.LittleEndian.Uint32(slot[coreHeaderEntryOffset:]); got != CoreEntryOffset {
		return fmt.Errorf("legacy Core entry offset=%d, want %d", got, CoreEntryOffset)
	}
	if !allZero(slot[coreHeaderReservedOffset:CoreHeaderBytes]) {
		return fmt.Errorf("legacy Core header reserved bytes are not zero")
	}
	expectedHeaderCRC := binary.LittleEndian.Uint32(slot[coreHeaderHeaderCRCOffset:])
	actualHeaderCRC := crc32.ChecksumIEEE(slot[:coreHeaderCRCInputBytes])
	if actualHeaderCRC != expectedHeaderCRC {
		return fmt.Errorf("legacy Core header CRC32=%08X, want %08X", actualHeaderCRC, expectedHeaderCRC)
	}
	expectedContentCRC := binary.LittleEndian.Uint32(slot[coreHeaderContentCRCOffset:])
	actualContentCRC := crc32.ChecksumIEEE(slot[CoreHeaderBytes:imageSize])
	if actualContentCRC != expectedContentCRC {
		return fmt.Errorf("legacy Core content CRC32=%08X, want %08X", actualContentCRC, expectedContentCRC)
	}
	return nil
}

func ComputeRegion(startingUsableOffset, espStartBytes uint64, sectorBytes uint32) (Region, error) {
	if sectorBytes != SupportedSectorBytes {
		return Region{}, fmt.Errorf("legacy BIOS boot area requires %d-byte logical sectors; got %d", SupportedSectorBytes, sectorBytes)
	}
	coreStart := CoreLBA * uint64(sectorBytes)
	coreEnd := coreStart + CoreSlotBytes
	if coreEnd < coreStart {
		return Region{}, fmt.Errorf("legacy Core byte range overflows")
	}
	if coreStart < startingUsableOffset {
		return Region{}, fmt.Errorf("legacy Core start=%d overlaps GPT metadata ending at StartingUsableOffset=%d", coreStart, startingUsableOffset)
	}
	if espStartBytes == 0 {
		return Region{}, fmt.Errorf("ESP start is zero")
	}
	if coreEnd > espStartBytes {
		return Region{}, fmt.Errorf("legacy Core end=%d overlaps ESP start=%d", coreEnd, espStartBytes)
	}
	return Region{CoreStartBytes: coreStart, CoreSizeBytes: CoreSlotBytes, CoreEndBytes: coreEnd}, nil
}

func ValidateProtectiveMBR(sector []byte, diskBytes uint64, sectorBytes uint32) error {
	if sectorBytes != SupportedSectorBytes {
		return fmt.Errorf("protective MBR validation requires %d-byte logical sectors; got %d", SupportedSectorBytes, sectorBytes)
	}
	if len(sector) != int(sectorBytes) {
		return fmt.Errorf("MBR sector length=%d, want %d", len(sector), sectorBytes)
	}
	if sector[MBRSignatureOffset] != 0x55 || sector[MBRSignatureOffset+1] != 0xAA {
		return fmt.Errorf("protective MBR signature mismatch: got %02X %02X want 55 AA", sector[MBRSignatureOffset], sector[MBRSignatureOffset+1])
	}
	if diskBytes < uint64(sectorBytes)*2 || diskBytes%uint64(sectorBytes) != 0 {
		return fmt.Errorf("invalid disk size %d for %d-byte sectors", diskBytes, sectorBytes)
	}
	sectors := diskBytes / uint64(sectorBytes)
	expectedProtectiveSectors := sectors - 1
	if expectedProtectiveSectors > 0xFFFFFFFF {
		expectedProtectiveSectors = 0xFFFFFFFF
	}

	protective := -1
	for index := 0; index < 4; index++ {
		entry := sector[MBRPartitionOffset+index*16 : MBRPartitionOffset+(index+1)*16]
		partitionType := entry[4]
		if partitionType == 0xEE {
			if protective != -1 {
				return fmt.Errorf("protective MBR contains more than one 0xEE entry")
			}
			protective = index
			if entry[0] != 0 {
				return fmt.Errorf("protective MBR 0xEE entry boot indicator=%02X, want 00", entry[0])
			}
			if binary.LittleEndian.Uint32(entry[8:12]) != 1 {
				return fmt.Errorf("protective MBR 0xEE entry starts at LBA=%d, want 1", binary.LittleEndian.Uint32(entry[8:12]))
			}
			actualProtectiveSectors := uint64(binary.LittleEndian.Uint32(entry[12:16]))
			if actualProtectiveSectors != expectedProtectiveSectors && actualProtectiveSectors != 0xFFFFFFFF {
				return fmt.Errorf("protective MBR 0xEE size=%d sectors, want %d or 0xFFFFFFFF sentinel", actualProtectiveSectors, expectedProtectiveSectors)
			}
			continue
		}
		if !allZero(entry) {
			return fmt.Errorf("protective MBR entry %d is not empty and is not type 0xEE", index+1)
		}
	}
	if protective == -1 {
		return fmt.Errorf("protective MBR has no 0xEE partition entry")
	}
	return nil
}

func ExpectedSectorWithStage1(before []byte, stage1 []byte) ([]byte, error) {
	if len(before) != int(SupportedSectorBytes) {
		return nil, fmt.Errorf("MBR sector length=%d, want %d", len(before), SupportedSectorBytes)
	}
	if len(stage1) != Stage1CodeBytes {
		return nil, fmt.Errorf("Stage 1 length=%d, want %d", len(stage1), Stage1CodeBytes)
	}
	expected := append([]byte(nil), before...)
	copy(expected[:Stage1CodeBytes], stage1)
	return expected, nil
}

func ZeroBytes(size int) []byte {
	return make([]byte, size)
}

func SHA256(data []byte) string {
	sum := sha256.Sum256(data)
	return strings.ToUpper(hex.EncodeToString(sum[:]))
}

func MakeAudit(beforeStage1, afterStage1, expectedStage1, beforeCore, afterCore, expectedCore []byte) Audit {
	beforeStage1Hash := SHA256(beforeStage1)
	afterStage1Hash := SHA256(afterStage1)
	beforeCoreHash := SHA256(beforeCore)
	afterCoreHash := SHA256(afterCore)
	return Audit{
		Stage1: ComponentAudit{
			BeforeSHA256:   beforeStage1Hash,
			AfterSHA256:    afterStage1Hash,
			ExpectedSHA256: SHA256(expectedStage1),
			Changed:        beforeStage1Hash != afterStage1Hash,
		},
		Core: ComponentAudit{
			BeforeSHA256:   beforeCoreHash,
			AfterSHA256:    afterCoreHash,
			ExpectedSHA256: SHA256(expectedCore),
			Changed:        beforeCoreHash != afterCoreHash,
		},
	}
}

func equalBytes(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func allZero(data []byte) bool {
	for _, value := range data {
		if value != 0 {
			return false
		}
	}
	return true
}
