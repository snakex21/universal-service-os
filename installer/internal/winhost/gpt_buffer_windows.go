//go:build windows

package winhost

import (
	"encoding/binary"
	"fmt"
	"unicode/utf16"

	"github.com/snakex21/universal-service-os/installer/internal/layout"
	"golang.org/x/sys/windows"
)

const (
	partitionStyleGPT                  = uint32(1)
	createDiskBufferSize               = 24
	driveLayoutHeaderSize              = 48
	partitionEntrySize                 = 144
	gptInfoOffset                      = 32
	gptNameChars                       = 36
	gptBasicDataAttributeNoDriveLetter = uint64(0x8000000000000000)
)

type gptHeader struct {
	DiskID               windows.GUID
	StartingUsableOffset uint64
	UsableLength         uint64
	MaxPartitionCount    uint32
}

type gptIDs struct {
	Disk windows.GUID
	ESP  windows.GUID
	DATA windows.GUID
	WORK windows.GUID
}

type parsedPartition struct {
	Ordinal       uint16
	Number        uint32
	StartBytes    uint64
	SizeBytes     uint64
	PartitionType windows.GUID
	PartitionID   windows.GUID
	Attributes    uint64
	Name          string
}

type parsedLayout struct {
	Header     gptHeader
	Partitions []parsedPartition
}

func newGPTIDs() (gptIDs, error) {
	disk, err := randomGUID()
	if err != nil {
		return gptIDs{}, err
	}
	esp, err := randomGUID()
	if err != nil {
		return gptIDs{}, err
	}
	data, err := randomGUID()
	if err != nil {
		return gptIDs{}, err
	}
	work, err := randomGUID()
	if err != nil {
		return gptIDs{}, err
	}
	return gptIDs{Disk: disk, ESP: esp, DATA: data, WORK: work}, nil
}

func buildCreateDiskBuffer(diskID windows.GUID) ([]byte, error) {
	buffer := make([]byte, createDiskBufferSize)
	binary.LittleEndian.PutUint32(buffer[0:4], partitionStyleGPT)
	if err := putGUID(buffer, 4, diskID); err != nil {
		return nil, err
	}
	binary.LittleEndian.PutUint32(buffer[20:24], 128)
	return buffer, nil
}

func buildDriveLayoutBuffer(plan layout.Plan, header gptHeader, ids gptIDs) ([]byte, error) {
	if guidString(header.DiskID) != guidString(ids.Disk) {
		return nil, fmt.Errorf("GPT disk GUID changed between CREATE_DISK and layout write")
	}
	usableEnd := header.StartingUsableOffset + header.UsableLength
	if usableEnd < header.StartingUsableOffset {
		return nil, fmt.Errorf("GPT usable range overflows uint64")
	}
	if plan.ESP.StartBytes < header.StartingUsableOffset || plan.WORK.StartBytes+plan.WORK.SizeBytes > usableEnd {
		return nil, fmt.Errorf("planned partitions fall outside Windows-reported GPT usable range")
	}

	buffer := make([]byte, driveLayoutHeaderSize+3*partitionEntrySize)
	binary.LittleEndian.PutUint32(buffer[0:4], partitionStyleGPT)
	binary.LittleEndian.PutUint32(buffer[4:8], 3)
	if err := putGUID(buffer, 8, header.DiskID); err != nil {
		return nil, err
	}
	binary.LittleEndian.PutUint64(buffer[24:32], header.StartingUsableOffset)
	binary.LittleEndian.PutUint64(buffer[32:40], header.UsableLength)
	binary.LittleEndian.PutUint32(buffer[40:44], header.MaxPartitionCount)

	partitions := []struct {
		ordinal    uint16
		number     uint32
		part       layout.Partition
		typeID     windows.GUID
		partID     windows.GUID
		attributes uint64
		name       string
	}{
		{1, 1, plan.ESP, efiSystemPartitionType, ids.ESP, 0, "USOS_ESP"},
		{2, 2, plan.DATA, basicDataPartitionType, ids.DATA, 0, "USOS_DATA"},
		{3, 3, plan.WORK, basicDataPartitionType, ids.WORK, gptBasicDataAttributeNoDriveLetter, "USOS_WORK"},
	}
	for index, partition := range partitions {
		offset := driveLayoutHeaderSize + index*partitionEntrySize
		if err := putPartitionEntry(buffer[offset:offset+partitionEntrySize], partition.ordinal, partition.number, partition.part, partition.typeID, partition.partID, partition.attributes, partition.name); err != nil {
			return nil, err
		}
	}
	return buffer, nil
}

func putPartitionEntry(buffer []byte, ordinal uint16, number uint32, partition layout.Partition, typeID, partID windows.GUID, attributes uint64, name string) error {
	if len(buffer) != partitionEntrySize {
		return fmt.Errorf("partition entry buffer size=%d, want %d", len(buffer), partitionEntrySize)
	}
	binary.LittleEndian.PutUint32(buffer[0:4], partitionStyleGPT)
	binary.LittleEndian.PutUint16(buffer[4:6], ordinal)
	binary.LittleEndian.PutUint64(buffer[8:16], partition.StartBytes)
	binary.LittleEndian.PutUint64(buffer[16:24], partition.SizeBytes)
	binary.LittleEndian.PutUint32(buffer[24:28], number)
	buffer[28] = 1
	buffer[29] = 0
	if err := putGUID(buffer, gptInfoOffset, typeID); err != nil {
		return err
	}
	if err := putGUID(buffer, gptInfoOffset+16, partID); err != nil {
		return err
	}
	binary.LittleEndian.PutUint64(buffer[gptInfoOffset+32:gptInfoOffset+40], attributes)
	return putUTF16Fixed(buffer[gptInfoOffset+40:gptInfoOffset+40+gptNameChars*2], name)
}

func parseDriveLayout(buffer []byte) (parsedLayout, error) {
	if len(buffer) < driveLayoutHeaderSize {
		return parsedLayout{}, fmt.Errorf("DRIVE_LAYOUT_INFORMATION_EX is too short: %d", len(buffer))
	}
	if binary.LittleEndian.Uint32(buffer[0:4]) != partitionStyleGPT {
		return parsedLayout{}, fmt.Errorf("disk layout is not GPT")
	}
	count := int(binary.LittleEndian.Uint32(buffer[4:8]))
	required := driveLayoutHeaderSize + count*partitionEntrySize
	if count < 0 || required > len(buffer) {
		return parsedLayout{}, fmt.Errorf("invalid GPT partition count=%d buffer=%d", count, len(buffer))
	}
	diskID, err := readGUID(buffer, 8)
	if err != nil {
		return parsedLayout{}, err
	}
	result := parsedLayout{
		Header: gptHeader{
			DiskID:               diskID,
			StartingUsableOffset: binary.LittleEndian.Uint64(buffer[24:32]),
			UsableLength:         binary.LittleEndian.Uint64(buffer[32:40]),
			MaxPartitionCount:    binary.LittleEndian.Uint32(buffer[40:44]),
		},
		Partitions: make([]parsedPartition, 0, count),
	}
	for index := 0; index < count; index++ {
		offset := driveLayoutHeaderSize + index*partitionEntrySize
		entry := buffer[offset : offset+partitionEntrySize]
		if binary.LittleEndian.Uint32(entry[0:4]) != partitionStyleGPT {
			continue
		}
		typeID, err := readGUID(entry, gptInfoOffset)
		if err != nil {
			return parsedLayout{}, err
		}
		partID, err := readGUID(entry, gptInfoOffset+16)
		if err != nil {
			return parsedLayout{}, err
		}
		result.Partitions = append(result.Partitions, parsedPartition{
			Ordinal:       binary.LittleEndian.Uint16(entry[4:6]),
			Number:        binary.LittleEndian.Uint32(entry[24:28]),
			StartBytes:    binary.LittleEndian.Uint64(entry[8:16]),
			SizeBytes:     binary.LittleEndian.Uint64(entry[16:24]),
			PartitionType: typeID,
			PartitionID:   partID,
			Attributes:    binary.LittleEndian.Uint64(entry[gptInfoOffset+32 : gptInfoOffset+40]),
			Name:          readUTF16Fixed(entry[gptInfoOffset+40 : gptInfoOffset+40+gptNameChars*2]),
		})
	}
	return result, nil
}

func putUTF16Fixed(buffer []byte, value string) error {
	encoded := utf16.Encode([]rune(value))
	if len(encoded) >= gptNameChars {
		return fmt.Errorf("GPT partition name %q is too long", value)
	}
	if len(buffer) != gptNameChars*2 {
		return fmt.Errorf("GPT name buffer size=%d, want %d", len(buffer), gptNameChars*2)
	}
	for index, code := range encoded {
		binary.LittleEndian.PutUint16(buffer[index*2:index*2+2], code)
	}
	return nil
}

func readUTF16Fixed(buffer []byte) string {
	codes := make([]uint16, 0, len(buffer)/2)
	for index := 0; index+1 < len(buffer); index += 2 {
		code := binary.LittleEndian.Uint16(buffer[index : index+2])
		if code == 0 {
			break
		}
		codes = append(codes, code)
	}
	return string(utf16.Decode(codes))
}
