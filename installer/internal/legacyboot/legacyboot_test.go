package legacyboot

import (
	"encoding/binary"
	"hash/crc32"
	"testing"
)

func protectiveSector(diskBytes uint64) []byte {
	sector := make([]byte, SupportedSectorBytes)
	entry := sector[MBRPartitionOffset : MBRPartitionOffset+16]
	entry[4] = 0xEE
	binary.LittleEndian.PutUint32(entry[8:12], 1)
	sectors := diskBytes/uint64(SupportedSectorBytes) - 1
	if sectors > 0xFFFFFFFF {
		sectors = 0xFFFFFFFF
	}
	binary.LittleEndian.PutUint32(entry[12:16], uint32(sectors))
	sector[MBRSignatureOffset] = 0x55
	sector[MBRSignatureOffset+1] = 0xAA
	return sector
}

func TestComputeRegionUsesActualGPTAndESPBoundaries(t *testing.T) {
	region, err := ComputeRegion(34*512, 2048*512, 512)
	if err != nil {
		t.Fatal(err)
	}
	if region.CoreStartBytes != 64*512 || region.CoreEndBytes != (64+512)*512 {
		t.Fatalf("unexpected Core region: %+v", region)
	}
	if _, err := ComputeRegion(65*512, 2048*512, 512); err == nil {
		t.Fatal("accepted Core overlapping actual GPT usable boundary")
	}
	if _, err := ComputeRegion(34*512, 575*512, 512); err == nil {
		t.Fatal("accepted Core overlapping ESP")
	}
	if _, err := ComputeRegion(34*512, 576*512, 512); err != nil {
		t.Fatalf("rejected Core slot ending exactly before ESP: %v", err)
	}
	if _, err := ComputeRegion(34*512, 2048*512, 4096); err == nil {
		t.Fatal("accepted unsupported logical sector size")
	}
}

func validCoreSlotForTest() []byte {
	slot := make([]byte, CoreSlotBytes)
	copy(slot[:8], coreHeaderMagic[:])
	binary.LittleEndian.PutUint16(slot[coreHeaderVersionOffset:], CoreFormatVersion)
	binary.LittleEndian.PutUint16(slot[coreHeaderSizeOffset:], CoreHeaderBytes)
	binary.LittleEndian.PutUint32(slot[coreHeaderSlotBytesOffset:], uint32(CoreSlotBytes))
	binary.LittleEndian.PutUint32(slot[coreHeaderBootstrapOffset:], uint32(CoreBootstrapBytes))
	payload := []byte{0xFC, 0xFA, 0xF4}
	imageSize := uint32(CoreBootstrapBytes) + uint32(len(payload))
	binary.LittleEndian.PutUint32(slot[coreHeaderImageSizeOffset:], imageSize)
	binary.LittleEndian.PutUint32(slot[coreHeaderPayloadOffset:], uint32(CoreBootstrapBytes))
	binary.LittleEndian.PutUint32(slot[coreHeaderPayloadSizeOffset:], uint32(len(payload)))
	binary.LittleEndian.PutUint32(slot[coreHeaderLoadAddressOffset:], CoreLoadAddress)
	binary.LittleEndian.PutUint32(slot[coreHeaderEntryOffset:], CoreEntryOffset)
	copy(slot[CoreBootstrapBytes:], payload)
	binary.LittleEndian.PutUint32(slot[coreHeaderContentCRCOffset:], crc32.ChecksumIEEE(slot[CoreHeaderBytes:imageSize]))
	binary.LittleEndian.PutUint32(slot[coreHeaderHeaderCRCOffset:], crc32.ChecksumIEEE(slot[:coreHeaderCRCInputBytes]))
	return slot
}

func TestValidateCoreSlot(t *testing.T) {
	slot := validCoreSlotForTest()
	if err := ValidateCoreSlot(slot); err != nil {
		t.Fatalf("valid Core slot rejected: %v", err)
	}

	badVersion := append([]byte(nil), slot...)
	binary.LittleEndian.PutUint16(badVersion[coreHeaderVersionOffset:], CoreFormatVersion+1)
	binary.LittleEndian.PutUint32(badVersion[coreHeaderHeaderCRCOffset:], crc32.ChecksumIEEE(badVersion[:coreHeaderCRCInputBytes]))
	if err := ValidateCoreSlot(badVersion); err == nil {
		t.Fatal("accepted unsupported Core format version")
	}

	badHeaderCRC := append([]byte(nil), slot...)
	badHeaderCRC[coreHeaderSlotBytesOffset] ^= 0x01
	if err := ValidateCoreSlot(badHeaderCRC); err == nil {
		t.Fatal("accepted corrupted Core header")
	}

	badContent := append([]byte(nil), slot...)
	badContent[CoreBootstrapBytes] ^= 0x5A
	if err := ValidateCoreSlot(badContent); err == nil {
		t.Fatal("accepted corrupted Core content")
	}
}

func TestValidateProtectiveMBR(t *testing.T) {
	diskBytes := uint64(40) * 1024 * 1024 * 1024
	sector := protectiveSector(diskBytes)
	if err := ValidateProtectiveMBR(sector, diskBytes, 512); err != nil {
		t.Fatalf("valid protective MBR rejected: %v", err)
	}

	sentinel := append([]byte(nil), sector...)
	binary.LittleEndian.PutUint32(sentinel[MBRPartitionOffset+12:MBRPartitionOffset+16], 0xFFFFFFFF)
	if err := ValidateProtectiveMBR(sentinel, diskBytes, 512); err != nil {
		t.Fatalf("Windows 0xFFFFFFFF protective-size sentinel rejected: %v", err)
	}

	badSignature := append([]byte(nil), sector...)
	badSignature[510] = 0
	if err := ValidateProtectiveMBR(badSignature, diskBytes, 512); err == nil {
		t.Fatal("accepted bad MBR signature")
	}

	badType := append([]byte(nil), sector...)
	badType[MBRPartitionOffset+4] = 0x07
	if err := ValidateProtectiveMBR(badType, diskBytes, 512); err == nil {
		t.Fatal("accepted missing protective 0xEE entry")
	}

	extra := append([]byte(nil), sector...)
	extra[MBRPartitionOffset+16+4] = 0x07
	if err := ValidateProtectiveMBR(extra, diskBytes, 512); err == nil {
		t.Fatal("accepted extra non-empty MBR partition entry")
	}
}

func TestExpectedSectorChangesOnlyBootCode(t *testing.T) {
	before := protectiveSector(40 * 1024 * 1024 * 1024)
	for index := 440; index < 446; index++ {
		before[index] = byte(index)
	}
	stage1 := make([]byte, Stage1CodeBytes)
	for index := range stage1 {
		stage1[index] = byte(index)
	}
	expected, err := ExpectedSectorWithStage1(before, stage1)
	if err != nil {
		t.Fatal(err)
	}
	for index := 0; index < Stage1CodeBytes; index++ {
		if expected[index] != stage1[index] {
			t.Fatalf("Stage1 byte %d mismatch", index)
		}
	}
	for index := Stage1CodeBytes; index < len(before); index++ {
		if expected[index] != before[index] {
			t.Fatalf("byte %d outside Stage1 changed", index)
		}
	}
}

func TestPayloadRejectsAutotestEvenWithValidCRC(t *testing.T) {
	slot := validCoreSlotForTest()
	copy(slot[CoreHeaderBytes:], []byte("[LEGACY_MENU_TEST] BEGIN XP METHODS AUTO TEST"))
	imageSize := binary.LittleEndian.Uint32(slot[coreHeaderImageSizeOffset:])
	binary.LittleEndian.PutUint32(slot[coreHeaderContentCRCOffset:], crc32.ChecksumIEEE(slot[CoreHeaderBytes:imageSize]))
	binary.LittleEndian.PutUint32(slot[coreHeaderHeaderCRCOffset:], crc32.ChecksumIEEE(slot[:coreHeaderCRCInputBytes]))
	if err := ValidateCoreSlot(slot); err != nil {
		t.Fatalf("fixture CRC/format is invalid: %v", err)
	}
	if err := (Payload{Stage1: make([]byte, Stage1CodeBytes), Core: slot}).Validate(); err == nil {
		t.Fatal("accepted a valid-CRC autotest Core for device installation")
	}
	if err := (Payload{Stage1: make([]byte, Stage1CodeBytes), Core: validCoreSlotForTest()}).Validate(); err != nil {
		t.Fatalf("rejected normal Core: %v", err)
	}
}
